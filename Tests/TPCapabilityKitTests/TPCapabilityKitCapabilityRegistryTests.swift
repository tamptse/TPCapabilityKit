@preconcurrency import Foundation
import Combine
import Testing
@testable import TPCapabilityKit

@Suite("CapabilityRegistry Tests")
struct TPCapabilityKitCapabilityRegistryTests {
    @Test("query true after register, false after unregister")
    func queryAfterRegisterUnregister() {
        let registry = CapabilityRegistry()
        let pluginId = "RegQuery_\(UUID().uuidString)"
        let cap = Capability.custom("regQuery_\(UUID().uuidString)")

        #expect(registry.query(cap) == false)

        registry.register(for: pluginId, capabilities: [cap])
        #expect(registry.queryAll()[pluginId] == [cap])
        #expect(registry.query(cap) == true)
        #expect(registry.queryCapabilities(for: pluginId) == [cap])

        registry.unregister(for: pluginId)
        #expect(registry.queryAll()[pluginId] == nil)
        #expect(registry.query(cap) == false)
        #expect(registry.queryCapabilities(for: pluginId) == [])
    }

    @Test("re-register replaces old capabilities")
    func reRegisterReplacesOldCapabilities() {
        let registry = CapabilityRegistry()
        let pluginId = "RegReplace_\(UUID().uuidString)"

        registry.register(for: pluginId, capabilities: [.heavyTask, .lightTask])
        #expect(registry.queryAll()[pluginId] == [.heavyTask, .lightTask])
        #expect(registry.query(.heavyTask) == true)
        #expect(registry.query(.lightTask) == true)

        registry.register(for: pluginId, capabilities: [.networkAccess])
        #expect(registry.queryAll()[pluginId] == [.networkAccess])
        #expect(registry.query(.networkAccess) == true)
        #expect(registry.queryCapabilities(for: pluginId) == [.networkAccess])

        let snapshot = registry.queryAll()
        #expect(snapshot[pluginId] == [.networkAccess])
    }

    @Test("unregister emptied capability emits false and retains subject for reuse")
    func unregisterCleanupEmitsFalse() {
        let registry = CapabilityRegistry()
        let pluginId = "RegCleanup_\(UUID().uuidString)"
        let cap = Capability.custom("regCleanup_\(UUID().uuidString)")
        var cancellables = Set<AnyCancellable>()

        var received: [Bool] = []
        registry.observe(cap)
            .sink { received.append($0) }
            .store(in: &cancellables)
        #expect(received.last == false)

        registry.register(for: pluginId, capabilities: [cap])
        #expect(received.last == true)
        #expect(registry.query(cap) == true)

        registry.unregister(for: pluginId)

        #expect(received.last == false)
        #expect(registry.query(cap) == false)
        #expect(registry.queryAll()[pluginId] == nil)

        let otherPlugin = "RegCleanupOther_\(UUID().uuidString)"
        registry.register(for: otherPlugin, capabilities: [cap])
        #expect(received.last == true)
        #expect(registry.query(cap) == true)
        registry.unregister(for: otherPlugin)

        cancellables.removeAll()
    }

    @Test("snapshot reflects current plugin mapping")
    func snapshotContents() {
        let registry = CapabilityRegistry()
        let pluginId1 = "RegSnap1_\(UUID().uuidString)"
        let pluginId2 = "RegSnap2_\(UUID().uuidString)"

        registry.register(for: pluginId1, capabilities: [.heavyTask])
        registry.register(for: pluginId2, capabilities: [.lightTask, .networkAccess])

        let snapshot = registry.queryAll()
        #expect(snapshot[pluginId1]?.contains(.heavyTask) == true)
        #expect(snapshot[pluginId2]?.contains(.lightTask) == true)
        #expect(snapshot[pluginId2]?.contains(.networkAccess) == true)

        var observedSnapshots: [[String: Set<Capability>]] = []
        var cancellables = Set<AnyCancellable>()
        registry.observeAll()
            .sink { observedSnapshots.append($0) }
            .store(in: &cancellables)
        registry.register(for: "RegSnap3_\(UUID().uuidString)", capabilities: [.backgroundExecution])
        #expect(registry.queryAll().count == 3)
        #expect(observedSnapshots.last?[pluginId1]?.contains(.heavyTask) == true)

        cancellables.removeAll()
    }

    @Test("per-capability observer receives true then false")
    func observerTrueFalseTransitions() {
        let registry = CapabilityRegistry()
        let pluginId = "RegObserve_\(UUID().uuidString)"
        let cap = Capability.custom("regObserve_\(UUID().uuidString)")
        var received: [Bool] = []
        var cancellables = Set<AnyCancellable>()

        registry.observe(cap)
            .sink { received.append($0) }
            .store(in: &cancellables)
        #expect(received == [false])

        registry.register(for: pluginId, capabilities: [cap])
        #expect(received == [false, true])

        registry.unregister(for: pluginId)
        #expect(received == [false, true, false])

        cancellables.removeAll()
    }

    @Test("emit helper sends notifications before snapshot")
    func emitNotificationsBeforeSnapshot() {
        let registry = CapabilityRegistry()
        let pluginId = "RegEmitOrder_\(UUID().uuidString)"
        let cap = Capability.custom("regEmitOrder_\(UUID().uuidString)")
        var order: [String] = []
        var cancellables = Set<AnyCancellable>()

        registry.observe(cap)
            .sink { _ in order.append("notify") }
            .store(in: &cancellables)
        registry.observeAll()
            .sink { snapshot in
                if !snapshot.isEmpty { order.append("snapshot") }
            }
            .store(in: &cancellables)
        order.removeAll()

        registry.register(for: pluginId, capabilities: [cap])
        #expect(order == ["notify", "snapshot"])
        #expect(registry.query(cap) == true)
        #expect(registry.queryAll()[pluginId] == [cap])

        cancellables.removeAll()
    }

    @Test("replacement registration emits false for removed and true for added")
    func replacementEmitsFalseThenTrue() {
        let registry = CapabilityRegistry()
        let pluginId = "RegReplaceEmit_\(UUID().uuidString)"
        var cancellables = Set<AnyCancellable>()
        var heavyReceived: [Bool] = []
        var networkReceived: [Bool] = []

        registry.observe(.heavyTask)
            .sink { heavyReceived.append($0) }
            .store(in: &cancellables)
        registry.observe(.networkAccess)
            .sink { networkReceived.append($0) }
            .store(in: &cancellables)

        registry.register(for: pluginId, capabilities: [.heavyTask])
        #expect(heavyReceived.last == true)

        registry.register(for: pluginId, capabilities: [.networkAccess])
        #expect(heavyReceived.last == false)
        #expect(networkReceived.last == true)
        #expect(registry.query(.heavyTask) == false)
        #expect(registry.query(.networkAccess) == true)

        cancellables.removeAll()
    }
}
