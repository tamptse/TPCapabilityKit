import Foundation

/// Concurrency limiter keyed by Capability sets, holders owned by Lease identity.
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
    /// Owner-keyed hold; taskId rides along as waiter-side eviction index only,
    /// never as a held-release lookup.
    private var heldKeys: [ObjectIdentifier: (taskId: String, keys: Set<Capability>)] = [:]
    private struct Waiter: Sendable {
        let keys: Set<Capability>
        /// Waiter-side eviction index only; held release never looks up by taskId.
        let taskId: String
        let owner: ObjectIdentifier
        let resume: @Sendable (Bool) -> Void
    }
    /// FIFO arrival queue; release and limit change share one scan from the
    /// head admitting every waiter fitting current capacity in arrival order
    /// (first-fit FIFO with skip). A skipped head keeps its place and is
    /// re-evaluated on every later consideration, so skipping delays but
    /// never strands it. Admitted waiters resume outside the lock as an
    /// arrival-ordered batch.
    private var waiters: [Waiter] = []

    init(maxPerCapability: Int? = 5, maxGlobal: Int? = 20) {
        self.maxPerCapability = maxPerCapability
        self.maxGlobal = maxGlobal
    }

    /// Limit entry with a wake obligation: a limit change reconsiders the
    /// queue through the same first-fit FIFO-with-skip consideration as
    /// release. Raises admit, lowers naturally admit none; the atomic install
    /// gates every admission against the new caps, so no call-site
    /// raise-vs-lower branch exists. Installs holds only, never releases.
    internal func updateLimits(maxPerCapability: Int?, maxGlobal: Int?) {
        var toResume: [@Sendable (Bool) -> Void] = []
        lock.withLock {
            self.maxPerCapability = maxPerCapability
            self.maxGlobal = maxGlobal
            toResume = admitFittingWaiters()
        }
        for resume in toResume {
            resume(true)
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

    /// Newcomers never overtake queued waiters: the waiters.isEmpty gate forces
    /// parking behind any queued waiter even when capacity is free.
    private func park(
        _ lease: Lease,
        resume: @Sendable @escaping (Bool) -> Void
    ) -> HoldAdmission {
        let keys = lease.task.requiredCapabilities
        let taskId = lease.task.id
        let owner = ObjectIdentifier(lease)
        return lock.withLock {
            if isDuplicate(owner: owner) { return .duplicate }
            if waiters.isEmpty, tryInstall(keys: keys, taskId: taskId, owner: owner) {
                return .admitted
            }
            waiters.append(Waiter(keys: keys, taskId: taskId, owner: owner, resume: resume))
            return .parked
        }
    }

    /// Single duplicate-ownership query over held slots plus the queued wait:
    /// a Lease parks at most once across both collections. Call only with
    /// `lock` held.
    private func isDuplicate(owner: ObjectIdentifier) -> Bool {
        heldKeys[owner] != nil
            || waiters.contains(where: { $0.owner == owner })
    }

    private enum WaiterEviction: Sendable {
        case stale
        case `self`
    }

    /// Single waiter-eviction primitive: removes at most one queued waiter
    /// under `taskId` and resumes it with false outside the lock.
    /// Stale evicts a waiter owned by someone else; self evicts our own wait.
    /// TaskId is waiter-side index only; absent match no-ops.
    /// Slot-only: touches no Lease, no row, no lifecycle transition.
    private func removeWaiter(taskId: String, owner: ObjectIdentifier, match: WaiterEviction) {
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

    /// Single displaced-note: evicts at most one queued waiter under the fresh
    /// lease's task id whose owner differs, resuming it false outside the lock.
    /// No-op when absent. Slot-only: touches no Lease, no row, no transition.
    internal func noteDisplaced(fresh: Lease) {
        removeWaiter(taskId: fresh.task.id, owner: ObjectIdentifier(fresh), match: .stale)
    }

    /// Lease-keyed self-cancel intent over the single eviction primitive;
    /// owner mismatch or absent wait no-ops so cancelling one lease never
    /// yanks another wait.
    private func cancel(_ lease: Lease) {
        removeWaiter(taskId: lease.task.id, owner: ObjectIdentifier(lease), match: .self)
    }

    private func release(_ lease: Lease) {
        let taskId = lease.task.id
        let owner = ObjectIdentifier(lease)
        var toResume: [@Sendable (Bool) -> Void] = []
        lock.withLock {
            guard removeHolding(taskId: taskId, owner: owner) != nil else { return }
            // Shared consideration with the limit entry: scan from the head and
            // admit every waiter fitting the freed capacity, in arrival order.
            // The head keeps priority as the first candidate; a skipped waiter
            // loses no place and is reconsidered on the next consideration.
            // Each admission consumes capacity under the same lock, so one
            // consideration admits at most what the headroom allows and limits
            // are never overshot. Woken means admitted: slots are installed
            // here, so no resumed waiter ever re-parks.
            toResume = admitFittingWaiters()
        }
        for resume in toResume {
            resume(true)
        }
    }

    // MARK: - Private Helpers

    /// Shared scan-plus-install consideration crossed by both wake sources
    /// (scope-exit release after freeing capacity, limit change after updating
    /// caps). Limit-wake policy: any change triggers and admission decides —
    /// raises admit, lowers naturally admit none, mixed changes admit only the
    /// new headroom on both axes with no old-vs-new comparison. The slot
    /// domain self-wakes under its own lock only, reachable solely via the
    /// explicit reconfigure entry, never a count read; reconfigure keeps its
    /// store-thread-append-reap shape. One locked pass never overshoots (the
    /// atomic install gates every admission against the live caps) and never
    /// strands (a skipped waiter keeps its place and is reconsidered on every
    /// later consideration). Call only with `lock` held; the admitted batch
    /// resumes outside the lock in arrival order at the call site.
    private func admitFittingWaiters() -> [@Sendable (Bool) -> Void] {
        var admitted: [@Sendable (Bool) -> Void] = []
        var index = waiters.startIndex
        while index < waiters.endIndex {
            let waiter = waiters[index]
            if tryInstall(keys: waiter.keys, taskId: waiter.taskId, owner: waiter.owner) {
                waiters.remove(at: index)
                admitted.append(waiter.resume)
            } else {
                index = waiters.index(after: index)
            }
        }
        return admitted
    }

    /// Single accounting install behind the admission seam: consumes capacity
    /// for all three occupancy structures at once. Call only with `lock` held,
    /// only after the capacity guards pass.
    private func installHolding(keys: Set<Capability>, taskId: String, owner: ObjectIdentifier) {
        globalSlots += 1
        for cap in keys {
            capabilitySlots[cap, default: 0] += 1
        }
        heldKeys[owner] = (taskId: taskId, keys: keys)
    }

    /// Single accounting remove behind the release seam: drops all three
    /// occupancy structures at once with the identity guard inside, so a
    /// displaced-active row's stale scope-exit cannot release the new holder.
    /// Returns the released keys when the owner matches, nil otherwise.
    /// Call only with `lock` held.
    private func removeHolding(taskId: String, owner: ObjectIdentifier) -> Set<Capability>? {
        guard let held = heldKeys[owner], held.taskId == taskId else { return nil }
        heldKeys.removeValue(forKey: owner)
        globalSlots = max(0, globalSlots - 1)
        for cap in held.keys {
            capabilitySlots[cap] = max(0, (capabilitySlots[cap] ?? 1) - 1)
        }
        return held.keys
    }

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
        installHolding(keys: keys, taskId: taskId, owner: owner)
        return true
    }
}
