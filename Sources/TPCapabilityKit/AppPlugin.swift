import Foundation

/// Protocol defining the interface for an application plugin in the micro-frontend architecture.
public protocol AppPlugin {
    /// Unique identifier for the plugin.
    var id: String { get }

    /// Capabilities provided by this plugin.
    var capabilities: Set<Capability> { get }

    /// Initializes and starts the plugin with the shared dynamic store.
    /// - Parameter store: The `DynamicStore` instance used for state registration and observation.
    func start(with store: DynamicStore)
}

extension AppPlugin {
    /// Default is empty. Override in conforming types to declare provided capabilities.
    public var capabilities: Set<Capability> { [] }
}
