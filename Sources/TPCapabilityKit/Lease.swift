import Foundation

/// Represents the lifecycle of a scheduled task execution.
/// A lease tracks the task from scheduling through completion or failure.
///
/// - Note: This class is `@unchecked Sendable` because it requires mutable state
///   for lifecycle management. All mutations should be coordinated through the
///   TaskScheduler to ensure thread safety.
public final class Lease: @unchecked Sendable {
    /// State of the lease.
    public enum State: Sendable, Equatable {
        case pending
        case active
        case completed
        case failed(Error)
        case expired

        public static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.pending, .pending), (.active, .active), (.completed, .completed), (.expired, .expired):
                return true
            case (.failed, .failed):
                return true
            default:
                return false
            }
        }
    }

    /// The task descriptor this lease is for.
    public let task: TaskDescriptor

    /// Current state of the lease.
    public private(set) var state: State

    /// When the lease was created.
    public let createdAt: Date

    /// When the lease was activated (task started executing).
    public private(set) var activatedAt: Date?

    /// When the lease completed (success or failure).
    public private(set) var completedAt: Date?

    /// The result of the task execution, if completed successfully.
    public private(set) var result: Any?

    /// Number of times this task has been retried.
    public private(set) var retryCount: Int

    /// Creates a new lease for a task.
    public init(task: TaskDescriptor) {
        self.task = task
        self.state = .pending
        self.createdAt = Date()
        self.retryCount = 0
    }

    /// Marks the lease as active (task started executing).
    public func activate() {
        guard isPending else { return }
        state = .active
        activatedAt = Date()
    }

    /// Marks the lease as completed with a result.
    public func complete(with result: Any?) {
        guard isActive else { return }
        self.result = result
        state = .completed
        completedAt = Date()
    }

    /// Marks the lease as failed with an error.
    public func fail(with error: Error) {
        guard isActive else { return }
        state = .failed(error)
        completedAt = Date()
    }

    /// Marks the lease as expired (timeout reached).
    public func expire() {
        state = .expired
        completedAt = Date()
    }

    /// Increments retry count and resets to pending state.
    /// Returns true if retries remain, false if max retries exceeded.
    @discardableResult
    public func retry() -> Bool {
        guard retryCount < task.maxRetries else { return false }
        retryCount += 1
        state = .pending
        activatedAt = nil
        completedAt = nil
        result = nil
        return true
    }

    /// Whether the lease is in a terminal state (completed, failed, or expired).
    public var isTerminal: Bool {
        switch state {
        case .completed, .failed, .expired:
            return true
        case .pending, .active:
            return false
        }
    }

    /// Whether the lease is currently active.
    private var isActive: Bool {
        if case .active = state { return true }
        return false
    }

    /// Whether the lease is currently pending.
    private var isPending: Bool {
        if case .pending = state { return true }
        return false
    }

    /// Whether the lease has exceeded its timeout.
    public var hasExpired: Bool {
        let deadline = activatedAt ?? createdAt
        return Date().timeIntervalSince(deadline) > task.timeout
    }
}
