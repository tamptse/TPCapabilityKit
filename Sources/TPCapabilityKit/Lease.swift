import Foundation

/// Lifecycle tracker for scheduled tasks.
/// - Important: `@unchecked Sendable` is intentional — all mutations
///   (`activate`, `complete`, `fail`, `expire`, `retry`) are `internal`
///   and only called by `TaskScheduler` which coordinates access via its
///   own lock. External code only reads state. Do not add public mutators.
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
    let createdAt: Date

    /// When the lease was activated (task started executing).
    private(set) var activatedAt: Date?

    /// When the lease completed (success or failure).
    private(set) var completedAt: Date?

    /// The result of the task execution, if completed successfully.
    public private(set) var result: Any?

    /// Number of times this task has been retried.
    private(set) var retryCount: Int

    /// Creates a new lease for a task.
    init(task: TaskDescriptor) {
        self.task = task
        self.state = .pending
        self.createdAt = Date()
        self.retryCount = 0
    }

    /// Marks the lease as active (task started executing).
    func activate() {
        guard isPending else { return }
        state = .active
        activatedAt = Date()
    }

    /// Marks the lease as completed with a result.
    func complete(with result: Any?) {
        guard isActive else { return }
        self.result = result
        state = .completed
        completedAt = Date()
    }

    /// Marks the lease as failed with an error.
    func fail(with error: Error) {
        guard isActive else { return }
        state = .failed(error)
        completedAt = Date()
    }

    /// Marks the lease as expired (timeout reached).
    func expire() {
        guard !isTerminal else { return }
        state = .expired
        completedAt = Date()
    }

    /// Increments retry count and resets to pending state.
    /// Returns true if retries remain, false if max retries exceeded.
    @discardableResult
    func retry() -> Bool {
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
    var hasExpired: Bool {
        let deadline = activatedAt ?? createdAt
        return Date().timeIntervalSince(deadline) > task.timeout
    }
}

extension Lease.State {
    public var rawValue: Int {
        switch self {
        case .pending: return 0
        case .active: return 1
        case .completed: return 2
        case .failed: return 3
        case .expired: return 4
        }
    }
}
