import Foundation
import TPCapabilityKit

/// Objective-C wrapper for Lease.
///
/// - Important: This wrapper captures a snapshot of the lease state at creation time.
///   If the underlying lease changes state after creation, call `refresh()` to sync.
///   Alternatively, access the `underlying` property for the live lease object.
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

    /// Current state of the lease.
    @objc public private(set) var state: State

    /// The result of the task execution, if completed successfully.
    @objc public private(set) var result: Any?

    /// The underlying Swift Lease.
    public let underlying: Lease

    internal init(underlying: Lease) {
        self.underlying = underlying
        self.taskId = underlying.task.id
        self.state = State(rawValue: underlying.state.rawValue) ?? .pending
        self.result = underlying.result
        super.init()
    }

    /// Refreshes cached state from the underlying lease.
    /// Call this after the underlying lease may have changed state.
    @objc public func refresh() {
        state = State(rawValue: underlying.state.rawValue) ?? .pending
        result = underlying.result
    }
}
