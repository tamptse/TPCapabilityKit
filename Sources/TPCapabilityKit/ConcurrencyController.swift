import Foundation

/// Concurrency limiter keyed by Capability sets, holders owned by task identity.
/// Sole admission seam is `withHold(for:_:)` owning admission, FIFO wake order,
/// cancellable wait, and scope-exit release with the identity guard inside
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
    /// FIFO arrival queue; only the head is ever woken, so wake order is policy.
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
    private func cancel(_ lease: Lease) {
        let taskId = lease.task.id
        let owner = ObjectIdentifier(lease)
        var resume: (@Sendable (Bool) -> Void)?
        lock.withLock {
            guard let index = waiters.firstIndex(where: { $0.taskId == taskId && $0.owner == owner }) else { return }
            resume = waiters.remove(at: index).resume
        }
        resume?(false)
    }

    private func release(_ lease: Lease) {
        let taskId = lease.task.id
        let owner = ObjectIdentifier(lease)
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
