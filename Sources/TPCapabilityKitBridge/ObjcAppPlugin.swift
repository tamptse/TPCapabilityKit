import Foundation

/// Objective-C compatible protocol for plugins.
@objc(TPAppPlugin)
public protocol ObjcAppPlugin: NSObjectProtocol {
    /// Unique identifier for the plugin.
    @objc var id: String { get }

    /// Starts the plugin using the Objective-C store bridge.
    /// - Parameter store: The `ObjcStoreBridge` instance.
    @objc func start(with store: ObjcStoreBridge)
}
