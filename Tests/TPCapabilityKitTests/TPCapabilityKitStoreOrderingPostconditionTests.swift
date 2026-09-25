import Combine
import Foundation
import Testing
@testable import TPCapabilityKit

@Suite("Store Ordering Postcondition (Store seam)")
struct TPCapabilityKitStoreOrderingPostconditionTests {
    @Test("pre-write observers land on single write losslessly with isolation and no-create")
    func preWriteObserversLandOnSingleWrite() {
        let store = DynamicStore()
        let pluginId = "Ordering_\(UUID().uuidString)"
        let otherId = "OrderingOther_\(UUID().uuidString)"
        let observerCount = 5
        var received = Array(repeating: [String](), count: observerCount)
        var completions = Array<Subscribers.Completion<Never>?>(repeating: nil, count: observerCount)
        var otherReceived: [String] = []
        var otherCompletion: Subscribers.Completion<Never>?
        var cancellables = Set<AnyCancellable>()

        for index in 0..<observerCount {
            let captured = index
            store.observeState(pluginId: pluginId, type: String.self)
                .sink(
                    receiveCompletion: { completions[captured] = $0 },
                    receiveValue: { received[captured].append($0) }
                )
                .store(in: &cancellables)
        }
        store.observeState(pluginId: otherId, type: String.self)
            .sink(
                receiveCompletion: { otherCompletion = $0 },
                receiveValue: { otherReceived.append($0) }
            )
            .store(in: &cancellables)

        #expect(store.getState(pluginId: pluginId, type: String.self) == nil)
        #expect(store.getState(pluginId: otherId, type: String.self) == nil)

        store.updateState(pluginId: pluginId, newState: "OrderedValue")

        for values in received {
            #expect(values.last == "OrderedValue")
        }
        #expect(store.getState(pluginId: pluginId, type: String.self) == "OrderedValue")
        #expect(otherReceived.isEmpty)
        #expect(otherCompletion == nil)
        #expect(store.getState(pluginId: otherId, type: String.self) == nil)

        store.removeState(for: pluginId)

        for completion in completions {
            #expect(completion == .finished)
        }
        #expect(store.getState(pluginId: pluginId, type: String.self) == nil)
        let deliveredCounts = received.map(\.count)

        store.updateState(pluginId: pluginId, newState: "FreshValue")

        for (index, values) in received.enumerated() {
            #expect(values.count == deliveredCounts[index])
        }
        #expect(otherReceived.isEmpty)
        #expect(otherCompletion == nil)

        var freshReceived: [String] = []
        var freshCancellables = Set<AnyCancellable>()
        store.observeState(pluginId: pluginId, type: String.self)
            .sink { freshReceived.append($0) }
            .store(in: &freshCancellables)
        #expect(freshReceived.last == "FreshValue")

        cancellables.removeAll()
        freshCancellables.removeAll()
    }
}
