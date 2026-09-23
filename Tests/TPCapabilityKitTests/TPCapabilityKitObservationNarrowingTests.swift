@preconcurrency import Foundation
import Combine
import Testing
@testable import TPCapabilityKit

@Suite("Observation Narrowing (Store seam)")
struct TPCapabilityKitObservationNarrowingTests {
    @Test("empty plugin id is no-op with identical observable behavior for state and capability paths")
    func emptyPluginIdNoOp() {
        let store = DynamicStore()
        var cancellables = Set<AnyCancellable>()

        var stateValues: [String] = []
        var stateCompletion: Subscribers.Completion<Never>?
        store.observeState(pluginId: "", type: String.self)
            .sink(
                receiveCompletion: { stateCompletion = $0 },
                receiveValue: { stateValues.append($0) }
            )
            .store(in: &cancellables)
        #expect(stateValues.isEmpty)
        #expect(stateCompletion == .finished)

        store.updateState(pluginId: "", newState: "Nope")
        #expect(store.getState(pluginId: "", type: String.self) == nil)
        #expect(stateValues.isEmpty)

        store.removeState(for: "")
        #expect(store.getState(pluginId: "", type: String.self) == nil)

        #expect(store.queryCapabilities(for: "") == [])

        let cap = Capability.custom("narrowEmpty_\(UUID().uuidString)")
        var capReceived: [Bool] = []
        store.observeCapability(cap)
            .sink { capReceived.append($0) }
            .store(in: &cancellables)
        #expect(capReceived == [false])

        var snapshots: [[String: Set<Capability>]] = []
        store.observeAllCapabilities()
            .sink { snapshots.append($0) }
            .store(in: &cancellables)
        let snapshotCount = snapshots.count

        store.registerCapability(for: "", capabilities: [cap])
        #expect(store.queryCapability(cap) == false)
        #expect(store.queryCapabilities(for: "") == [])
        #expect(store.queryAllCapabilities()[""] == nil)
        #expect(capReceived == [false])
        #expect(snapshots.count == snapshotCount)

        store.unregisterCapability(for: "")
        #expect(store.queryCapability(cap) == false)
        #expect(capReceived == [false])
        #expect(snapshots.count == snapshotCount)

        cancellables.removeAll()
    }

    @Test("registry register/unregister return Void")
    func registryReturnsVoid() {
        let registry = CapabilityRegistry()
        let cap = Capability.custom("narrowVoid_\(UUID().uuidString)")
        let pluginId = "NarrowVoid_\(UUID().uuidString)"

        let registerResult: Void = registry.register(for: pluginId, capabilities: [cap])
        #expect(registerResult == ())
        #expect(registry.query(cap) == true)

        let unregisterResult: Void = registry.unregister(for: pluginId)
        #expect(unregisterResult == ())
        #expect(registry.query(cap) == false)
    }

    @Test("per-capability notice precedes snapshot publish")
    func noticeBeforeSnapshot() {
        let registry = CapabilityRegistry()
        let pluginId = "NarrowOrder_\(UUID().uuidString)"
        let cap = Capability.custom("narrowOrder_\(UUID().uuidString)")
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

        cancellables.removeAll()
    }
}
