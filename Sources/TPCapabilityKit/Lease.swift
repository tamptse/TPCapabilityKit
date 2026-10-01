import Foundation

/// Lifecycle tracker for scheduled tasks.
///
/// Dumb state only (Settlement decides per ADR-0001/0004 in the fused settle
/// step (`TaskScheduler+Path.swift`); guards below are safety no-ops only):
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

    public let task: TaskDescriptor

    public private(set) var state: State

    let createdAt: Date

    private(set) var activatedAt: Date?

    private(set) var completedAt: Date?

    public private(set) var result: Any?

    private(set) var retryCount: Int

    init(task: TaskDescriptor) {
        self.task = task
        self.state = .pending
        self.createdAt = Date()
        self.retryCount = 0
    }

    /// Legal only from pending; all other states are no-ops per the contract above.
    internal func activate() {
        guard isPending else { return }
        state = .active
        activatedAt = Date()
    }

    /// Single terminal vocabulary for the Lease lifecycle, owned here.
    /// Tasks reuses it via `TaskScheduler.Terminal` (typealias, no duplicate).
    /// `Settlement.failed` carries no `Error`; the fused settle mints the
    /// fresh execution error when applying `.failed`.
    internal enum Terminal {
        case completed(Any?)
        case failed(Error)
        case expired
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

    /// Internal so Settlement can route failures for pending leases to expiry
    /// (completed/failed are active-only by contract).
    var isActive: Bool {
        if case .active = state { return true }
        return false
    }

    private var isPending: Bool {
        if case .pending = state { return true }
        return false
    }
}
