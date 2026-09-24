@preconcurrency import Foundation
import Combine
import Testing
@testable import TPCapabilityKit

@Suite("Guard Ownership (owner seams)")
struct TPCapabilityKitGuardOwnershipTests {
    @Test("capability domain rejects empty id through the interface")
    func capabilityDomainRejectsEmptyId() {
        let store = DynamicStore()
        let cap = Capability.custom("guardCap_\(UUID().uuidString)")
        let before = store.queryAllCapabilities()

        store.registerCapability(for: "", capabilities: [cap])
        #expect(store.queryCapability(cap) == false)
        #expect(store.queryCapabilities(for: "") == [])
        #expect(store.queryAllCapabilities()[""] == nil)
        #expect(store.queryAllCapabilities() == before)

        store.unregisterCapability(for: "")
        #expect(store.queryCapability(cap) == false)
        #expect(store.queryCapabilities(for: "") == [])
        #expect(store.queryAllCapabilities() == before)
    }

    @Test("state domain rejects empty id through the interface")
    func stateDomainRejectsEmptyId() {
        let store = DynamicStore()
        var cancellables = Set<AnyCancellable>()

        var values: [String] = []
        var completion: Subscribers.Completion<Never>?
        store.observeState(pluginId: "", type: String.self)
            .sink(
                receiveCompletion: { completion = $0 },
                receiveValue: { values.append($0) }
            )
            .store(in: &cancellables)
        #expect(values.isEmpty)
        #expect(completion == .finished)

        store.updateState(pluginId: "", newState: "Nope")
        #expect(store.getState(pluginId: "", type: String.self) == nil)
        #expect(values.isEmpty)

        store.removeState(for: "")
        #expect(store.getState(pluginId: "", type: String.self) == nil)
        #expect(values.isEmpty)

        cancellables.removeAll()
    }

    @Test("registry owns its guards directly")
    func registryOwnsGuards() {
        let registry = CapabilityRegistry()
        let cap = Capability.custom("guardReg_\(UUID().uuidString)")

        registry.register(for: "", capabilities: [cap])
        #expect(registry.query(cap) == false)
        #expect(registry.queryCapabilities(for: "") == [])
        #expect(registry.queryAll()[""] == nil)

        registry.unregister(for: "")
        #expect(registry.query(cap) == false)
        #expect(registry.queryCapabilities(for: "") == [])
    }
}
