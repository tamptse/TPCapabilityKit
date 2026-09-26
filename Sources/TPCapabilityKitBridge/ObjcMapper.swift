import Foundation
import TPCapabilityKit

/// Mapper-internal timeout form owning the unspecified/explicit fork once.
///
/// The @objc boundary spells timeout as a non-optional TimeInterval (negative
/// means unspecified). An omitted call arrives as the pin literal, which
/// collapses to explicit on purpose per ADR-0020: downstream only distinguishes
/// nil from non-nil, so explicit pin and omitted read identically.
@usableFromInline enum ObjcTimeout: Sendable {
    case unspecified
    case explicit(TimeInterval)

    /// Pinned compat default carried as explicit for omitted wire. Literal on
    /// purpose: it must never follow a reconfigured Swift default. Deadline
    /// construction stays the sole Swift resolver for nil timeouts.
    /// Display is lossy: absent displays as this pin, so rebuilding from display
    /// alone promotes to explicit pin; honor hasExplicitTimeout (absent travels
    /// as wire-negative) to preserve the distinction.
    @usableFromInline static let pinnedDefault: TimeInterval = 30.0

    /// Single statement of ObjC timeout compat: wire-negative means unspecified
    /// (nil, scheduler default applies at Deadline construction); every
    /// non-negative wire travels as explicit, with wire equal to the pin
    /// literal collapsing to explicit(pinnedDefault) per ADR-0020.
    static func resolve(wire: TimeInterval) -> ObjcTimeout {
        if wire < 0 { return .unspecified }
        return .explicit(wire)
    }

    /// Domain reading: unspecified stays nil for Deadline construction,
    /// explicit travels unchanged.
    var resolved: TimeInterval? {
        switch self {
        case .unspecified: nil
        case .explicit(let value): value
        }
    }

    /// Collapsed display reading: the stored value when explicit, otherwise
    /// the pinned compat default.
    var display: TimeInterval {
        switch self {
        case .unspecified: Self.pinnedDefault
        case .explicit(let value): value
        }
    }

    /// Explicitness flag: true exactly when display returns the stored value
    /// rather than the pin.
    var isExplicit: Bool {
        switch self {
        case .unspecified: false
        case .explicit: true
        }
    }

    /// Live-view mapping from an already-resolved domain value. Nil stays
    /// unspecified; non-nil travels as explicit without touching the wire fork.
    static func fromStored(_ value: TimeInterval?) -> ObjcTimeout {
        switch value {
        case .none: .unspecified
        case .some(let stored): .explicit(stored)
        }
    }
}

/// Single mapping point between Objective-C primitives and Swift domain types.
@usableFromInline enum ObjcMapper {
    static func capability(from string: String) -> Capability {
        Capability(rawValue: string)
    }

    /// Single statement of the valid ObjC priority range, shared by the
    /// coercion below and the strict validity check, so the next range
    /// change touches one place.
    @usableFromInline static let validPriorityRange: ClosedRange<Int> =
        TaskPriority.background.rawValue...TaskPriority.critical.rawValue

    /// Maps a raw priority value to a domain priority.
    /// Out-of-range values coerce to `.normal` — the safe default that neither
    /// starves the task nor jumps the queue. Callers needing strict validation
    /// should clamp before crossing the Bridge.
    static func taskPriority(from rawValue: Int) -> TaskPriority {
        guard validPriorityRange.contains(rawValue),
            let priority = TaskPriority(rawValue: rawValue)
        else {
            #if DEBUG
            print("[ObjcStoreBridge] Warning: coerced out-of-range priority \(rawValue) to normal")
            #endif
            return .normal
        }
        return priority
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
