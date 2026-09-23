import Foundation
import TPCapabilityKit

/// Objective-C wrapper for Lease.
///
/// A live view over the underlying lease: `state` and `result` read through
/// on every access, so there is no snapshot to refresh and no sync call.
/// `taskId` is pinned at construction because task identity never changes.
/// Freshness: state reflects the latest transition at read time; terminal
/// reads (`completed`/`failed`/`expired`) are stable once observed.
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
    /// Mapping stays an exhaustive switch co-located with this view, so new
    /// lease states fail visibly here.
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
