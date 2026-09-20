import Foundation
import TPCapabilityKit

/// Objective-C wrapper for Lease.
///
/// Reads live state from the underlying lease; no manual sync needed.
@objc(TPLease)
public final class ObjcLease: NSObject, @unchecked Sendable {
    /// Lease state for ObjC consumers.
    @objc public enum State: Int {
        case pending = 0
        case active = 1
        case completed = 2
        case failed = 3
        case expired = 4
    }

    /// Task identifier this lease is for.
    @objc public let taskId: String

    /// Current state of the lease, read live from the underlying lease.
    /// Exhaustive switch keeps the mapping explicit: if `Lease.State` gains a
    /// case, this fails to compile instead of silently coercing.
    @objc public var state: State {
        switch underlying.state {
        case .pending: return .pending
        case .active: return .active
        case .completed: return .completed
        case .failed: return .failed
        case .expired: return .expired
        }
    }

    /// The result of the task execution, if completed successfully.
    @objc public var result: Any? {
        underlying.result
    }

    /// The underlying Swift Lease.
    public let underlying: Lease

    internal init(underlying: Lease) {
        self.underlying = underlying
        self.taskId = underlying.task.id
        super.init()
    }
}
