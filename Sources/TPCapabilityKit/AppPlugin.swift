import Foundation

/// Protocol defining the interface for an application plugin in the micro-frontend architecture.
public protocol AppPlugin {
    /// Unique identifier for the plugin.
    var id: String { get }

    /// Initializes and starts the plugin with the shared dynamic store.
    /// - Parameter store: The `DynamicStore` instance used for state registration and observation.
    func start(with store: DynamicStore)
}

extension AppPlugin {
    /// Capabilities provided by this plugin.
    /// Default is empty. Override in conforming types or use `CapabilityProvider` for explicit declaration.
    public var capabilities: Set<Capability> { [] }
}
