@preconcurrency import Foundation
import Combine
import Testing
@testable import TPCapabilityKit

struct TPCapabilityKitLifecycleOrderPinTests {

    @Test func startCanSynchronouslyQueryOwnCapability() {
        final class StartQueryPlugin: AppPlugin {
            let id: String
            var sawCapabilityDuringStart: Bool?
            init(id: String) { self.id = id }
            var capabilities: Set<Capability> { [.heavyTask] }
            func start(with store: DynamicStore) {
                sawCapabilityDuringStart = store.queryCapability(.heavyTask)
            }
        }

        let store = DynamicStore()
        let plugin = StartQueryPlugin(id: "StartQueryPin_\(UUID().uuidString)")
        store.register(plugin: plugin)

        #expect(plugin.sawCapabilityDuringStart == true)
        #expect(store.queryCapability(.heavyTask))
    }

    @Test func unregisterDetachesObserversAndClearsQueries() {
        final class UnregisterPinPlugin: AppPlugin {
            let id: String
            init(id: String) { self.id = id }
            var capabilities: Set<Capability> { [.heavyTask] }
            func start(with store: DynamicStore) {
                store.updateState(pluginId: id, newState: "UnregisterPinState")
            }
        }

        let store = DynamicStore()
        let pluginId = "UnregisterPin_\(UUID().uuidString)"
        let plugin = UnregisterPinPlugin(id: pluginId)
        store.register(plugin: plugin)

        #expect(store.getState(pluginId: pluginId, type: String.self) == "UnregisterPinState")
        #expect(store.queryCapability(.heavyTask))
        #expect(store.queryCapabilities(for: pluginId) == [.heavyTask])

        var received: [String] = []
        var didFinish = false
        var cancellables = Set<AnyCancellable>()
        store.observeState(pluginId: pluginId, type: String.self)
            .sink(
                receiveCompletion: { _ in didFinish = true },
                receiveValue: { received.append($0) }
            )
            .store(in: &cancellables)
        #expect(received.last == "UnregisterPinState")

        store.unregister(plugin: plugin)

        #expect(store.queryCapabilities(for: pluginId).isEmpty)
        #expect(store.queryCapability(.heavyTask) == false)
        #expect(store.getState(pluginId: pluginId, type: String.self) == nil)
        #expect(didFinish)
        #expect(received == ["UnregisterPinState"])

        store.updateState(pluginId: pluginId, newState: "AfterUnregister")
        #expect(received == ["UnregisterPinState"])
        #expect(store.getState(pluginId: pluginId, type: String.self) == "AfterUnregister")

        var newReceived: [String] = []
        var newCancellables = Set<AnyCancellable>()
        store.observeState(pluginId: pluginId, type: String.self)
            .sink { newReceived.append($0) }
            .store(in: &newCancellables)
        #expect(newReceived.last == "AfterUnregister")

        cancellables.removeAll()
        newCancellables.removeAll()
    }

    @Test func emptyIdRegisterUnregisterLeavesObservablesIdentical() {
        struct EmptyIdPinPlugin: AppPlugin {
            let id = ""
            var capabilities: Set<Capability> { [.heavyTask] }
            func start(with store: DynamicStore) {
                store.updateState(pluginId: id, newState: "ShouldBeNoOp")
            }
        }

        let store = DynamicStore()
        #expect(store.queryCapability(.heavyTask) == false)
        #expect(store.queryCapabilities(for: "").isEmpty)
        #expect(store.getState(pluginId: "", type: String.self) == nil)

        var capValues: [Bool] = []
        var snapshots: [[String: Set<Capability>]] = []
        var cancellables = Set<AnyCancellable>()
        store.observeCapability(.heavyTask)
            .sink { capValues.append($0) }
            .store(in: &cancellables)
        store.observeAllCapabilities()
            .sink { snapshots.append($0) }
            .store(in: &cancellables)
        #expect(capValues == [false])
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.isEmpty == true)

        var emptyStateValues: [String] = []
        var emptyStateCompleted = false
        var emptyCancellables = Set<AnyCancellable>()
        store.observeState(pluginId: "", type: String.self)
            .sink(
                receiveCompletion: { _ in emptyStateCompleted = true },
                receiveValue: { emptyStateValues.append($0) }
            )
            .store(in: &emptyCancellables)
        #expect(emptyStateValues.isEmpty)
        #expect(emptyStateCompleted)

        let emptyPlugin = EmptyIdPinPlugin()
        store.register(plugin: emptyPlugin)

        #expect(store.queryCapability(.heavyTask) == false)
        #expect(store.queryCapabilities(for: "").isEmpty)
        #expect(store.getState(pluginId: "", type: String.self) == nil)
        #expect(capValues == [false])
        #expect(snapshots.count == 1)

        store.unregister(plugin: emptyPlugin)

        #expect(store.queryCapability(.heavyTask) == false)
        #expect(store.queryCapabilities(for: "").isEmpty)
        #expect(store.getState(pluginId: "", type: String.self) == nil)
        #expect(capValues == [false])
        #expect(snapshots.count == 1)

        cancellables.removeAll()
        emptyCancellables.removeAll()
    }
}
