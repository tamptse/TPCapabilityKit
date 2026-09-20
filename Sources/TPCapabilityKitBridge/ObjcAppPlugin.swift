import Foundation
import TPCapabilityKit

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

/// Adapter registering an Objective-C plugin with the Swift store.
/// Consumer-only contract: `ObjcAppPlugin` declares `id` + `start` but no
/// `capabilities`, so the adapter relies on `AppPlugin`'s default empty set.
/// ObjC Plugins consume capabilities via the Bridge (query/run/schedule) and
/// never satisfy capability queries — register a Swift `AppPlugin` to provide.
internal final class PluginObjcAdapter: AppPlugin {
    let id: String
    private let objcPlugin: ObjcAppPlugin
    private let bridge: ObjcStoreBridge

    init(objcPlugin: ObjcAppPlugin, bridge: ObjcStoreBridge) {
        self.id = objcPlugin.id
        self.objcPlugin = objcPlugin
        self.bridge = bridge
    }

    func start(with store: DynamicStore) {
        objcPlugin.start(with: bridge)
    }
}
