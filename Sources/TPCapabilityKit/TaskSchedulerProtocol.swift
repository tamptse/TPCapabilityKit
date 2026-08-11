import Combine

/// Protocol defining the interface for task scheduling.
/// Enables A/B testing of different scheduling implementations.
public protocol TaskSchedulerProtocol: AnyObject, Sendable {
    /// Schedules a task for execution.
    func schedule(
        _ task: TaskDescriptor,
        taskExecution: @escaping @Sendable () async -> Void,
        completion: ((Lease) -> Void)?,
        autoProcess: Bool
    ) -> Lease

    /// Schedules a task and waits for its result.
    func scheduleAndWait<T: Sendable>(
        _ task: TaskDescriptor,
        taskExecution: @escaping @Sendable () async throws -> T
    ) async -> T?

    /// Cancels a pending task.
    func cancel(taskId: String)

    /// Number of pending tasks.
    var pendingCount: Int { get }

    /// Number of active tasks.
    var activeCount: Int { get }

    /// Publisher for scheduler events.
    var events: AnyPublisher<TaskScheduler.SchedulerEvent, Never> { get }
}
