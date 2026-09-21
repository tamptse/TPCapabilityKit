@preconcurrency import Foundation
import Combine
import Testing
@testable import TPCapabilityKit

@Suite("CapabilityRegistry Tests")
struct TPCapabilityKitCapabilityRegistryTests {
    private func emit(_ mutation: CapabilityRegistry.MutationResult, via registry: CapabilityRegistry) {
        for (subject, value) in mutation.notifications {
            subject.send(value)
        }
        registry.publish(snapshot: mutation.snapshot)
    }

    @Test("query true after register, false after unregister")
    func queryAfterRegisterUnregister() {
        let registry = CapabilityRegistry()
        let pluginId = "RegQuery_\(UUID().uuidString)"
        let cap = Capability.custom("regQuery_\(UUID().uuidString)")

        #expect(registry.query(cap) == false)

        let registered = registry.register(for: pluginId, capabilities: [cap])
        emit(registered, via: registry)
        #expect(registry.query(cap) == true)
        #expect(registry.queryCapabilities(for: pluginId) == [cap])

        let unregistered = registry.unregister(for: pluginId)
        emit(unregistered, via: registry)
        #expect(registry.query(cap) == false)
        #expect(registry.queryCapabilities(for: pluginId) == [])
    }

    @Test("re-register replaces old capabilities")
    func reRegisterReplacesOldCapabilities() {
        let registry = CapabilityRegistry()
        let pluginId = "RegReplace_\(UUID().uuidString)"

        let first = registry.register(for: pluginId, capabilities: [.heavyTask, .lightTask])
        emit(first, via: registry)
        #expect(registry.query(.heavyTask) == true)
        #expect(registry.query(.lightTask) == true)

        let second = registry.register(for: pluginId, capabilities: [.networkAccess])
        emit(second, via: registry)
        #expect(registry.query(.networkAccess) == true)
        #expect(registry.queryCapabilities(for: pluginId) == [.networkAccess])

        let snapshot = registry.queryAll()
        #expect(snapshot[pluginId] == [.networkAccess])
    }

    @Test("unregister emptied capability emits false and cleans up")
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

        let registered = registry.register(for: pluginId, capabilities: [cap])
        emit(registered, via: registry)
        #expect(received.last == true)
        #expect(registry.query(cap) == true)

        let unregistered = registry.unregister(for: pluginId)
        #expect(unregistered.notifications.count == 1)
        #expect(unregistered.notifications.first?.value == false)
        emit(unregistered, via: registry)

        #expect(received.last == false)
        #expect(registry.query(cap) == false)
        #expect(registry.queryAll()[pluginId] == nil)

        cancellables.removeAll()
    }

    @Test("snapshot reflects current plugin mapping")
    func snapshotContents() {
        let registry = CapabilityRegistry()
        let pluginId1 = "RegSnap1_\(UUID().uuidString)"
        let pluginId2 = "RegSnap2_\(UUID().uuidString)"

        let first = registry.register(for: pluginId1, capabilities: [.heavyTask])
        emit(first, via: registry)
        let second = registry.register(for: pluginId2, capabilities: [.lightTask, .networkAccess])
        emit(second, via: registry)

        let snapshot = registry.queryAll()
        #expect(snapshot[pluginId1]?.contains(.heavyTask) == true)
        #expect(snapshot[pluginId2]?.contains(.lightTask) == true)
        #expect(snapshot[pluginId2]?.contains(.networkAccess) == true)
        #expect(first.snapshot[pluginId1]?.contains(.heavyTask) == true)
        #expect(second.snapshot[pluginId1]?.contains(.heavyTask) == true)
        #expect(second.snapshot[pluginId2]?.contains(.lightTask) == true)

        var observedSnapshots: [[String: Set<Capability>]] = []
        var cancellables = Set<AnyCancellable>()
        registry.observeAll()
            .sink { observedSnapshots.append($0) }
            .store(in: &cancellables)
        let third = registry.register(for: "RegSnap3_\(UUID().uuidString)", capabilities: [.backgroundExecution])
        emit(third, via: registry)
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

        let registered = registry.register(for: pluginId, capabilities: [cap])
        emit(registered, via: registry)
        #expect(received == [false, true])

        let unregistered = registry.unregister(for: pluginId)
        emit(unregistered, via: registry)
        #expect(received == [false, true, false])

        cancellables.removeAll()
    }
}
