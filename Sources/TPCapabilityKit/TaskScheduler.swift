import Foundation
import Combine

/// Internal error type for task execution failures.
private struct TaskExecutionError: Error, Sendable {}

private struct VoidCompletionSentinel: Sendable {}

/// Typed one-shot handoff: result-write, resume-once, and completion
/// co-located so no caller orchestrates locks or resumed flags.
private final class OneShot<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    private var claimed = false

    func store(_ newValue: T?) {
        lock.withLock { value = newValue }
    }

    func load() -> T? {
        lock.withLock { value }
    }

    func claim() -> (taken: Bool, value: T?) {
        lock.withLock {
            guard !claimed else { return (false, nil) }
            claimed = true
            return (true, value)
        }
    }
}

/// Centralized task scheduler that manages capability-based routing,
/// priority queuing, and lease lifecycle.
///
/// Inspired by Meta's Jupiter (capability matching) and Async (priority dispatching).
/// - Important: `@unchecked Sendable` is intentional — all mutable state
///   (`pendingTasks`, `activeLeases`, `taskExecutions`, `completionHandlers`,
///   `parkedWaiters`) is protected by `lock`. Parked capability waiters are
///   tracked per lease and cancelled on terminal settlement. Do not add
///   unsynchronized mutable state.
public final class TaskScheduler: @unchecked Sendable {
    public struct Configuration: Sendable {
        public let defaultTimeout: TimeInterval
        public let maxPerCapability: Int?
        public let maxGlobal: Int?

        public init(
            defaultTimeout: TimeInterval = 30.0,
            maxPerCapability: Int? = 5,
            maxGlobal: Int? = 20
        ) {
            self.defaultTimeout = defaultTimeout
            self.maxPerCapability = maxPerCapability
            self.maxGlobal = maxGlobal
        }

        public static let `default` = Configuration()
    }

    private weak var store: DynamicStore?
    private let configuration: Configuration
    private let concurrencyController: ConcurrencyController
    private let lock = NSLock()

    private func effectiveTimeout(for task: TaskDescriptor) -> TimeInterval {
        task.timeout ?? configuration.defaultTimeout
    }

    private var pendingTasks: [TaskPriority: [Lease]] = [
        .critical: [],
        .high: [],
        .normal: [],
        .low: [],
        .background: []
    ]

    private var activeLeases: [String: Lease] = [:]

    private var taskExecutions: [String: @Sendable () async -> Any?] = [:]

    private var completionHandlers: [String: (Lease) -> Void] = [:]

    // Cached pending count for O(1) access
    private var _pendingCount: Int = 0

    // Lookup index for O(1) cancel: taskId -> priority
    private var taskPriorityIndex: [String: TaskPriority] = [:]

    // Lets cancel find a lease even while it is dequeued between queues.
    private var leasesById: [String: Lease] = [:]

    // One waiter per lease at a time, so the pending loop never spawns duplicates.
    private var waitingLeases: Set<String> = []

    // Cancelled on settlement so a parked waiter wakes promptly instead of lingering until timeout.
    private var parkedWaiters: [String: Task<Void, Never>] = [:]

    // Deadlines captured at activation, owned by Settlement.
    private var deadlines: [String: Date] = [:]

    // Held concurrency Slots by task ID. Settlement owns release: terminalize
    // releases before completion, retry releases before re-queue, and withSlot
    // releases on scope exit. Map removal makes release exactly once.
    private var slotsByTaskId: [String: ConcurrencyController.Slot] = [:]

    private let eventSubject = PassthroughSubject<SchedulerEvent, Never>()

    enum SchedulerEvent: Sendable {
        case taskScheduled(lease: Lease)
        case taskStarted(lease: Lease)
        case taskCompleted(lease: Lease)
        case taskFailed(lease: Lease, error: Error)
        case taskExpired(lease: Lease)
        case taskRetried(lease: Lease, attempt: Int)
    }

    init(store: DynamicStore = .shared, configuration: Configuration = .init()) {
        self.store = store
        self.configuration = configuration
        self.concurrencyController = ConcurrencyController(maxPerCapability: configuration.maxPerCapability, maxGlobal: configuration.maxGlobal)
    }

    /// Intentional observability seam for tests and diagnostics, alongside `ConcurrencyController.stats()`.
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
        let lease = enqueue(task, execution: {
            await taskExecution()
            return VoidCompletionSentinel()
        }, completion: completion)
        Task { await self.processPendingTasks() }
        return lease
    }

    @discardableResult
    private func enqueue(
        _ task: TaskDescriptor,
        execution: @escaping @Sendable () async -> Any?,
        completion: ((Lease) -> Void)?
    ) -> Lease {
        let lease = Lease(task: task)

        lock.withLock {
            pendingTasks[task.priority]?.append(lease)
            _pendingCount += 1
            taskPriorityIndex[task.id] = task.priority
            leasesById[task.id] = lease
            taskExecutions[task.id] = execution
            if let completion {
                completionHandlers[task.id] = completion
            }
        }

        eventSubject.send(.taskScheduled(lease: lease))
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
        let handoff = OneShot<T>()
        let lease = enqueue(task, execution: {
            let value = try? await taskExecution()
            handoff.store(value)
            return value
        }, completion: nil)

        return await withCheckedContinuation { continuation in
            func finish(_ lease: Lease) {
                let claimed = handoff.claim()
                guard claimed.taken else { return }
                switch lease.state {
                case .completed:
                    continuation.resume(returning: claimed.value)
                default:
                    continuation.resume(returning: nil)
                }
            }

            let settledEarly: Bool = lock.withLock {
                if lease.isTerminal {
                    return true
                }
                completionHandlers[task.id] = { finish($0) }
                return false
            }
            if settledEarly {
                switch lease.state {
                case .completed:
                    continuation.resume(returning: handoff.load())
                default:
                    continuation.resume(returning: nil)
                }
                return
            }

            Task { await self.processPendingTasks() }
        }
    }

    /// Cancels a pending task.
    /// - Parameter taskId: The ID of the task to cancel.
    func cancel(taskId: String) {
        let target: Lease? = lock.withLock { leasesById[taskId] }
        guard let target else { return }
        settle(target, as: .cancelled)
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

    private enum Settlement {
        case completed(Any?)
        case failed
        case expired
        case cancelled
    }

    private func settle(_ lease: Lease, as outcome: Settlement) {
        switch outcome {
        case .completed(let result):
            terminalize(lease, applyState: { $0.complete(with: result) }, makeEvent: { .taskCompleted(lease: $0) })
        case .failed:
            let error = TaskExecutionError()
            terminalize(lease, applyState: { $0.fail(with: error) }, makeEvent: { .taskFailed(lease: $0, error: error) })
        case .expired, .cancelled:
            terminalize(lease, applyState: { $0.expire() }, makeEvent: { .taskExpired(lease: $0) })
        }
    }

    private func settle(_ lease: Lease, result: Any?, timedOut: Bool, execution: (@Sendable () async -> Any?)?) async {
        if lease.isTerminal { return }
        let deadline: Date? = lock.withLock { deadlines[lease.task.id] }
        if timedOut || (deadline.map { Date() >= $0 } ?? false) {
            settle(lease, as: .expired)
            return
        }
        if result is VoidCompletionSentinel {
            settle(lease, as: .completed(nil))
            return
        }
        if result != nil {
            settle(lease, as: .completed(result))
            return
        }
        if requeueForRetry(lease, execution: execution) {
            return
        }
        if lease.isTerminal { return }
        settle(lease, as: .failed)
    }

    private func requeueForRetry(_ lease: Lease, execution: (@Sendable () async -> Any?)?) -> Bool {
        var slotToRelease: ConcurrencyController.Slot?
        var retried = false
        lock.withLock {
            guard !lease.isTerminal else { return }
            if lease.canRetry {
                lease.beginRetry()
                activeLeases.removeValue(forKey: lease.task.id)
                deadlines.removeValue(forKey: lease.task.id)
                slotToRelease = slotsByTaskId.removeValue(forKey: lease.task.id)
                if let execution {
                    taskExecutions[lease.task.id] = execution
                }
                pendingTasks[lease.task.priority]?.append(lease)
                _pendingCount += 1
                taskPriorityIndex[lease.task.id] = lease.task.priority
                retried = true
            }
        }
        if let slotToRelease {
            concurrencyController.release(slotToRelease)
        }
        if retried {
            eventSubject.send(.taskRetried(lease: lease, attempt: lease.retryCount))
            Task { await self.processPendingTasks() }
            return true
        }
        return false
    }

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
        var slotToRelease: ConcurrencyController.Slot?
        var waiterToCancel: Task<Void, Never>?
        lock.withLock {
            guard !lease.isTerminal else { return }
            if let priority = taskPriorityIndex.removeValue(forKey: lease.task.id),
               let index = pendingTasks[priority]?.firstIndex(where: { $0.task.id == lease.task.id }) {
                pendingTasks[priority]?.remove(at: index)
                _pendingCount -= 1
            }
            activeLeases.removeValue(forKey: lease.task.id)
            leasesById.removeValue(forKey: lease.task.id)
            deadlines.removeValue(forKey: lease.task.id)
            waitingLeases.remove(lease.task.id)
            waiterToCancel = parkedWaiters.removeValue(forKey: lease.task.id)
            slotToRelease = slotsByTaskId.removeValue(forKey: lease.task.id)
            taskExecutions.removeValue(forKey: lease.task.id)
            completion = completionHandlers.removeValue(forKey: lease.task.id)
            applyState(lease)
            event = makeEvent(lease)
        }
        guard let event else { return }
        waiterToCancel?.cancel()
        if let slotToRelease {
            concurrencyController.release(slotToRelease)
        }
        eventSubject.send(event)
        completion?(lease)
    }

    private func releaseSlot(for taskId: String) {
        let slot: ConcurrencyController.Slot? = lock.withLock {
            slotsByTaskId.removeValue(forKey: taskId)
        }
        if let slot {
            concurrencyController.release(slot)
        }
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
                    let waiter = Task { await self.waitForCapabilitiesAndProcess(nextLease) }
                    let alreadyTerminal: Bool = lock.withLock {
                        parkedWaiters[nextLease.task.id] = waiter
                        return nextLease.isTerminal
                    }
                    if alreadyTerminal { waiter.cancel() }
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
        guard let store else { return false }
        for cap in task.requiredCapabilities {
            guard store.queryCapability(cap) else { return false }
        }
        return true
    }

    private func waitForCapabilitiesAndProcess(_ lease: Lease) async {
        let capabilityAvailable = await waitForCapabilities(
            lease.task.requiredCapabilities,
            timeout: effectiveTimeout(for: lease.task)
        )
        lock.withLock {
            waitingLeases.remove(lease.task.id)
            parkedWaiters.removeValue(forKey: lease.task.id)
        }

        guard !lease.isTerminal else { return }

        guard capabilityAvailable else {
            settle(lease, as: .expired)
            return
        }

        await executeLease(lease)
    }

    /// Single capability waiter owned by Tasks: one deadline shared by the
    /// whole set. Serves immediate (run-when-available) and queued
    /// (schedule/schedule-and-wait) execution alike, preserved across retry.
    private func waitForCapabilities(_ capabilities: Set<Capability>, timeout: TimeInterval) async -> Bool {
        guard let store else { return false }
        if capabilities.isEmpty { return true }
        if capabilities.allSatisfy({ store.queryCapability($0) }) { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { [store] in
                for await _ in store.observeAllCapabilities().values {
                    if capabilities.allSatisfy({ store.queryCapability($0) }) { return true }
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

    /// Sole production activator: every prod path to `active` goes through here
    /// (wait via the shared waiter, terminal via `terminalize`).
    /// Tests may still call `Lease.activate()` directly.
    private func executeLease(_ lease: Lease) async {
        guard checkCapabilities(for: lease.task) else {
            settle(lease, as: .failed)
            return
        }

        await withSlot(for: lease) {
            await self.runActivatedLease(lease)
        }
    }

    /// Scoped concurrency slot: acquire, re-check capability, activate, and
    /// always release on scope exit so no path can leak or double-release.
    private func withSlot(for lease: Lease, operation: @escaping () async -> Void) async {
        let slot = await concurrencyController.acquire(keys: lease.task.requiredCapabilities)
        lock.withLock { slotsByTaskId[lease.task.id] = slot }
        defer { releaseSlot(for: lease.task.id) }

        guard !lease.isTerminal else { return }
        guard checkCapabilities(for: lease.task) else {
            settle(lease, as: .failed)
            return
        }

        let activated: Bool = lock.withLock {
            guard !lease.isTerminal else { return false }
            lease.activate()
            activeLeases[lease.task.id] = lease
            deadlines[lease.task.id] = Date().addingTimeInterval(effectiveTimeout(for: lease.task))
            return true
        }
        guard activated else { return }

        eventSubject.send(.taskStarted(lease: lease))

        await operation()
    }

    private func runActivatedLease(_ lease: Lease) async {
        let taskExecution: (@Sendable () async -> Any?)? = lock.withLock {
            taskExecutions[lease.task.id]
        }

        let box = OneShot<Any?>()
        let executedFirst = await withTaskGroup(of: Bool.self) { group in
            group.addTask { @Sendable in
                let value = await taskExecution?()
                box.store(value)
                return true
            }

            group.addTask { @Sendable [lease] in
                try? await Task.sleep(nanoseconds: UInt64(self.effectiveTimeout(for: lease.task) * 1_000_000_000))
                return false
            }

            guard let first = await group.next() else {
                group.cancelAll()
                return false
            }
            group.cancelAll()
            return first
        }

        let value: Any? = executedFirst ? (box.load() ?? nil) : nil
        await settle(lease, result: value, timedOut: !executedFirst, execution: taskExecution)
    }
}
