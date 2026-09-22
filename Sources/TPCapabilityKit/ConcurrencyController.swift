import Foundation

/// Concurrency limiter keyed by Capability sets, holders owned by task identity.
/// Single release shared by terminal, retry, and scope-exit; guarded by owner
/// token (ObjectIdentifier of the Lease) so a displaced-active row's stale
/// scope-exit defer cannot release the new holder's slot.
/// Displaced-active then self-heals: old defer no-ops, new holder keeps its slot.
final class ConcurrencyController: @unchecked Sendable {
    private let maxPerCapability: Int?
    private let maxGlobal: Int?
    private let lock = NSLock()
    private var capabilitySlots: [Capability: Int] = [:]
    private var globalSlots: Int = 0
    private var heldKeys: [String: (keys: Set<Capability>, owner: ObjectIdentifier)] = [:]
    private struct Waiter {
        let keys: Set<Capability>
        let continuation: CheckedContinuation<Void, Never>
    }
    private var waitingContinuations: [Waiter] = []

    init(maxPerCapability: Int? = 5, maxGlobal: Int? = 20) {
        self.maxPerCapability = maxPerCapability
        self.maxGlobal = maxGlobal
    }

    internal func acquire(keys: Set<Capability>, taskId: String, owner: ObjectIdentifier) async {
        while true {
            if lock.withLock({ tryHold(keys: keys, taskId: taskId, owner: owner) }) {
                return
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                var resumeNow = false
                lock.withLock {
                    if tryHold(keys: keys, taskId: taskId, owner: owner) {
                        resumeNow = true
                    } else {
                        waitingContinuations.append(Waiter(keys: keys, continuation: continuation))
                    }
                }
                if resumeNow { continuation.resume() }
            }
        }
    }

    internal func release(taskId: String, owner: ObjectIdentifier) {
        var toResume: CheckedContinuation<Void, Never>?
        lock.withLock {
            guard let held = heldKeys[taskId], held.owner == owner else { return }
            heldKeys.removeValue(forKey: taskId)
            let keys = held.keys
            globalSlots = max(0, globalSlots - 1)
            for cap in keys {
                capabilitySlots[cap] = max(0, (capabilitySlots[cap] ?? 1) - 1)
            }
            for index in waitingContinuations.indices {
                if canAcquire(keys: waitingContinuations[index].keys) {
                    toResume = waitingContinuations.remove(at: index).continuation
                    break
                }
            }
        }
        toResume?.resume()
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

    private func tryHold(keys: Set<Capability>, taskId: String, owner: ObjectIdentifier) -> Bool {
        if let held = heldKeys[taskId] { return held.owner == owner }
        guard canAcquire(keys: keys) else { return false }
        globalSlots += 1
        for cap in keys {
            capabilitySlots[cap, default: 0] += 1
        }
        heldKeys[taskId] = (keys, owner)
        return true
    }
}
