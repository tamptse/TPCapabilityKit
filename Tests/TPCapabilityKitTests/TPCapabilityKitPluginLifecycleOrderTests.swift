import Combine
import Foundation
import Testing
@testable import TPCapabilityKit

@Suite("Plugin lifecycle order (facade pins)")
struct TPCapabilityKitPluginLifecycleOrderTests {
    struct CapabilityQueryPlugin: AppPlugin {
        let id: String
        let capabilities: Set<Capability>
        var observedInsideStart: Bool = false

        func start(with store: DynamicStore) {
            let seen = store.queryCapability(.heavyTask)
            // Record via state so the test can read it through the facade
            // (structs capture by value; use state as the side channel).
            store.updateState(pluginId: id + ".startSeen", newState: seen)
        }
    }

    struct StateWritingPlugin: AppPlugin {
        let id: String
        let capabilities: Set<Capability>
        func start(with store: DynamicStore) {
            store.updateState(pluginId: id, newState: "Started")
        }
    }

    struct EmptyIdPlugin: AppPlugin {
        let id: String = ""
        let capabilities: Set<Capability> = [.heavyTask]
        func start(with store: DynamicStore) {
            store.updateState(pluginId: "", newState: "ShouldNotLand")
        }
    }

    @Test("register-before-start: start observes its own capability synchronously")
    func registerBeforeStartOrdering() {
        let store = DynamicStore()
        let pluginId = "LifecycleOrder_\(UUID().uuidString)"
        #expect(store.queryCapability(.heavyTask) == false)
        let plugin = CapabilityQueryPlugin(id: pluginId, capabilities: [.heavyTask])
        store.register(plugin: plugin)
        let seen = store.getState(pluginId: pluginId + ".startSeen", type: Bool.self)
        #expect(seen == true)
        store.removeState(for: pluginId + ".startSeen")
    }

    @Test("unregister detaches state and capabilities with fresh-subject postcondition")
    func unregisterDetachPlusClear() {
        let store = DynamicStore()
        let pluginId = "LifecycleUnreg_\(UUID().uuidString)"
        let plugin = StateWritingPlugin(id: pluginId, capabilities: [.heavyTask])
        store.register(plugin: plugin)
        #expect(store.getState(pluginId: pluginId, type: String.self) == "Started")
        #expect(store.queryCapabilities(for: pluginId) == [.heavyTask])

        var received: [String] = []
        var completion: Subscribers.Completion<Never>?
        var cancellables = Set<AnyCancellable>()
        store.observeState(pluginId: pluginId, type: String.self)
            .sink(
                receiveCompletion: { completion = $0 },
                receiveValue: { received.append($0) }
            )
            .store(in: &cancellables)
        #expect(received.last == "Started")

        store.unregister(plugin: plugin)
        #expect(store.getState(pluginId: pluginId, type: String.self) == nil)
        #expect(store.queryCapabilities(for: pluginId).isEmpty)
        #expect(completion == .finished)
        let delivered = received.count

        store.updateState(pluginId: pluginId, newState: "After")
        #expect(received.count == delivered)

        var fresh: [String] = []
        var freshCancellables = Set<AnyCancellable>()
        store.observeState(pluginId: pluginId, type: String.self)
            .sink { fresh.append($0) }
            .store(in: &freshCancellables)
        #expect(fresh.last == "After")

        cancellables.removeAll()
        freshCancellables.removeAll()
    }

    @Test("empty-id register/unregister are observable no-ops")
    func emptyIdIdenticalNoOp() {
        let store = DynamicStore()
        let beforeAll = store.queryAllCapabilities()
        let beforeQuery = store.queryCapability(.heavyTask)
        store.register(plugin: EmptyIdPlugin())
        #expect(store.queryCapabilities(for: "").isEmpty)
        #expect(store.getState(pluginId: "", type: String.self) == nil)
        #expect(store.queryAllCapabilities() == beforeAll)
        #expect(store.queryCapability(.heavyTask) == beforeQuery)
        store.unregister(plugin: EmptyIdPlugin())
        #expect(store.queryAllCapabilities() == beforeAll)
        #expect(store.getState(pluginId: "", type: String.self) == nil)
    }
}
