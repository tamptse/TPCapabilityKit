import Combine
import Foundation
import Testing
@testable import TPCapabilityKit

@Suite("Registry Lock (Store seam)")
struct TPCapabilityKitRegistryLockTests {
    @Test("removal-vs-creation interleave does not diverge")
    func removalVsCreationNoDivergence() {
        let store = DynamicStore()
        let cap = Capability.custom("interleave_\(UUID().uuidString)")
        let pluginA = "InterleaveA_\(UUID().uuidString)"
        let pluginB = "InterleaveB_\(UUID().uuidString)"
        var received: [Bool] = []
        var cancellables = Set<AnyCancellable>()

        store.observeCapability(cap)
            .sink { received.append($0) }
            .store(in: &cancellables)
        #expect(received == [false])

        store.registerCapability(for: pluginA, capabilities: [cap])
        #expect(received.last == true)

        store.unregisterCapability(for: pluginA)
        #expect(received.last == false)

        store.registerCapability(for: pluginB, capabilities: [cap])
        #expect(store.queryCapability(cap) == true)
        #expect(received.last == true)

        store.unregisterCapability(for: pluginB)
        cancellables.removeAll()
    }

    @Test("per-capability notices land before snapshot publish")
    func perCapBeforeSnapshot() {
        let store = DynamicStore()
        let cap = Capability.custom("order_\(UUID().uuidString)")
        let pluginId = "Order_\(UUID().uuidString)"
        var order: [String] = []
        var cancellables = Set<AnyCancellable>()

        store.observeCapability(cap)
            .sink { _ in order.append("notify") }
            .store(in: &cancellables)
        store.observeAllCapabilities()
            .sink { snapshot in
                if !snapshot.isEmpty { order.append("snapshot") }
            }
            .store(in: &cancellables)
        order.removeAll()

        store.registerCapability(for: pluginId, capabilities: [cap])
        #expect(order == ["notify", "snapshot"])

        store.unregisterCapability(for: pluginId)
        cancellables.removeAll()
    }

    @Test("reentrant query from per-capability sink stays consistent")
    func reentrantQueryConsistent() {
        let store = DynamicStore()
        let cap = Capability.custom("reentrant_\(UUID().uuidString)")
        let pluginId = "Reentrant_\(UUID().uuidString)"
        var received: [Bool] = []
        var queried: [Bool] = []
        var cancellables = Set<AnyCancellable>()

        store.observeCapability(cap)
            .sink { value in
                received.append(value)
                queried.append(store.queryCapability(cap))
            }
            .store(in: &cancellables)

        store.registerCapability(for: pluginId, capabilities: [cap])
        store.unregisterCapability(for: pluginId)

        #expect(received == [false, true, false])
        #expect(queried == [false, true, false])
        cancellables.removeAll()
    }
}
