import Foundation

/// Lifecycle tracker for scheduled tasks.
///
/// Transition contract (Settlement decides per ADR-0001/0004 — single reviewable
/// decision in the fused settle step (`TaskScheduler+Path.swift`); guards below are safety no-ops only):
/// - pending → active via `activate()`.
/// - active → completed/failed/expired via `terminalize(_:)`; terminal
///   states reject `activate`/`terminalize` as no-ops.
/// - `beginRetry()` resets to pending with cleared result and `retryCount + 1`.
/// Only `.expired` accepts pending: cancel-of-pending settles through the same
/// expired path (`TaskScheduler.settle(_:as:)` row transition), so
/// completed/failed staying active-only is intentional, not a missing case.
/// - Important: `@unchecked Sendable` is intentional — all mutations
///   (`activate`, `terminalize`, `beginRetry`) are `internal` and only
///   called by the lifecycle table seam only — `transition(for:to:)` plus the
///   fused displace core in `insert` (takeRow + terminalize(.expired)) — which
///   pairs each mutation with its row write under the scheduler lock. Never call them
///   directly from a new path. External code only reads state. Do not add public mutators.
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
    /// Legal only from pending; all other states are no-ops per the contract above.
    internal func activate() {
        guard isPending else { return }
        state = .active
        activatedAt = Date()
    }

    /// Phase table (intentional, do not fuse): public `Terminal` plus `SettleDirective` table owned here vs input `Settlement` (`cancelled`→`.expired`)
    /// vs pre-admission `ActivationGate` (never terminalizes).
    /// Retry reuses same Lease identity.
    /// Single terminal vocabulary for the Lease lifecycle, owned here.
    /// Tasks reuses it via `TaskScheduler.Terminal` (typealias, no duplicate).
    /// `Settlement` (Tasks input) shares this spelling for its terminal cases;
    /// `cancelled` stays input-only and maps to `.expired` at the single settle
    /// site. `Settlement.failed` carries no `Error`; the single transition
    /// mints the fresh execution error when applying `.failed`.
    /// `ActivationGate` stays pre-admission-only in the Path and never
    /// terminalizes; it is not a terminal row.
    internal enum Terminal {
        case completed(Any?)
        case failed(Error)
        case expired
    }

    /// Single settlement decision table (input → directive → terminal), owned
    /// here beside `Terminal`. Decision beside owner; effects stay in the Path.
    /// Rows: `cancelled`→expired plus void-nil plus `isActive` routing plus
    /// retry-budget (`canRetry` is a read-only view; the retry decision lives
    /// in this table, not in `canRetry`).
    internal enum SettleDirective {
        case retry
        case complete(Any?)
        case fail
        case expire
    }

    internal static func settleDecision(for outcome: TaskScheduler.Settlement, canRetry: Bool, isActive: Bool) -> SettleDirective {
        switch outcome {
        case .completed(let result):
            if result != nil {
                return .complete(result)
            }
            if canRetry {
                return .retry
            }
            return isActive ? .fail : .expire
        case .failed:
            return isActive ? .fail : .expire
        case .expired, .cancelled:
            return .expire
        }
    }

    /// Sole terminal writer; Settlement is the only caller.
    internal func terminalize(_ terminal: Terminal) {
        switch terminal {
        case .completed(let result):
            guard isActive else { return }
            self.result = result
            state = .completed
            completedAt = Date()
        case .failed(let error):
            guard isActive else { return }
            state = .failed(error)
            completedAt = Date()
        case .expired:
            guard !isTerminal else { return }
            state = .expired
            completedAt = Date()
        }
    }

    /// Whether retry budget remains (`retryCount < task.maxRetries`).
    /// Read-only view for Settlement; the retry decision lives there, not here.
    public var canRetry: Bool {
        retryCount < task.maxRetries
    }

    /// Resets to pending for another attempt and consumes one retry.
    /// Infallible primitive; callers check `canRetry` before calling.
    /// Clears `result`, `activatedAt`, and `completedAt` per the contract above.
    internal func beginRetry() {
        retryCount += 1
        state = .pending
        activatedAt = nil
        completedAt = nil
        result = nil
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
    /// Internal so Settlement can route failures for pending leases to expiry
    /// (completed/failed are active-only by contract).
    var isActive: Bool {
        if case .active = state { return true }
        return false
    }

    /// Whether the lease is currently pending.
    private var isPending: Bool {
        if case .pending = state { return true }
        return false
    }
}
