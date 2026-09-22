import Foundation

/// Concurrency limiter keyed by Capability sets, holders owned by task identity.
/// Single release shared by terminal, retry, and scope-exit; idempotent by task id.
final class ConcurrencyController: @unchecked Sendable {
    private let maxPerCapability: Int?
    private let maxGlobal: Int?
    private let lock = NSLock()
    private var capabilitySlots: [Capability: Int] = [:]
    private var globalSlots: Int = 0
    private var heldKeys: [String: Set<Capability>] = [:]
    private var waitingContinuations: [CheckedContinuation<Void, Never>] = []

    init(maxPerCapability: Int? = 5, maxGlobal: Int? = 20) {
        self.maxPerCapability = maxPerCapability
        self.maxGlobal = maxGlobal
    }

    internal func acquire(keys: Set<Capability>, taskId: String) async {
        while true {
            if lock.withLock({ tryHold(keys: keys, taskId: taskId) }) {
                return
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

    internal func release(taskId: String) {
        var toResume: CheckedContinuation<Void, Never>?
        lock.withLock {
            guard let keys = heldKeys.removeValue(forKey: taskId) else { return }
            globalSlots = max(0, globalSlots - 1)
            for cap in keys {
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

    private func tryHold(keys: Set<Capability>, taskId: String) -> Bool {
        if heldKeys[taskId] != nil { return true }
        guard canAcquire(keys: keys) else { return false }
        globalSlots += 1
        for cap in keys {
            capabilitySlots[cap, default: 0] += 1
        }
        heldKeys[taskId] = keys
        return true
    }

    /// Statistics about current concurrency utilization.
    struct Stats: Sendable {
        let globalActive: Int
        let globalMax: Int?
        let perCapability: [Capability: Int]
        let waitingCount: Int
    }
}
