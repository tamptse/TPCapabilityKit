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
}
