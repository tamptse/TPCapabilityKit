import Testing
import Foundation
@testable import TPCapabilityKit

/// Pins the Tasks waiter through the registry seam only: readiness resolves
/// via register/unregister with no direct snapshot subscription in the test,
/// partial sets stay parked, empty sets run immediately, and missing sets
/// expire on the single Deadline.
@Suite("Waiter Through Interface Tests")
struct WaiterThroughInterfaceTests {
    @Test("partial set stays parked until the whole set registers")
    func partialSetStaysParked() async {
        let store = DynamicStore()
        let capA = Capability.custom("waiterIfaceA_\(UUID().uuidString)")
        let capB = Capability.custom("waiterIfaceB_\(UUID().uuidString)")
        let pluginA = "WaiterIfaceA_\(UUID().uuidString)"
        let pluginB = "WaiterIfaceB_\(UUID().uuidString)"
        defer {
            store.unregisterCapability(for: pluginA)
            store.unregisterCapability(for: pluginB)
        }

        async let result: String? = store.scheduleTaskAndWait(
            TaskDescriptor(requiredCapabilities: [capA, capB], timeout: 10.0)
        ) {
            return "ready"
        }

        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(store.pendingTaskCount == 1)

        store.registerCapability(for: pluginA, capabilities: [capA])
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(store.pendingTaskCount == 1)

        store.registerCapability(for: pluginB, capabilities: [capB])
        #expect(await result == "ready")
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("unregister before completion keeps the waiter parked")
    func unregisterKeepsWaiterParked() async {
        let store = DynamicStore()
        let cap = Capability.custom("waiterIfaceUnreg_\(UUID().uuidString)")
        let pluginId = "WaiterIfaceUnreg_\(UUID().uuidString)"
        defer { store.unregisterCapability(for: pluginId) }

        async let result: String? = store.scheduleTaskAndWait(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 10.0)
        ) {
            return "ready"
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        store.registerCapability(for: pluginId, capabilities: [cap])
        store.unregisterCapability(for: pluginId)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(store.pendingTaskCount == 1)

        store.registerCapability(for: pluginId, capabilities: [cap])
        #expect(await result == "ready")
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("empty set runs without waiting")
    func emptySetRunsImmediately() async {
        let store = DynamicStore()
        let result: String? = await store.scheduleTaskAndWait(
            TaskDescriptor(requiredCapabilities: [], timeout: 5.0)
        ) {
            return "immediate"
        }
        #expect(result == "immediate")
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("missing set expires on the single Deadline")
    func missingSetExpires() async {
        let store = DynamicStore()
        store.enableDeterministicTime()
        let missing = Capability.custom("waiterIfaceMissing_\(UUID().uuidString)")
        async let result: String? = store.scheduleTaskAndWait(
            TaskDescriptor(requiredCapabilities: [missing], timeout: 5.0)
        ) {
            return "should-not-run"
        }
        await store.advanceTime(by: 5.0)
        #expect(await result == nil)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
