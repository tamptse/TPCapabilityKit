import Foundation

/// Type-safe wrapper around Lease that provides compile-time result type checking.
/// - Important: This is a read-only view. Lease mutations are still managed by TaskScheduler.
struct TypedLease<Result: Sendable>: Sendable {
    /// The underlying lease.
    let lease: Lease
    
    /// The task descriptor.
    var task: TaskDescriptor { lease.task }
    
    /// Current state of the lease.
    var state: Lease.State { lease.state }
    
    /// Whether the lease is in a terminal state.
    var isTerminal: Bool { lease.isTerminal }
    
    /// The typed result of the task execution, if completed successfully.
    /// Returns nil if not completed or if result type doesn't match.
    var typedResult: Result? {
        guard case .completed = state else { return nil }
        return lease.result as? Result
    }
    
    /// Creates a typed lease from an existing lease.
    /// - Parameter lease: The underlying lease to wrap.
    init(lease: Lease) {
        self.lease = lease
    }
}
