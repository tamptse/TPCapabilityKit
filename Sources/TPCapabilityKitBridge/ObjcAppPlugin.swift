import Foundation

/// Objective-C compatible protocol for plugins.
///
/// Consumer-only contract: conformers declare `id` + `start` but no
/// `capabilities`, so plugins registered through the Bridge never satisfy
/// capability queries. Consume capabilities via `ObjcStoreBridge`
/// (query/run/schedule); provide them with a Swift `AppPlugin` instead.
@objc(TPAppPlugin)
public protocol ObjcAppPlugin: NSObjectProtocol {
    /// Unique identifier for the plugin.
    @objc var id: String { get }

    /// Starts the plugin using the Objective-C store bridge.
    /// - Parameter store: The `ObjcStoreBridge` instance.
    @objc func start(with store: ObjcStoreBridge)
}
