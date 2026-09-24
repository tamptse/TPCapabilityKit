import Testing
import Foundation
@testable import TPCapabilityKit

/// Pins whole-set readiness behind the registry interface with no
/// scheduler: empty and already-satisfied sets never invoke the injected
/// race, a missing set expires through an expiring fake, and an arriving
/// set resolves through a pass-through fake. No TaskScheduler, Deadline,
/// or clock appears here by construction.
@Suite("Registry Wait Tests")
struct TPCapabilityKitRegistryWaitTests {
    private actor RaceProbe {
        private(set) var invocations = 0
        func record() { invocations += 1 }
    }

    @Test("empty set resolves true without invoking the race")
    func emptySetSkipsRace() async {
        let registry = CapabilityRegistry()
        let probe = RaceProbe()
        let result = await registry.waitForAll([]) { _ in
            await probe.record()
            return true
        }
        #expect(result == true)
        #expect(await probe.invocations == 0)
    }

    @Test("already-satisfied set resolves true without invoking the race")
    func satisfiedSetSkipsRace() async {
        let registry = CapabilityRegistry()
        let pluginId = "RegWaitSatisfied_\(UUID().uuidString)"
        let cap = Capability.custom("regWaitSatisfied_\(UUID().uuidString)")
        registry.register(for: pluginId, capabilities: [cap])
        defer { registry.unregister(for: pluginId) }

        let probe = RaceProbe()
        let result = await registry.waitForAll([cap]) { _ in
            await probe.record()
            return true
        }
        #expect(result == true)
        #expect(await probe.invocations == 0)
    }

    @Test("missing set resolves false when the injected expiry wins")
    func missingSetExpires() async {
        let registry = CapabilityRegistry()
        let cap = Capability.custom("regWaitMissing_\(UUID().uuidString)")
        let probe = RaceProbe()
        let result = await registry.waitForAll([cap]) { _ in
            await probe.record()
            return false
        }
        #expect(result == false)
        #expect(await probe.invocations == 1)
    }

    @Test("partial set resolves false when the injected expiry wins")
    func partialSetExpires() async {
        let registry = CapabilityRegistry()
        let capA = Capability.custom("regWaitPartialA_\(UUID().uuidString)")
        let capB = Capability.custom("regWaitPartialB_\(UUID().uuidString)")
        let pluginId = "RegWaitPartial_\(UUID().uuidString)"
        registry.register(for: pluginId, capabilities: [capA])
        defer { registry.unregister(for: pluginId) }

        let result = await registry.waitForAll([capA, capB]) { _ in false }
        #expect(result == false)
    }

    @Test("registering the whole set resolves true through a pass-through race")
    func arrivingSetResolves() async {
        let registry = CapabilityRegistry()
        let capA = Capability.custom("regWaitArriveA_\(UUID().uuidString)")
        let capB = Capability.custom("regWaitArriveB_\(UUID().uuidString)")
        let pluginA = "RegWaitArriveA_\(UUID().uuidString)"
        let pluginB = "RegWaitArriveB_\(UUID().uuidString)"
        defer {
            registry.unregister(for: pluginA)
            registry.unregister(for: pluginB)
        }

        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            registry.register(for: pluginA, capabilities: [capA])
            registry.register(for: pluginB, capabilities: [capB])
        }
        let result = await registry.waitForAll([capA, capB]) { operation in
            await operation()
        }
        #expect(result == true)
    }
}
