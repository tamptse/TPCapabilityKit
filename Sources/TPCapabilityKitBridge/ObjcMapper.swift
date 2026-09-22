import Foundation
import TPCapabilityKit

/// Single mapping point between Objective-C primitives and Swift domain types.
enum ObjcMapper {
    static func capability(from string: String) -> Capability {
        Capability(rawValue: string)
    }

    /// Maps a raw priority value to a domain priority.
    /// Out-of-range values coerce to `.normal` — the safe default that neither
    /// starves the task nor jumps the queue. Callers needing strict validation
    /// should clamp before crossing the Bridge.
    static func taskPriority(from rawValue: Int) -> TaskPriority {
        TaskPriority(rawValue: rawValue) ?? .normal
    }

    /// Maps an ObjC timeout to the Swift domain spelling: negative means
    /// unspecified (nil) so the scheduler default applies at enqueue.
    static func taskTimeout(from rawValue: TimeInterval) -> TimeInterval? {
        rawValue < 0 ? nil : rawValue
    }

    static func leaseState(from state: Lease.State) -> ObjcLease.State {
        switch state {
        case .pending: return .pending
        case .active: return .active
        case .completed: return .completed
        case .failed: return .failed
        case .expired: return .expired
        }
    }

    static func makeDescriptor(
        id: String? = nil,
        capabilities: [String],
        priority: Int,
        timeout: TimeInterval,
        maxRetries: Int,
        metadata: [String: String]
    ) -> TaskDescriptor {
        let caps = capabilities.map { capability(from: $0) }
        let fields = (
            priority: taskPriority(from: priority),
            timeout: taskTimeout(from: timeout)
        )
        if let id {
            return TaskDescriptor(
                id: id,
                requiredCapabilities: Set(caps),
                priority: fields.priority,
                timeout: fields.timeout,
                maxRetries: maxRetries,
                metadata: metadata
            )
        }
        return TaskDescriptor(
            requiredCapabilities: Set(caps),
            priority: fields.priority,
            timeout: fields.timeout,
            maxRetries: maxRetries,
            metadata: metadata
        )
    }
}

/// Shared box for passing non-Sendable ObjC closures into Tasks.
final class ObjcCallbackBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
