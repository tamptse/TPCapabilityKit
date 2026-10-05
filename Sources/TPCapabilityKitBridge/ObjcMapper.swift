import Foundation
import TPCapabilityKit

/// Single owner of ObjC timeout compat (fork plus pin plus display plus explicitness).
///
/// Whole fork stated once here; callers pass through without re-branching.
/// Wire-negative arrives unspecified with the scheduler default applying at
/// `Deadline` construction, every non-negative wire (including the pin
/// literal) travels explicit unchanged, and an omitted call arrives as the
/// pin carried explicit so reconfigure never silently moves it. Collapsed
/// display falls back to the pin while explicitness preserves the distinction
/// for rebuild. `Deadline` construction in `Time.swift` stays the sole
/// resolver of unspecified (nil) timeouts.
@usableFromInline enum ObjcTimeout: Sendable {
    case unspecified
    case explicit(TimeInterval)

    /// Compat pin for omitted wire. Literal on purpose per ADR-0020: it must
    /// never follow a reconfigured Swift default.
    @usableFromInline static let pinnedDefault: TimeInterval = 30.0

    /// Omitted call spelled once: the pin carried explicit.
    @usableFromInline static var omitted: Self { .explicit(pinnedDefault) }

    /// Wire entry; unspecified stays nil for `Deadline` to resolve.
    static func resolve(wire: TimeInterval) -> ObjcTimeout {
        if wire < 0 { return .unspecified }
        return .explicit(wire)
    }

    /// Domain value for `TaskDescriptor.timeout`.
    var resolved: TimeInterval? {
        switch self {
        case .unspecified: nil
        case .explicit(let value): value
        }
    }

    /// Collapsed read; pair with `isExplicit` when rebuilding from display.
    var display: TimeInterval {
        switch self {
        case .unspecified: Self.pinnedDefault
        case .explicit(let value): value
        }
    }

    /// Pair with `display` on rebuild so display-alone never silently promotes.
    var isExplicit: Bool {
        switch self {
        case .unspecified: false
        case .explicit: true
        }
    }

    /// Live-view entry that bypasses the wire fork.
    static func fromStored(_ value: TimeInterval?) -> ObjcTimeout {
        switch value {
        case .none: .unspecified
        case .some(let stored): .explicit(stored)
        }
    }
}

/// Single mapping point between Objective-C primitives and Swift domain types.
///
/// Pure mapping only: capability rename, priority range with coercion plus
/// strict query. Timeout compat lives solely in `ObjcTimeout`; descriptor
/// construction lives with the door and the descriptor wrapper.
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
    /// should check `isValidPriority` before crossing the Bridge.
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

    /// Strict validity query over the single shared range. Reports only;
    /// never coerces, schedules, or stores.
    static func isValidPriority(_ rawValue: Int) -> Bool {
        validPriorityRange.contains(rawValue)
    }
}
