import Foundation

extension DynamicStore {
    // MARK: - Task Scheduling (facade over StoreSchedulingGenerations)

    var scheduler: TaskScheduler {
        scheduling.current(owner: self)
    }

    /// Reconfigures the scheduler without orphaning in-flight work (see StoreSchedulingGenerations).
    public func configureScheduler(_ configuration: TaskScheduler.Configuration) {
        scheduling.reconfigure(configuration, owner: self)
    }

    /// Deterministic-time delegates, spelling-only forwards to the generations module.
    internal func enableDeterministicTime(owner: DynamicStore) {
        scheduling.enableDeterministicTime(owner: owner)
    }

    internal func advanceTime(by delta: TimeInterval) async {
        await scheduling.advanceTime(by: delta)
    }

    internal func waitForDeterministicWaiters(count expected: Int) async {
        await scheduling.waitForDeterministicWaiters(count: expected)
    }

    /// Schedules a task for centralized execution with capability matching and priority.
    /// Queued work; for immediate fire see the entry table on `runIfAvailable`.
    /// - Parameters:
    ///   - descriptor: The task descriptor.
    ///   - task: The async closure to execute.
    ///   - completion: Optional completion handler.
    /// - Returns: The lease for tracking.
    @discardableResult
    public func scheduleTask(
        _ descriptor: TaskDescriptor,
        task: @escaping @Sendable () async -> Void,
        completion: ((Lease) -> Void)? = nil
    ) -> Lease {
        scheduler.schedule(descriptor, taskExecution: task, completion: completion)
    }

    /// Schedules a task and waits for its result.
    /// Queued-style entry to the one shared Tasks waiter (see `fire`);
    /// `runTaskWhenAvailable` is the single-capability convenience over the
    /// same core, so both styles behave identically.
    /// - Parameters:
    ///   - descriptor: The task descriptor.
    ///   - task: The async closure to execute.
    /// - Returns: The result, or nil if timeout/error.
    public func scheduleTaskAndWait<T: Sendable>(
        _ descriptor: TaskDescriptor,
        task: @escaping @Sendable () async throws -> T
    ) async -> T? {
        await fire(descriptor, task: task)
    }

    /// Cancels a pending task by its identifier.
    public func cancelTask(taskId: String) {
        scheduling.cancel(taskId: taskId)
    }

    /// Number of pending tasks, aggregated across live generations.
    public var pendingTaskCount: Int {
        scheduling.pendingCount
    }

    /// Number of active tasks, aggregated across live generations.
    public var activeTaskCount: Int {
        scheduling.activeCount
    }
}
