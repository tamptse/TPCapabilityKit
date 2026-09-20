import Foundation

/// Concurrency limiter keyed by Capability sets with scoped Slot tokens.
/// Synchronous release on scope exit; idempotent via held-slot tracking.
final class ConcurrencyController: @unchecked Sendable {
    struct Slot: Sendable, Hashable {
        let id: UUID
        let keys: Set<Capability>
    }

    private let maxPerCapability: Int?
    private let maxGlobal: Int?
    private let lock = NSLock()
    private var capabilitySlots: [Capability: Int] = [:]
    private var globalSlots: Int = 0
    private var heldSlots: [UUID: Set<Capability>] = [:]
    private var waitingContinuations: [CheckedContinuation<Void, Never>] = []

    init(maxPerCapability: Int? = 5, maxGlobal: Int? = 20) {
        self.maxPerCapability = maxPerCapability
        self.maxGlobal = maxGlobal
    }

    internal func acquire(keys: Set<Capability>) async -> Slot {
        while true {
            if let slot = lock.withLock({ tryAcquire(keys: keys) }) {
                return slot
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                var resumeNow = false
                lock.withLock {
                    if canAcquire(keys: keys) {
                        resumeNow = true
                    } else {
                        waitingContinuations.append(continuation)
                    }
                }
                if resumeNow { continuation.resume() }
            }
        }
    }

    internal func release(_ slot: Slot) {
        var toResume: CheckedContinuation<Void, Never>?
        lock.withLock {
            guard heldSlots.removeValue(forKey: slot.id) != nil else { return }
            globalSlots = max(0, globalSlots - 1)
            for cap in slot.keys {
                capabilitySlots[cap] = max(0, (capabilitySlots[cap] ?? 1) - 1)
            }
            if !waitingContinuations.isEmpty {
                toResume = waitingContinuations.removeFirst()
            }
        }
        toResume?.resume()
    }

    func stats() -> Stats {
        lock.withLock {
            Stats(
                globalActive: globalSlots,
                globalMax: maxGlobal,
                perCapability: capabilitySlots,
                waitingCount: waitingContinuations.count
            )
        }
    }

    // MARK: - Private Helpers

    private func canAcquire(keys: Set<Capability>) -> Bool {
        if let maxGlobal = maxGlobal {
            guard globalSlots < maxGlobal else { return false }
        }
        if let maxPerCap = maxPerCapability {
            for cap in keys {
                guard (capabilitySlots[cap] ?? 0) < maxPerCap else { return false }
            }
        }
        return true
    }

    private func makeSlot(keys: Set<Capability>) -> Slot {
        globalSlots += 1
        for cap in keys {
            capabilitySlots[cap, default: 0] += 1
        }
        let slot = Slot(id: UUID(), keys: keys)
        heldSlots[slot.id] = keys
        return slot
    }

    private func tryAcquire(keys: Set<Capability>) -> Slot? {
        guard canAcquire(keys: keys) else { return nil }
        return makeSlot(keys: keys)
    }

    /// Statistics about current concurrency utilization.
    struct Stats: Sendable {
        let globalActive: Int
        let globalMax: Int?
        let perCapability: [Capability: Int]
        let waitingCount: Int
    }
}
