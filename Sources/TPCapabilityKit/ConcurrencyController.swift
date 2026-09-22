import Foundation

/// Concurrency limiter keyed by Capability sets, holders owned by task identity.
/// One scoped-hold seam owns admission, FIFO wake order, cancellable wait, and
/// scope-exit release guarded by the owner token (ObjectIdentifier of the
/// Lease) so a displaced-active row's stale scope-exit defer cannot release
/// the new holder's slot.
/// Displaced-active then self-heals: old defer no-ops, new holder keeps its slot.
final class ConcurrencyController: @unchecked Sendable {
    enum HoldAdmission: Sendable, Equatable {
        case admitted
        case parked
        /// Same task already holds or waits; rejected instead of absorbed.
        case duplicate
    }

    private let maxPerCapability: Int?
    private let maxGlobal: Int?
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
    /// FIFO arrival queue; only the head is ever woken, so wake order is policy.
    private var waiters: [Waiter] = []

    init(maxPerCapability: Int? = 5, maxGlobal: Int? = 20) {
        self.maxPerCapability = maxPerCapability
        self.maxGlobal = maxGlobal
    }

    /// Scoped hold: one call per hold, scope exit shares the one release with
    /// Settlement. Returns nil when admission was cancelled or duplicated;
    /// Settlement already settled those paths, so there is nothing to run.
    internal func withHold<T: Sendable>(
        keys: Set<Capability>,
        taskId: String,
        owner: ObjectIdentifier,
        operation: @Sendable () async -> T
    ) async -> T? {
        guard await acquire(keys: keys, taskId: taskId, owner: owner) else { return nil }
        defer { release(taskId: taskId, owner: owner) }
        return await operation()
    }

    internal func acquire(keys: Set<Capability>, taskId: String, owner: ObjectIdentifier) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let decision = self.park(keys: keys, taskId: taskId, owner: owner) { admitted in
                    continuation.resume(returning: admitted)
                }
                switch decision {
                case .admitted:
                    continuation.resume(returning: true)
                case .duplicate:
                    continuation.resume(returning: false)
                case .parked:
                    if Task.isCancelled {
                        self.cancel(taskId: taskId, owner: owner)
                    }
                }
            }
        } onCancel: {
            self.cancel(taskId: taskId, owner: owner)
        }
    }

    /// Newcomers never overtake queued waiters.
    internal func park(
        keys: Set<Capability>,
        taskId: String,
        owner: ObjectIdentifier,
        resume: @Sendable @escaping (Bool) -> Void
    ) -> HoldAdmission {
        var retired: (@Sendable (Bool) -> Void)?
        defer {
            // The displaced lease is terminal, so retiring it cannot strand work.
            retired?(false)
        }
        return lock.withLock {
            if heldKeys[taskId] != nil { return .duplicate }
            if waiters.contains(where: { $0.taskId == taskId && $0.owner == owner }) { return .duplicate }
            if let stale = waiters.firstIndex(where: { $0.taskId == taskId }) {
                retired = waiters.remove(at: stale).resume
            }
            if waiters.isEmpty, canAcquire(keys: keys) {
                installHold(keys: keys, taskId: taskId, owner: owner)
                return .admitted
            }
            waiters.append(Waiter(keys: keys, taskId: taskId, owner: owner, resume: resume))
            return .parked
        }
    }

    /// Removes a parked waiter and resumes it with false; owner mismatch no-ops
    /// so cancelling one lease never yanks another holder's wait.
    internal func cancel(taskId: String, owner: ObjectIdentifier) {
        var resume: (@Sendable (Bool) -> Void)?
        lock.withLock {
            guard let index = waiters.firstIndex(where: { $0.taskId == taskId && $0.owner == owner }) else { return }
            resume = waiters.remove(at: index).resume
        }
        resume?(false)
    }

    internal func release(taskId: String, owner: ObjectIdentifier) {
        var toResume: (@Sendable (Bool) -> Void)?
        lock.withLock {
            guard let held = heldKeys[taskId], held.owner == owner else { return }
            heldKeys.removeValue(forKey: taskId)
            let keys = held.keys
            globalSlots = max(0, globalSlots - 1)
            for cap in keys {
                capabilitySlots[cap] = max(0, (capabilitySlots[cap] ?? 1) - 1)
            }
            if let head = waiters.first, canAcquire(keys: head.keys) {
                waiters.removeFirst()
                installHold(keys: head.keys, taskId: head.taskId, owner: head.owner)
                toResume = head.resume
            }
        }
        toResume?(true)
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

    /// Installs the hold; callers hold `lock` and checked `canAcquire` first.
    private func installHold(keys: Set<Capability>, taskId: String, owner: ObjectIdentifier) {
        globalSlots += 1
        for cap in keys {
            capabilitySlots[cap, default: 0] += 1
        }
        heldKeys[taskId] = (keys, owner)
    }
}
