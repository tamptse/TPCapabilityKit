import Foundation
import TPCapabilityKit

/// Mapper-internal timeout form owning the omitted/unspecified/explicit fork once.
///
/// The @objc boundary spells timeout as a non-optional TimeInterval (negative
/// means unspecified), and Swift default arguments cannot distinguish an
/// omitted call from an explicit pin value — while both pin the compat
/// literal as explicit with identical downstream readings. Wire equal to the
/// pin literal therefore collapses to omitted, keeping three live branches at
/// this one site.
enum ObjcTimeout: Sendable {
    case omitted
    case unspecified
    case explicit(TimeInterval)

    /// Pinned compat default carried as explicit for omitted wire. Literal on
    /// purpose: it must never follow a reconfigured Swift default. Deadline
    /// construction stays the sole Swift resolver for nil timeouts.
    static let pinnedDefault: TimeInterval = 30.0

    /// Single statement of ObjC timeout compat: omitted pins the compat
    /// default as explicit; wire-negative means unspecified (nil, scheduler
    /// default applies at Deadline construction); explicit non-negative
    /// travels as explicit.
    static func resolve(wire: TimeInterval) -> ObjcTimeout {
        if wire < 0 { return .unspecified }
        if wire == pinnedDefault { return .omitted }
        return .explicit(wire)
    }

    /// Domain reading: omitted pins the literal as explicit, unspecified
    /// stays nil for Deadline construction, explicit travels unchanged.
    var resolved: TimeInterval? {
        switch self {
        case .omitted: Self.pinnedDefault
        case .unspecified: nil
        case .explicit(let value): value
        }
    }

    /// Collapsed display reading: the stored value when explicit, otherwise
    /// the pinned compat default.
    static func display(for descriptor: TaskDescriptor) -> TimeInterval {
        descriptor.timeout ?? pinnedDefault
    }

    /// Exact inverse of the display fallback above: true exactly when display
    /// returns the stored value rather than the pin.
    static func isExplicit(for descriptor: TaskDescriptor) -> Bool {
        descriptor.timeout != nil
    }
}

/// Single mapping point between Objective-C primitives and Swift domain types.
@usableFromInline enum ObjcMapper {
    /// Compat spelling of the pin literal, owned by `ObjcTimeout`.
    @usableFromInline static let omittedTimeout: TimeInterval = ObjcTimeout.pinnedDefault

    static func displayTimeout(for descriptor: TaskDescriptor) -> TimeInterval {
        ObjcTimeout.display(for: descriptor)
    }

    static func hasExplicitTimeout(for descriptor: TaskDescriptor) -> Bool {
        ObjcTimeout.isExplicit(for: descriptor)
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
        timeout: ObjcTimeout,
        maxRetries: Int,
        metadata: [String: String]
    ) -> TaskDescriptor {
        TaskDescriptor(
            id: id ?? UUID().uuidString,
            requiredCapabilities: Set(capabilities.map { capability(from: $0) }),
            priority: taskPriority(from: priority),
            timeout: timeout.resolved,
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
