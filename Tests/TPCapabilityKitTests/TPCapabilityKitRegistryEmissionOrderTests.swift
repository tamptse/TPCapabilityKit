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

    @Test("per-capability delivered before snapshot on register")
    func perCapabilityBeforeSnapshotOnRegister() {
        let registry = CapabilityRegistry()
        let cap = Capability.custom("emissionOrderReg_\(UUID().uuidString)")
        let log = EventLog()
        var cancellables = Set<AnyCancellable>()

        registry.observe(cap)
            .sink { _ in log.append("per-capability") }
            .store(in: &cancellables)
        registry.observeAll()
            .sink { _ in log.append("snapshot") }
            .store(in: &cancellables)
        log.reset()

        registry.register(for: "EmissionOrderReg", capabilities: [cap])

        #expect(log.snapshot == ["per-capability", "snapshot"])
        #expect(registry.query(cap) == true)
    }

    @Test("per-capability delivered before snapshot on unregister")
    func perCapabilityBeforeSnapshotOnUnregister() {
        let registry = CapabilityRegistry()
        let cap = Capability.custom("emissionOrderUnreg_\(UUID().uuidString)")
        let log = EventLog()
        var cancellables = Set<AnyCancellable>()

        registry.observe(cap)
            .sink { _ in log.append("per-capability") }
            .store(in: &cancellables)
        registry.observeAll()
            .sink { _ in log.append("snapshot") }
            .store(in: &cancellables)

        registry.register(for: "EmissionOrderUnreg", capabilities: [cap])
        log.reset()

        registry.unregister(for: "EmissionOrderUnreg")

        #expect(log.snapshot == ["per-capability", "snapshot"])
        #expect(registry.query(cap) == false)
    }
}
