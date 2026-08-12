import Foundation

/// Represents a capability that a plugin can provide to the system.
/// Plugins declare capabilities at registration time; the central store
/// maintains a registry and exposes query/observation APIs.
public enum Capability: Hashable, Sendable {
    case heavyTask
    case lightTask
    case networkAccess
    case backgroundExecution
    case custom(String)

    /// String representation for ObjC bridge compatibility and debugging.
    public var rawValue: String {
        switch self {
        case .heavyTask: return "heavyTask"
        case .lightTask: return "lightTask"
        case .networkAccess: return "networkAccess"
        case .backgroundExecution: return "backgroundExecution"
        case .custom(let value): return value
        }
    }

    /// Initialize from a string identifier.
    /// Known capabilities return their specific case.
    /// Unknown strings return `.custom(rawValue)` for consistent querying.
    public init(rawValue: String) {
        switch rawValue {
        case "heavyTask": self = .heavyTask
        case "lightTask": self = .lightTask
        case "networkAccess": self = .networkAccess
        case "backgroundExecution": self = .backgroundExecution
        default: self = .custom(rawValue)
        }
    }
}

/// Protocol for plugins that declare capabilities beyond basic state management.
/// Conforming to this protocol allows the plugin to be auto-registered
/// in the capability registry when `DynamicStore.register(plugin:)` is called.
public protocol CapabilityProvider: AppPlugin {
    /// The set of capabilities this plugin provides.
    var capabilities: Set<Capability> { get }
}
