import Combine
import Foundation
import Testing
@testable import TPCapabilityKit

@Suite("State Waiter Isolation (Store seam)")
struct TPCapabilityKitStateWaiterIsolationTests {
    @Test("distinct pending observers wake only on their own id")
    func distinctPendingObserversIsolate() {
        let store = DynamicStore()
        let firstId = "WaiterFirst_\(UUID().uuidString)"
        let secondId = "WaiterSecond_\(UUID().uuidString)"
        var firstReceived: [String] = []
        var secondReceived: [String] = []
        var cancellables = Set<AnyCancellable>()

        store.observeState(pluginId: firstId, type: String.self)
            .sink { firstReceived.append($0) }
            .store(in: &cancellables)
        store.observeState(pluginId: secondId, type: String.self)
            .sink { secondReceived.append($0) }
            .store(in: &cancellables)

        #expect(store.getState(pluginId: firstId, type: String.self) == nil)
        #expect(store.getState(pluginId: secondId, type: String.self) == nil)

        store.updateState(pluginId: firstId, newState: "First")
        #expect(firstReceived.last == "First")
        #expect(secondReceived.isEmpty)

        store.updateState(pluginId: secondId, newState: "Second")
        #expect(secondReceived.last == "Second")
        #expect(firstReceived == ["First"])

        cancellables.removeAll()
    }

    @Test("remove before creation is noop; parked observers still resolve on next update")
    func removeNoopBeforeCreation() {
        let store = DynamicStore()
        let pluginId = "WaiterNoop_\(UUID().uuidString)"
        var received: [String] = []
        var cancellables = Set<AnyCancellable>()

        store.observeState(pluginId: pluginId, type: String.self)
            .sink { received.append($0) }
            .store(in: &cancellables)

        store.removeState(for: pluginId)
        #expect(received.isEmpty)

        store.updateState(pluginId: pluginId, newState: "LateValue")
        #expect(received.last == "LateValue")

        cancellables.removeAll()
    }

    @Test("multiple parked observers on the same id all resolve")
    func sameIdParkersAllResolve() {
        let store = DynamicStore()
        let pluginId = "WaiterShared_\(UUID().uuidString)"
        let observerCount = 3
        var received = Array(repeating: [String](), count: observerCount)
        var cancellables = Set<AnyCancellable>()

        for index in 0..<observerCount {
            store.observeState(pluginId: pluginId, type: String.self)
                .sink { received[index].append($0) }
                .store(in: &cancellables)
        }

        store.updateState(pluginId: pluginId, newState: "Shared")
        for values in received {
            #expect(values.last == "Shared")
        }

        cancellables.removeAll()
    }
}
