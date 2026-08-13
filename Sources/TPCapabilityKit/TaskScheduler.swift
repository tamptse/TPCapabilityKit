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

    // Subject for scheduler events
    private let eventSubject = PassthroughSubject<SchedulerEvent, Never>()

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
        self.concurrencyController = ConcurrencyController(configuration: .init(maxPerCapability: configuration.maxPerCapability, maxGlobal: configuration.maxGlobal))
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
    ///   - autoProcess: Whether to automatically process pending tasks. Default is true.
    /// - Returns: The lease for tracking the task.
    @discardableResult
    func schedule(
        _ task: TaskDescriptor,
        taskExecution: @escaping @Sendable () async -> Void,
        completion: ((Lease) -> Void)? = nil,
        autoProcess: Bool = true
    ) -> Lease {
        let lease = Lease(task: task)

        lock.withLock {
            pendingTasks[task.priority]?.append(lease)
            _pendingCount += 1
            taskPriorityIndex[task.id] = task.priority
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
        var cancelledLease: Lease?
        var activeExpired = false
        var expiredLease: Lease?
        var expiredCompletion: ((Lease) -> Void)?

        lock.withLock {
            // Remove from pending queues using index
            if let priority = taskPriorityIndex[taskId],
               let index = pendingTasks[priority]?.firstIndex(where: { $0.task.id == taskId }) {
                cancelledLease = pendingTasks[priority]?.remove(at: index)
                _pendingCount -= 1
                taskPriorityIndex.removeValue(forKey: taskId)
            }

            // Check if active and expire atomically
            if let lease = activeLeases.removeValue(forKey: taskId) {
                lease.expire()
                expiredLease = lease
                expiredCompletion = completionHandlers.removeValue(forKey: taskId)
                activeExpired = true
            }
        }

        // Handle active task expiration
        if activeExpired, let lease = expiredLease {
            eventSubject.send(.taskExpired(lease: lease))
            expiredCompletion?(lease)
            return
        }

        // Handle pending task expiration
        if let lease = cancelledLease {
            lease.expire()
            eventSubject.send(.taskExpired(lease: lease))

            // Call completion handler
            let completion: ((Lease) -> Void)? = lock.withLock {
                completionHandlers.removeValue(forKey: taskId)
            }
            completion?(lease)
        }
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

    private func failLease(_ lease: Lease) {
        lock.withLock {
            activeLeases.removeValue(forKey: lease.task.id)
            let completion = completionHandlers.removeValue(forKey: lease.task.id)
            let error = TaskExecutionError()
            lease.fail(with: error)
            eventSubject.send(.taskFailed(lease: lease, error: error))
            completion?(lease)
        }
    }

    private func processPendingTasks() async {
        // Process tasks in priority order
        while true {
            guard let nextLease = dequeueNext() else { break }

            // Check capability availability
            guard checkCapabilities(for: nextLease.task) else {
                // Re-queue and wait for capabilities
                lock.withLock {
                    pendingTasks[nextLease.task.priority]?.append(nextLease)
                    _pendingCount += 1
                    taskPriorityIndex[nextLease.task.id] = nextLease.task.priority
                }

                // Wait for capabilities then retry
                await taskStore.store(Task { await waitForCapabilitiesAndProcess(nextLease) })
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

        guard capabilityAvailable else {
            // Timeout, expire the lease
            lock.withLock {
                let completion = completionHandlers.removeValue(forKey: lease.task.id)
                taskExecutions.removeValue(forKey: lease.task.id)
                lease.expire()
                eventSubject.send(.taskExpired(lease: lease))
                completion?(lease)
            }
            return
        }

        // Execute the task
        await executeLease(lease)
    }

    /// Waits for capabilities to become available with a timeout.
    /// - Returns: `true` if all capabilities are available, `false` if timeout.
    private func waitForCapabilitiesWithTimeout(_ task: TaskDescriptor) async -> Bool {
        // Fast path: already available
        if checkCapabilities(for: task) { return true }

        // Wait for capabilities with timeout
        return await withTaskGroup(of: Bool.self) { group in
            // Task: wait for capabilities
            group.addTask { [self] in
                for cap in task.requiredCapabilities {
                    for await isAvailable in self.store.observeCapability(cap).values {
                        if isAvailable { break }
                    }
                }
                return self.checkCapabilities(for: task)
            }

            // Task: timeout
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(task.timeout * 1_000_000_000))
                return false
            }

            // Return first result, cancel the other
            guard let result = await group.next() else {
                group.cancelAll()
                return false
            }
            group.cancelAll()
            return result
        }
    }

    private func executeLease(_ lease: Lease) async {
        // Check if capability is available
        guard checkCapabilities(for: lease.task) else {
            failLease(lease)
            return
        }

        // Acquire concurrency slot
        await concurrencyController.acquire(for: lease.task)

        // Re-check capabilities after acquiring slot (capability may have been revoked)
        guard checkCapabilities(for: lease.task) else {
            await concurrencyController.release(for: lease.task)
            failLease(lease)
            return
        }

        // Activate lease
        lease.activate()
        lock.withLock {
            activeLeases[lease.task.id] = lease
        }

        eventSubject.send(.taskStarted(lease: lease))

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

        // Complete lease
        let completion: ((Lease) -> Void)? = lock.withLock {
            activeLeases.removeValue(forKey: lease.task.id)
            return completionHandlers.removeValue(forKey: lease.task.id)
        }

        await concurrencyController.release(for: lease.task)

        if let result = result?.value {
            lease.complete(with: result)
            eventSubject.send(.taskCompleted(lease: lease))
        } else {
            // Check if it was a timeout or retryable failure
            if lease.hasExpired {
                lease.expire()
                eventSubject.send(.taskExpired(lease: lease))
            } else if lease.retry() {
                eventSubject.send(.taskRetried(lease: lease, attempt: lease.retryCount))
                lock.withLock {
                    pendingTasks[lease.task.priority]?.append(lease)
                    _pendingCount += 1
                    taskPriorityIndex[lease.task.id] = lease.task.priority
                }
                await taskStore.store(Task { await processPendingTasks() })
                return
            } else {
                let error = TaskExecutionError()
                lease.fail(with: error)
                eventSubject.send(.taskFailed(lease: lease, error: error))
            }
        }

        completion?(lease)
    }
}

extension TaskPriority: CaseIterable {
    public static var allCases: [TaskPriority] {
        [.background, .low, .normal, .high, .critical]
    }
}
