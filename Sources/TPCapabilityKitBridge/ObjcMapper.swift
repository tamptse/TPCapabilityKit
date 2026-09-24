import Foundation
import TPCapabilityKit

/// Single mapping point between Objective-C primitives and Swift domain types.
@usableFromInline enum ObjcMapper {
    /// Pinned compat default carried as explicit for omitted wire. Literal on
    /// purpose: it must never follow a reconfigured Swift default. Deadline
    /// construction stays the sole Swift resolver for nil timeouts.
    @usableFromInline static let omittedTimeout: TimeInterval = 30.0

    /// Single statement of ObjC timeout compat, shared by both descriptor
    /// initializers and the wait-then-run entry: omitted (nil wire) pins the
    /// compat default as explicit; wire-negative means unspecified
    /// (nil, scheduler default applies at Deadline construction); explicit non-negative
    /// travels as explicit. Swift nil (wrapped descriptors) resolves at
    /// Deadline construction and never crosses this resolver.
    static func resolveTimeout(wire: TimeInterval?) -> TimeInterval? {
        guard let wire else { return omittedTimeout }
        return wire < 0 ? nil : wire
    }

    static func displayTimeout(for descriptor: TaskDescriptor) -> TimeInterval {
        descriptor.timeout ?? omittedTimeout
    }

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

    static func makeDescriptor(
        id: String? = nil,
        capabilities: [String],
        priority: Int,
        timeout: TimeInterval,
        maxRetries: Int,
        metadata: [String: String]
    ) -> TaskDescriptor {
        TaskDescriptor(
            id: id ?? UUID().uuidString,
            requiredCapabilities: Set(capabilities.map { capability(from: $0) }),
            priority: taskPriority(from: priority),
            timeout: resolveTimeout(wire: timeout),
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
