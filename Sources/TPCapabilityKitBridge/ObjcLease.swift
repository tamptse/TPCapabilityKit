import Foundation
import TPCapabilityKit

/// Objective-C wrapper for Lease.
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

    /// When the lease was created.
    @objc public let createdAt: Date

    /// When the lease was activated (task started executing).
    @objc public private(set) var activatedAt: Date?

    /// When the lease completed (success or failure).
    @objc public private(set) var completedAt: Date?

    /// The result of the task execution, if completed successfully.
    @objc public private(set) var result: Any?

    /// Number of times this task has been retried.
    @objc public private(set) var retryCount: Int

    /// The underlying Swift Lease.
    public let underlying: Lease

    internal init(underlying: Lease) {
        self.underlying = underlying
        self.taskId = underlying.task.id
        self.state = State(rawValue: underlying.state.rawValue) ?? .pending
        self.createdAt = underlying.createdAt
        self.activatedAt = underlying.activatedAt
        self.completedAt = underlying.completedAt
        self.result = underlying.result
        self.retryCount = underlying.retryCount
        super.init()
    }
}
