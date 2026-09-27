import Combine
import Foundation
import Testing

@testable import TPCapabilityKit

private final class D5ValueBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [T] = []

    func append(_ value: T) {
        lock.withLock { values.append(value) }
    }

    var all: [T] {
        lock.withLock { values }
    }
}

@Suite("D5 State Rendezvous Pins")
struct TPCapabilityKitD5StateRendezvousTests {
    @Test("interleaved parkers isolate by identity then resolve on own creation")
    func interleavedParkersIsolate() async throws {
        let store = DynamicStore()
        var cancellables = Set<AnyCancellable>()

        let sameId = "d5-same-\(UUID().uuidString)"
        let otherId = "d5-other-\(UUID().uuidString)"

        let sameBoxes = (0..<3).map { _ in D5ValueBox<String>() }
        let otherBox = D5ValueBox<String>()

        for box in sameBoxes {
            store.observeState(pluginId: sameId, type: String.self)
                .sink { box.append($0) }
                .store(in: &cancellables)
        }
        store.observeState(pluginId: otherId, type: String.self)
            .sink { otherBox.append($0) }
            .store(in: &cancellables)

        #expect(store.getState(pluginId: sameId, type: String.self) == nil)
        #expect(store.getState(pluginId: otherId, type: String.self) == nil)

        store.updateState(pluginId: sameId, newState: "hello")
        try await Task.sleep(nanoseconds: 100_000_000)

        for box in sameBoxes {
            #expect(box.all == ["hello"])
        }
        #expect(otherBox.all.isEmpty)

        store.updateState(pluginId: otherId, newState: "world")
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(otherBox.all == ["world"])
        for box in sameBoxes {
            #expect(box.all == ["hello"])
        }
    }

    @Test("reverse creation order still isolates then resolves")
    func reverseCreationOrderIsolates() async throws {
        let store = DynamicStore()
        var cancellables = Set<AnyCancellable>()

        let firstId = "d5-first-\(UUID().uuidString)"
        let secondId = "d5-second-\(UUID().uuidString)"

        let firstBox = D5ValueBox<String>()
        let secondBoxes = (0..<2).map { _ in D5ValueBox<String>() }

        store.observeState(pluginId: firstId, type: String.self)
            .sink { firstBox.append($0) }
            .store(in: &cancellables)
        for box in secondBoxes {
            store.observeState(pluginId: secondId, type: String.self)
                .sink { box.append($0) }
                .store(in: &cancellables)
        }

        store.updateState(pluginId: secondId, newState: "second")
        try await Task.sleep(nanoseconds: 100_000_000)

        for box in secondBoxes {
            #expect(box.all == ["second"])
        }
        #expect(firstBox.all.isEmpty)

        store.updateState(pluginId: firstId, newState: "first")
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(firstBox.all == ["first"])
    }

    @Test("remove-before-create stays no-op for parker resolving on next write")
    func removeBeforeCreateNoop() async throws {
        let store = DynamicStore()
        var cancellables = Set<AnyCancellable>()

        let pluginId = "d5-remove-\(UUID().uuidString)"
        let box = D5ValueBox<String>()

        store.observeState(pluginId: pluginId, type: String.self)
            .sink { box.append($0) }
            .store(in: &cancellables)

        store.removeState(for: pluginId)
        #expect(store.getState(pluginId: pluginId, type: String.self) == nil)

        store.updateState(pluginId: pluginId, newState: "fresh")
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(box.all == ["fresh"])
        #expect(store.getState(pluginId: pluginId, type: String.self) == "fresh")
    }

    @Test("cancelled parker stays silent while survivors resolve")
    func cancelledParkerSilent() async throws {
        let store = DynamicStore()
        var cancellables = Set<AnyCancellable>()

        let pluginId = "d5-cancel-\(UUID().uuidString)"
        let cancelledBox = D5ValueBox<String>()
        let survivorBoxes = (0..<2).map { _ in D5ValueBox<String>() }

        var dropped: AnyCancellable?
        dropped = store.observeState(pluginId: pluginId, type: String.self)
            .sink { cancelledBox.append($0) }
        dropped?.cancel()
        dropped = nil

        for box in survivorBoxes {
            store.observeState(pluginId: pluginId, type: String.self)
                .sink { box.append($0) }
                .store(in: &cancellables)
        }

        #expect(store.getState(pluginId: pluginId, type: String.self) == nil)

        store.updateState(pluginId: pluginId, newState: "alive")
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(cancelledBox.all.isEmpty)
        for box in survivorBoxes {
            #expect(box.all == ["alive"])
        }
    }

    @Test("parking alone creates no visible state")
    func parkingCreatesNothing() async throws {
        let store = DynamicStore()
        var cancellables = Set<AnyCancellable>()

        let pluginId = "d5-nocreate-\(UUID().uuidString)"
        let box = D5ValueBox<String>()

        store.observeState(pluginId: pluginId, type: String.self)
            .sink { box.append($0) }
            .store(in: &cancellables)

        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(box.all.isEmpty)
        #expect(store.getState(pluginId: pluginId, type: String.self) == nil)
    }
}
