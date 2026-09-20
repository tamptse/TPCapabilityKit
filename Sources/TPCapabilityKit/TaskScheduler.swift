import Foundation
import Combine

/// Internal error type for task execution failures.
private struct TaskExecutionError: Error, Sendable {}

/// Thread-safe wrapper for passing non-Sendable values through task groups.
final class SendableBox<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()
    
    var value: T {
        lock.withLock { _value }
    }
    
    init(_ value: T) { _value = value }
    
    func setValue(_ value: T) {
        lock.withLock { _value = value }
    }
}

/// Centralized task scheduler that manages capability-based routing,
/// priority queuing, and lease lifecycle.
///
/// Inspired by Meta's Jupiter (capability matching) and Async (priority dispatching).
/// - Important: `@unchecked Sendable` is intentional — all mutable state
///   (`pendingTasks`, `activeLeases`, `taskExecutions`, `completionHandlers`)
///   is protected by `lock`. TaskStore tracks unstructured tasks for lifecycle
///   safety. Do not add unsynchronized mutable state.
final class TaskScheduler: TaskSchedulerProtocol, @unchecked Sendable {
    /// Configuration for the scheduler.
    struct Configuration: Sendable {
        /// Default timeout for tasks if not specified in TaskDescriptor.
        let defaultTimeout: TimeInterval

        /// Maximum concurrent tasks per capability. Nil means no per-capability limit.
        let maxPerCapability: Int?

        /// Maximum concurrent tasks globally. Nil means no global limit.
        let maxGlobal: Int?

        init(
            defaultTimeout: TimeInterval = 30.0,
            maxPerCapability: Int? = 5,
            maxGlobal: Int? = 20
        ) {
            self.defaultTimeout = defaultTimeout
            self.maxPerCapability = maxPerCapability
            self.maxGlobal = maxGlobal
        }

        /// Default configuration: 5 per capability, 20 global.
        static let `default` = Configuration()
    }

    private let store: DynamicStore
    private let configuration: Configuration
    private let concurrencyController: ConcurrencyController
    private let lock = NSLock()
    private let taskStore = TaskStore()

    // Priority queues: one per priority level
    private var pendingTasks: [TaskPriority: [Lease]] = [
        .critical: [],
        .high: [],
        .normal: [],
        .low: [],
        .background: []
    ]

    // Active leases by task ID
    private var activeLeases: [String: Lease] = [:]

    // Task execution closures by task ID (returns result as Any?)
    private var taskExecutions: [String: @Sendable () async -> Any?] = [:]

    // Completion handlers by task ID
    private var completionHandlers: [String: (Lease) -> Void] = [:]

    // Cached pending count for O(1) access
    private var _pendingCount: Int = 0

    // Lookup index for O(1) cancel: taskId -> priority
    private var taskPriorityIndex: [String: TaskPriority] = [:]

    // Lease index: taskId -> lease, live from schedule until terminalize.
    // Lets cancel find a lease even while it is dequeued between queues.
    private var leasesById: [String: Lease] = [:]

    // Task IDs with a live capability waiter. One waiter per lease at a time,
    // so the pending loop never spawns duplicate waiters for the same lease.
    private var waitingLeases: Set<String> = []

    // Subject for scheduler events
    private let eventSubject = PassthroughSubject<SchedulerEvent, Never>()

    /// Test-only hook fired after a lease is activated in `executeLease`.
    /// Lets tests park a task at active deterministically instead of sleeping.
    var onActivate: ((Lease) -> Void)?

    /// Events emitted by the scheduler.
    enum SchedulerEvent: Sendable {
        case taskScheduled(lease: Lease)
        case taskStarted(lease: Lease)
        case taskCompleted(lease: Lease)
        case taskFailed(lease: Lease, error: Error)
        case taskExpired(lease: Lease)
        case taskRetried(lease: Lease, attempt: Int)
    }

    /// Creates a new TaskScheduler.
    init(store: DynamicStore = .shared, configuration: Configuration = .init()) {
        self.store = store
        self.configuration = configuration
        self.concurrencyController = ConcurrencyController(maxPerCapability: configuration.maxPerCapability, maxGlobal: configuration.maxGlobal)
    }

    /// Publisher for scheduler events.
    var events: AnyPublisher<SchedulerEvent, Never> {
        eventSubject.eraseToAnyPublisher()
    }

    /// Schedules a task for execution with a closure.
    /// - Parameters:
    ///   - task: The task descriptor to schedule.
    ///   - taskExecution: The async closure to execute when capability is available.
    ///   - completion: Optional completion handler called when task reaches a terminal state.
    /// - Returns: The lease for tracking the task.
    @discardableResult
    func schedule(
        _ task: TaskDescriptor,
        taskExecution: @escaping @Sendable () async -> Void,
        completion: ((Lease) -> Void)? = nil
    ) -> Lease {
        schedule(task, taskExecution: taskExecution, completion: completion, autoProcess: true)
    }

    @discardableResult
    func schedule(
        _ task: TaskDescriptor,
        taskExecution: @escaping @Sendable () async -> Void,
        completion: ((Lease) -> Void)?,
        autoProcess: Bool
    ) -> Lease {
        let lease = Lease(task: task)

        lock.withLock {
            pendingTasks[task.priority]?.append(lease)
            _pendingCount += 1
            taskPriorityIndex[task.id] = task.priority
            leasesById[task.id] = lease
            taskExecutions[task.id] = { @Sendable in
                await taskExecution()
                return nil
            }
            if let completion = completion {
                completionHandlers[task.id] = completion
            }
        }

        eventSubject.send(.taskScheduled(lease: lease))

        // Process pending tasks if requested
        if autoProcess {
            Task { await processPendingTasks() }
        }

        return lease
    }

    /// Schedules a task and waits for its result.
    /// - Parameters:
    ///   - task: The task descriptor to schedule.
    ///   - taskExecution: The async closure to execute when capability is available.
    /// - Returns: The result of the task, or nil if timeout/error.
    func scheduleAndWait<T: Sendable>(
        _ task: TaskDescriptor,
        taskExecution: @escaping @Sendable () async throws -> T
    ) async -> T? {
        let resultBox = SendableBox<T?>(nil)
        let completionLock = NSLock()

        // Schedule without auto-processing
        let lease = schedule(task, taskExecution: {
            // Empty closure - actual execution happens via taskExecutions
        }, completion: { lease in
            // No-op here, we'll handle completion via the continuation
        }, autoProcess: false)

        // Store the actual execution closure that returns a result
        lock.withLock {
            taskExecutions[task.id] = { @Sendable in
                let value = try? await taskExecution()
                resultBox.setValue(value)
                return value
            }
        }

        return await withCheckedContinuation { continuation in
            var resumed = false

            // Update completion handler to resume continuation
            lock.withLock {
                completionHandlers[task.id] = { lease in
                    completionLock.withLock {
                        guard !resumed else { return }
                        resumed = true
                    }

                    switch lease.state {
                    case .completed:
                        continuation.resume(returning: resultBox.value)
                    case .failed:
                        continuation.resume(returning: nil)
                    case .expired:
                        continuation.resume(returning: nil)
                    default:
                        continuation.resume(returning: nil)
                    }
                }
            }

            // Start execution in background
            Task {
                await self.executeLease(lease)
            }
        }
    }

    /// Cancels a pending task.
    /// - Parameter taskId: The ID of the task to cancel.
    func cancel(taskId: String) {
        let target: Lease? = lock.withLock { leasesById[taskId] }
        guard let target else { return }
        terminalize(target, applyState: { $0.expire() }, makeEvent: { .taskExpired(lease: $0) })
    }

    /// Returns the number of pending tasks.
    var pendingCount: Int {
        lock.withLock { _pendingCount }
    }

    /// Returns the number of active tasks.
    var activeCount: Int {
        lock.withLock {
            activeLeases.count
        }
    }

    // MARK: - Private Methods

    /// Single terminal path: cleanup under lock, state + event decided under
    /// lock, `send` and completion outside the lock. Fires exactly once per
    /// lease via the `isTerminal` guard.
    private func terminalize(
        _ lease: Lease,
        applyState: (Lease) -> Void,
        makeEvent: (Lease) -> SchedulerEvent
    ) {
        var completion: ((Lease) -> Void)?
        var event: SchedulerEvent?
        lock.withLock {
            guard !lease.isTerminal else { return }
            if let priority = taskPriorityIndex.removeValue(forKey: lease.task.id),
               let index = pendingTasks[priority]?.firstIndex(where: { $0.task.id == lease.task.id }) {
                pendingTasks[priority]?.remove(at: index)
                _pendingCount -= 1
            }
            activeLeases.removeValue(forKey: lease.task.id)
            leasesById.removeValue(forKey: lease.task.id)
            taskExecutions.removeValue(forKey: lease.task.id)
            completion = completionHandlers.removeValue(forKey: lease.task.id)
            applyState(lease)
            event = makeEvent(lease)
        }
        guard let event else { return }
        eventSubject.send(event)
        completion?(lease)
    }

    private func failLease(_ lease: Lease) {
        let error = TaskExecutionError()
        terminalize(lease, applyState: { $0.fail(with: error) }, makeEvent: { .taskFailed(lease: $0, error: error) })
    }

    private func processPendingTasks() async {
        // Process tasks in priority order
        while true {
            guard let nextLease = dequeueNext() else { break }
            guard !nextLease.isTerminal else { continue }

            // Check capability availability
            guard checkCapabilities(for: nextLease.task) else {
                // Park the lease outside the queue with a single waiter;
                // the waiter executes or expires it when done.
                let shouldWait: Bool = lock.withLock {
                    if waitingLeases.contains(nextLease.task.id) { return false }
                    waitingLeases.insert(nextLease.task.id)
                    return true
                }
                if shouldWait {
                    await taskStore.store(Task { await waitForCapabilitiesAndProcess(nextLease) })
                }
                continue
            }

            // Execute the task
            await executeLease(nextLease)
        }
    }

    private func dequeueNext() -> Lease? {
        lock.withLock {
            // Find highest priority non-empty queue
            for priority in [TaskPriority.critical, .high, .normal, .low, .background] {
                if var queue = pendingTasks[priority], !queue.isEmpty {
                    let lease = queue.removeFirst()
                    pendingTasks[priority] = queue
                    _pendingCount -= 1
                    taskPriorityIndex.removeValue(forKey: lease.task.id)
                    return lease
                }
            }
            return nil
        }
    }

    private func checkCapabilities(for task: TaskDescriptor) -> Bool {
        for cap in task.requiredCapabilities {
            guard store.queryCapability(cap) else { return false }
        }
        return true
    }

    private func waitForCapabilitiesAndProcess(_ lease: Lease) async {
        // Wait for capability to be available (with timeout)
        let capabilityAvailable = await waitForCapabilitiesWithTimeout(lease.task)
        lock.withLock { waitingLeases.remove(lease.task.id) }

        guard !lease.isTerminal else { return }

        guard capabilityAvailable else {
            terminalize(lease, applyState: { $0.expire() }, makeEvent: { .taskExpired(lease: $0) })
            return
        }

        // Execute the task
        await executeLease(lease)
    }

    /// Waits for capabilities to become available with a timeout.
    /// - Returns: `true` if all capabilities are available, `false` if timeout.
    private func waitForCapabilitiesWithTimeout(_ task: TaskDescriptor) async -> Bool {
        await store.waitForCapabilities(task.requiredCapabilities, timeout: task.timeout)
    }

    /// Sole production activator: every prod path to `active` goes through here
    /// (wait via the shared waiter, terminal via `terminalize`).
    /// Tests may still call `Lease.activate()` directly.
    private func executeLease(_ lease: Lease) async {
        guard checkCapabilities(for: lease.task) else {
            failLease(lease)
            return
        }

        await withSlot(for: lease) {
            await self.runActivatedLease(lease)
        }
    }

    /// Scoped concurrency slot: acquire, re-check capability, activate, and
    /// always release on scope exit so no path can leak or double-release.
    func withSlot(for lease: Lease, operation: @escaping () async -> Void) async {
        await concurrencyController.acquire(for: lease.task)
        defer {
            Task { [concurrencyController, task = lease.task] in
                await concurrencyController.release(for: task)
            }
        }

        guard !lease.isTerminal else { return }
        guard checkCapabilities(for: lease.task) else {
            failLease(lease)
            return
        }

        lease.activate()
        lock.withLock {
            activeLeases[lease.task.id] = lease
        }

        eventSubject.send(.taskStarted(lease: lease))
        onActivate?(lease)

        await operation()
    }

    /// Current concurrency utilization. Exposed for tests to assert slot balance.
    func concurrencyStats() async -> ConcurrencyController.Stats {
        await concurrencyController.stats()
    }

    private func runActivatedLease(_ lease: Lease) async {
        // Get the task execution closure
        let taskExecution: (@Sendable () async -> Any?)? = lock.withLock {
            taskExecutions.removeValue(forKey: lease.task.id)
        }

        // Execute with timeout
        let result: SendableBox<Any?>? = await withTaskGroup(of: SendableBox<Any?>?.self) { group in
            // Task: actual execution
            group.addTask { @Sendable in
                let value = await taskExecution?()
                return SendableBox(value)
            }

            // Task: timeout monitor
            group.addTask { @Sendable () -> SendableBox<Any?>? in
                try? await Task.sleep(nanoseconds: UInt64(lease.task.timeout * 1_000_000_000))
                return nil
            }

            guard let result = await group.next() else {
                group.cancelAll()
                return nil
            }
            group.cancelAll()
            return result
        }

        // Complete lease (slot is released by `withSlot` on scope exit)
        if let result = result?.value {
            terminalize(lease, applyState: { $0.complete(with: result) }, makeEvent: { .taskCompleted(lease: $0) })
        } else {
            if lease.hasExpired {
                terminalize(lease, applyState: { $0.expire() }, makeEvent: { .taskExpired(lease: $0) })
            } else if lease.retry() {
                eventSubject.send(.taskRetried(lease: lease, attempt: lease.retryCount))
                lock.withLock {
                    activeLeases.removeValue(forKey: lease.task.id)
                    completionHandlers.removeValue(forKey: lease.task.id)
                    taskExecutions.removeValue(forKey: lease.task.id)
                    pendingTasks[lease.task.priority]?.append(lease)
                    _pendingCount += 1
                    taskPriorityIndex[lease.task.id] = lease.task.priority
                }
                await taskStore.store(Task { await processPendingTasks() })
                return
            } else {
                let error = TaskExecutionError()
                terminalize(lease, applyState: { $0.fail(with: error) }, makeEvent: { .taskFailed(lease: $0, error: error) })
            }
        }
    }
}

/// Single capability waiter owned by the Tasks module: one deadline shared by
/// the whole set. `DynamicStore.waitForCapability` delegates here.
extension DynamicStore {
    func waitForCapabilities(_ capabilities: Set<Capability>, timeout: TimeInterval) async -> Bool {
        if capabilities.isEmpty { return true }
        if capabilities.allSatisfy({ queryCapability($0) }) { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { [self] in
                for await _ in self.observeAllCapabilities().values {
                    if capabilities.allSatisfy({ self.queryCapability($0) }) { return true }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            guard let result = await group.next() else {
                group.cancelAll()
                return false
            }
            group.cancelAll()
            return result
        }
    }
}
