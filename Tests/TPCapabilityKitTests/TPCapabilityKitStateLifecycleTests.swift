import Combine
import Foundation
import Testing
@testable import TPCapabilityKit

@Suite("State Lifecycle (Store seam)")
struct TPCapabilityKitStateLifecycleTests {
    @Test("removal completes detached subscribers; next update creates fresh subject")
    func removalCompletesFreshSubject() {
        let store = DynamicStore()
        let pluginId = "Lifecycle_\(UUID().uuidString)"
        var received: [String] = []
        var completion: Subscribers.Completion<Never>?
        var cancellables = Set<AnyCancellable>()

        store.observeState(pluginId: pluginId, type: String.self)
            .sink(
                receiveCompletion: { completion = $0 },
                receiveValue: { received.append($0) }
            )
            .store(in: &cancellables)

        store.updateState(pluginId: pluginId, newState: "Before")
        #expect(received.last == "Before")
        #expect(completion == nil)

        store.removeState(for: pluginId)
        #expect(completion == .finished)
        let delivered = received.count

        store.updateState(pluginId: pluginId, newState: "After")
        #expect(received.count == delivered)

        var newReceived: [String] = []
        var newCancellables = Set<AnyCancellable>()
        store.observeState(pluginId: pluginId, type: String.self)
            .sink { newReceived.append($0) }
            .store(in: &newCancellables)
        #expect(newReceived.last == "After")

        cancellables.removeAll()
        newCancellables.removeAll()
    }

    @Test("observe then no-op remove then update still delivers")
    func observeRemoveUpdateDelivers() {
        let store = DynamicStore()
        let pluginId = "Probe_\(UUID().uuidString)"
        var received: [String] = []
        var cancellables = Set<AnyCancellable>()

        store.observeState(pluginId: pluginId, type: String.self)
            .sink { received.append($0) }
            .store(in: &cancellables)

        store.removeState(for: pluginId)
        store.updateState(pluginId: pluginId, newState: "LateValue")
        #expect(received.last == "LateValue")

        cancellables.removeAll()
    }

    @Test("concurrent observers before write rendezvous on the single write")
    func concurrentObserversBeforeWriteRendezvous() {
        let store = DynamicStore()
        let pluginId = "Rendezvous_\(UUID().uuidString)"
        let observerCount = 8
        var received = Array(repeating: [String](), count: observerCount)
        var cancellables = Set<AnyCancellable>()

        for index in 0..<observerCount {
            store.observeState(pluginId: pluginId, type: String.self)
                .sink { received[index].append($0) }
                .store(in: &cancellables)
        }

        #expect(store.getState(pluginId: pluginId, type: String.self) == nil)

        store.updateState(pluginId: pluginId, newState: "RendezvousValue")
        for values in received {
            #expect(values.last == "RendezvousValue")
        }
        #expect(store.getState(pluginId: pluginId, type: String.self) == "RendezvousValue")

        cancellables.removeAll()
    }

    @Test("observation alone never creates visible state")
    func observationAloneNeverCreates() {
        let store = DynamicStore()
        let pluginId = "NeverCreate_\(UUID().uuidString)"
        var cancellables = Set<AnyCancellable>()

        store.observeState(pluginId: pluginId, type: String.self)
            .sink { (_: String) in }
            .store(in: &cancellables)

        #expect(store.getState(pluginId: pluginId, type: String.self) == nil)
        store.removeState(for: pluginId)
        #expect(store.getState(pluginId: pluginId, type: String.self) == nil)

        cancellables.removeAll()
    }
}
