import Testing
import Foundation
import Combine
@testable import TPCapabilityKit

/// Pins the registry emission contract: per-Capability notices deliver before
/// the whole-snapshot publish, on register and on unregister. Crosses the
/// registry seam directly; sends are synchronous on the writer thread, so the
/// order is observable right after the mutation returns.
@Suite("RegistryEmissionOrder Tests")
struct RegistryEmissionOrderTests {
    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []

        func append(_ event: String) {
            lock.withLock { events.append(event) }
        }

        var snapshot: [String] {
            lock.withLock { events }
        }

        func reset() {
            lock.withLock { events.removeAll() }
        }
    }

    @Test("per-capability delivered before waiter resolution on register")
    func perCapabilityBeforeWaiterOnRegister() async {
        let registry = CapabilityRegistry()
        let cap = Capability.custom("emissionOrderReg_\(UUID().uuidString)")
        let log = EventLog()
        var cancellables = Set<AnyCancellable>()

        registry.observe(cap)
            .sink { value in
                if value { log.append("per-capability") }
            }
            .store(in: &cancellables)

        registry.register(for: "EmissionOrderReg", capabilities: [cap])

        // Per-capability notice delivers synchronously; the snapshot-driven
        // waiter resolves after.
        #expect(log.snapshot == ["per-capability"])
        let ready = await registry.waitForAll([cap]) { _ in false }
        if ready { log.append("waiter") }
        #expect(log.snapshot == ["per-capability", "waiter"])
        #expect(registry.query(cap) == true)
    }

    @Test("per-capability delivered before waiter expiry on unregister")
    func perCapabilityBeforeWaiterOnUnregister() async {
        let registry = CapabilityRegistry()
        let cap = Capability.custom("emissionOrderUnreg_\(UUID().uuidString)")
        let log = EventLog()
        var cancellables = Set<AnyCancellable>()

        registry.observe(cap)
            .sink { _ in log.append("per-capability") }
            .store(in: &cancellables)

        registry.register(for: "EmissionOrderUnreg", capabilities: [cap])
        log.reset()

        registry.unregister(for: "EmissionOrderUnreg")

        // Per-capability false delivers synchronously; the waiter then loses
        // the expiry race since the set is no longer simultaneously available.
        #expect(log.snapshot == ["per-capability"])
        let ready = await registry.waitForAll([cap]) { _ in false }
        if !ready { log.append("waiter-expired") }
        #expect(log.snapshot == ["per-capability", "waiter-expired"])
        #expect(registry.query(cap) == false)
    }
}
