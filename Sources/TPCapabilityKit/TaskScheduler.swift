import Foundation
import Combine

/// Internal error type for task execution failures.
private struct TaskExecutionError: Error, Sendable {}

/// Wrapper for non-Sendable values to pass through task groups.
private final class SendableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Centralized task scheduler that manages capability-based routing,
/// priority queuing, and lease lifecycle.
///
/// Inspired by Meta's Jupiter (capability matching) and Async (priority dispatching).
public final class TaskScheduler: TaskSchedulerProtocol, @unchecked Sendable {
    /// Configuration for the scheduler.
    public struct Configuration: Sendable {
        /// Default timeout for tasks if not specified in TaskDescriptor.
        public let defaultTimeout: TimeInterval

        /// Maximum number of tasks to process concurrently.
        public let concurrency: ConcurrencyController.Configuration

        public init(
            defaultTimeout: TimeInterval = 30.0,
            concurrency: ConcurrencyController.Configuration = .default
        ) {
            self.defaultTimeout = defaultTimeout
            self.concurrency = concurrency
        }
    }

    private let store: DynamicStore
    private let configuration: Configuration
    private let concurrencyController: ConcurrencyController
    private let lock = NSLock()

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

    // Subject for scheduler events
    private let eventSubject = PassthroughSubject<SchedulerEvent, Never>()

    /// Events emitted by the scheduler.
    public enum SchedulerEvent: Sendable {
        case taskScheduled(lease: Lease)
        case taskStarted(lease: Lease)
        case taskCompleted(lease: Lease)
        case taskFailed(lease: Lease, error: Error)
        case taskExpired(lease: Lease)
        case taskRetried(lease: Lease, attempt: Int)
    }

    /// Creates a new TaskScheduler.
    public init(store: DynamicStore = .shared, configuration: Configuration = .init()) {
        self.store = store
        self.configuration = configuration
        self.concurrencyController = ConcurrencyController(configuration: configuration.concurrency)
    }

    /// Publisher for scheduler events.
    public var events: AnyPublisher<SchedulerEvent, Never> {
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
    public func schedule(
        _ task: TaskDescriptor,
        taskExecution: @escaping @Sendable () async -> Void,
        completion: ((Lease) -> Void)? = nil,
        autoProcess: Bool = true
    ) -> Lease {
        let lease = Lease(task: task)

        lock.withLock {
            pendingTasks[task.priority]?.append(lease)
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
    public func scheduleAndWait<T: Sendable>(
        _ task: TaskDescriptor,
        taskExecution: @escaping @Sendable () async throws -> T
    ) async -> T? {
        let resultBox = SendableBox<T?>(nil)
        let completionLock = NSLock()

        return await withCheckedContinuation { continuation in
            var resumed = false

            // Schedule without auto-processing
            let lease = schedule(task, taskExecution: {
                // Empty closure - actual execution happens via taskExecutions
            }, completion: { lease in
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
            }, autoProcess: false)

            // Store the actual execution closure that returns a result
            lock.withLock {
                taskExecutions[task.id] = { @Sendable in
                    let value = try? await taskExecution()
                    resultBox.value = value
                    return value
                }
            }

            // Start execution in background
            Task {
                await executeLease(lease)
            }
        }
    }

    /// Cancels a pending task.
    /// - Parameter taskId: The ID of the task to cancel.
    public func cancel(taskId: String) {
        var cancelledLease: Lease?

        lock.withLock {
            // Remove from pending queues
            for priority in TaskPriority.allCases {
                if let index = pendingTasks[priority]?.firstIndex(where: { $0.task.id == taskId }) {
                    cancelledLease = pendingTasks[priority]?.remove(at: index)
                    break
                }
            }

            // Or expire if active
            if let lease = activeLeases[taskId] {
                lease.expire()
                eventSubject.send(.taskExpired(lease: lease))
            }
        }

        // If we found and removed from pending, expire it
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
    public var pendingCount: Int {
        lock.withLock {
            pendingTasks.values.reduce(0) { $0 + $1.count }
        }
    }

    /// Returns the number of active tasks.
    public var activeCount: Int {
        lock.withLock {
            activeLeases.count
        }
    }

    // MARK: - Private Methods

    private func processPendingTasks() async {
        // Process tasks in priority order
        while true {
            guard let nextLease = dequeueNext() else { break }

            // Check capability availability
            guard checkCapabilities(for: nextLease.task) else {
                // Re-queue and wait for capabilities
                lock.withLock {
                    pendingTasks[nextLease.task.priority]?.append(nextLease)
                }

                // Wait for capabilities then retry
                Task { await waitForCapabilitiesAndProcess(nextLease) }
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
            // Capability not available, fail the lease
            lock.withLock {
                activeLeases.removeValue(forKey: lease.task.id)
                let completion = completionHandlers.removeValue(forKey: lease.task.id)
                let error = TaskExecutionError()
                lease.fail(with: error)
                eventSubject.send(.taskFailed(lease: lease, error: error))
                completion?(lease)
            }
            return
        }

        // Acquire concurrency slot
        await concurrencyController.acquire(for: lease.task)

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
                }
                Task { await processPendingTasks() }
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
