import Foundation

/// Concurrency limiter keyed by Capability sets, holders owned by task identity.
/// Sole admission seam is `withHold(for:_:)` owning admission, first-fit FIFO
/// wake order with skip, cancellable wait, and scope-exit release with the identity guard inside
/// derived from the Lease so a displaced-active row's stale scope-exit cannot
/// release the new holder's slot.
/// Displaced-active then self-heals: old scope-exit no-ops, new holder keeps its slot.
final class ConcurrencyController: @unchecked Sendable {
    private enum HoldAdmission: Sendable, Equatable {
        case admitted
        case parked
        case duplicate
    }

    private var maxPerCapability: Int?
    private var maxGlobal: Int?
    private let lock = NSLock()
    private var capabilitySlots: [Capability: Int] = [:]
    private var globalSlots: Int = 0
    private var heldKeys: [String: (keys: Set<Capability>, owner: ObjectIdentifier)] = [:]
    private struct Waiter: Sendable {
        let keys: Set<Capability>
        let taskId: String
        let owner: ObjectIdentifier
        let resume: @Sendable (Bool) -> Void
    }
    /// FIFO arrival queue; release scans from the head and admits every waiter
    /// fitting current capacity in arrival order (first-fit FIFO with skip).
    /// A skipped head keeps its place and is re-evaluated on every later
    /// release, so skipping delays but never strands it. Admitted waiters
    /// resume outside the lock as an arrival-ordered batch.
    private var waiters: [Waiter] = []

    init(maxPerCapability: Int? = 5, maxGlobal: Int? = 20) {
        self.maxPerCapability = maxPerCapability
        self.maxGlobal = maxGlobal
    }

    internal func updateLimits(maxPerCapability: Int?, maxGlobal: Int?) {
        lock.withLock {
            self.maxPerCapability = maxPerCapability
            self.maxGlobal = maxGlobal
        }
    }

    /// Sole admission seam: runs `body` with whether the hold was admitted,
    /// releasing on scope exit when admitted. Missed release is unrepresentable.
    internal func withHold<R: Sendable>(for lease: Lease, _ body: (Bool) async -> R) async -> R {
        guard await acquire(lease) else { return await body(false) }
        defer { release(lease) }
        return await body(true)
    }

    private func acquire(_ lease: Lease) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let decision = self.park(lease) { admitted in
                    continuation.resume(returning: admitted)
                }
                switch decision {
                case .admitted:
                    continuation.resume(returning: true)
                case .duplicate:
                    continuation.resume(returning: false)
                case .parked:
                    if Task.isCancelled {
                        self.cancel(lease)
                    }
                }
            }
        } onCancel: {
            self.cancel(lease)
        }
    }

    /// Newcomers never overtake queued waiters.
    private func park(
        _ lease: Lease,
        resume: @Sendable @escaping (Bool) -> Void
    ) -> HoldAdmission {
        let keys = lease.task.requiredCapabilities
        let taskId = lease.task.id
        let owner = ObjectIdentifier(lease)
        return lock.withLock {
            if heldKeys.values.contains(where: { $0.owner == owner }) { return .duplicate }
            if waiters.contains(where: { $0.owner == owner }) { return .duplicate }
            if waiters.isEmpty, tryInstall(keys: keys, taskId: taskId, owner: owner) {
                return .admitted
            }
            waiters.append(Waiter(keys: keys, taskId: taskId, owner: owner, resume: resume))
            return .parked
        }
    }

    internal enum WaiterEviction: Sendable {
        case stale
        case `self`
    }

    /// Single waiter-eviction primitive: removes at most one queued waiter
    /// under `taskId` and resumes it with false outside the lock.
    /// Stale evicts a waiter owned by someone else; self evicts our own wait.
    /// Slot-only: touches no Lease, no row, no lifecycle transition.
    internal func removeWaiter(taskId: String, owner: ObjectIdentifier, match: WaiterEviction) {
        var resume: (@Sendable (Bool) -> Void)?
        lock.withLock {
            guard let index = waiters.firstIndex(where: {
                guard $0.taskId == taskId else { return false }
                switch match {
                case .stale: return $0.owner != owner
                case .self: return $0.owner == owner
                }
            }) else { return }
            resume = waiters.remove(at: index).resume
        }
        resume?(false)
    }

    /// Lease-keyed self-cancel intent over the single eviction primitive;
    /// owner mismatch no-ops so cancelling one lease never yanks another wait.
    private func cancel(_ lease: Lease) {
        removeWaiter(taskId: lease.task.id, owner: ObjectIdentifier(lease), match: .self)
    }

    private func release(_ lease: Lease) {
        let taskId = lease.task.id
        let owner = ObjectIdentifier(lease)
        var toResume: [@Sendable (Bool) -> Void] = []
        lock.withLock {
            guard let held = heldKeys[taskId], held.owner == owner else { return }
            heldKeys.removeValue(forKey: taskId)
            let keys = held.keys
            globalSlots = max(0, globalSlots - 1)
            for cap in keys {
                capabilitySlots[cap] = max(0, (capabilitySlots[cap] ?? 1) - 1)
            }
            // First-fit FIFO with skip: scan from the head and admit every
            // waiter fitting the freed capacity, in arrival order. The head
            // keeps priority as the first candidate; a skipped waiter loses no
            // place and is reconsidered on the next release. Each admission
            // consumes capacity under the same lock, so one release admits at
            // most what the freed capacity allows and limits are never
            // overshot. Woken means admitted: slots are installed here, so no
            // resumed waiter ever re-parks.
            var index = waiters.startIndex
            while index < waiters.endIndex {
                let waiter = waiters[index]
                if tryInstall(keys: waiter.keys, taskId: waiter.taskId, owner: waiter.owner) {
                    waiters.remove(at: index)
                    toResume.append(waiter.resume)
                } else {
                    index = waiters.index(after: index)
                }
            }
        }
        for resume in toResume {
            resume(true)
        }
    }

    // MARK: - Private Helpers

    /// Atomic check-and-install; call only with `lock` held.
    private func tryInstall(keys: Set<Capability>, taskId: String, owner: ObjectIdentifier) -> Bool {
        if let maxGlobal = maxGlobal {
            guard globalSlots < maxGlobal else { return false }
        }
        if let maxPerCap = maxPerCapability {
            for cap in keys {
                guard (capabilitySlots[cap] ?? 0) < maxPerCap else { return false }
            }
        }
        globalSlots += 1
        for cap in keys {
            capabilitySlots[cap, default: 0] += 1
        }
        heldKeys[taskId] = (keys, owner)
        return true
    }
}
