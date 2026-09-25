import Testing
import Foundation
@testable import TPCapabilityKit
@testable import TPCapabilityKitBridge

/// Pins the single sync-check seam: every sync entry crosses
/// `DynamicStore.runIfAvailable`, so sync results agree with each other and
/// with the waiter path by construction. Also pins the single empty-id guard
/// shared by state paths and capability paths.
struct SyncSeamTests {
    private func makeStore() -> DynamicStore {
        DynamicStore()
    }

    @Test func runIfAvailableReturnsValueWhenCapable() {
        let store = makeStore()
        let pluginId = "SyncSeam_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }

        let result = store.runIfAvailable(requiring: .heavyTask) { "ok" }
        #expect(result == "ok")
    }

    @Test func runIfAvailableNilWhenMissing() {
        let store = makeStore()
        let missing = Capability.custom("SyncSeamMissing_\(UUID().uuidString)")

        #expect(store.runIfAvailable(requiring: missing) { "ok" } == nil)
    }

    @Test func bridgeAndStoreSyncAgree() {
        let store = makeStore()
        let bridge = ObjcStoreBridge(store: store)
        let pluginId = "SyncSeamAgree_\(UUID().uuidString)"
        let missing = "SyncSeamMissing_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }

        let storeHit = store.runIfAvailable(requiring: .heavyTask) { NSString(string: "X") }
        let bridgeHit = bridge.taskScheduler.runIfAvailable(capability: "heavyTask") { NSString(string: "X") }
        #expect((storeHit as NSObject?) == (bridgeHit as NSObject?))
        #expect(storeHit != nil && bridgeHit != nil)

        let storeMiss: NSString? = store.runIfAvailable(requiring: .custom(missing)) { NSString(string: "X") }
        let bridgeMiss = bridge.taskScheduler.runIfAvailable(capability: missing) { NSString(string: "X") }
        #expect(storeMiss == nil && bridgeMiss == nil)
    }

    @Test func emptyPluginIdIsNoOpOnBothPaths() {
        let store = makeStore()
        store.registerCapability(for: "", capabilities: [.heavyTask])
        store.updateState(pluginId: "", newState: "junk")

        #expect(store.queryCapabilities(for: "") == [])
        #expect(store.getState(pluginId: "", type: String.self) == nil)
    }
}
