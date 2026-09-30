import Foundation

final class StoreSchedulingGenerations: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [TaskScheduler] = []
    private var configuration: TaskScheduler.Configuration
    private let slots: ConcurrencyController
    /// One time instance shared across live generations, so reconfigure never
    /// forks virtual time. Fixed here at construction, never threaded per call.
    private let clock: Clock

    init(configuration: TaskScheduler.Configuration, clock: Clock) {
        self.configuration = configuration
        self.clock = clock
        self.slots = ConcurrencyController(maxPerCapability: configuration.maxPerCapability, maxGlobal: configuration.maxGlobal)
    }

    func current(owner: DynamicStore) -> TaskScheduler {
        var created: TaskScheduler?
        let result = lock.withLock { () -> TaskScheduler in
            if let current = generations.last { return current }
            let new = TaskScheduler(store: owner, configuration: configuration, clock: clock, concurrencyController: slots)
            generations.append(new)
            created = new
            return new
        }
        if let created { attachSettleHook(to: created) }
        return result
    }

    func reconfigure(_ newConfiguration: TaskScheduler.Configuration, owner: DynamicStore) {
        var created: TaskScheduler?
        lock.withLock {
            configuration = newConfiguration
            let new = TaskScheduler(store: owner, configuration: configuration, clock: clock, concurrencyController: slots)
            generations.append(new)
            created = new
        }
        if let created { attachSettleHook(to: created) }
        // Thread the new caps outside the generations hold: the shared slot
        // domain self-wakes under its own lock only, so the admitted batch
        // resumes with no generations lock held across activation.
        slots.updateLimits(maxPerCapability: newConfiguration.maxPerCapability, maxGlobal: newConfiguration.maxGlobal)
        reapDrainedGenerations()
    }

    /// Deterministic-time controls live here next to the generations they
    /// gate: precede-first-use is checked against the private emptiness helper
    /// in exactly one place, enable-once and virtual-only inside the time module.
    func enableDeterministicTime(owner: DynamicStore) {
        precondition(owner !== DynamicStore.shared, "deterministic time only on fresh instances")
        precondition(isEmpty, "enableDeterministicTime must precede first schedule")
        clock.enableDeterministic()
    }

    func advanceTime(by delta: TimeInterval) async {
        await clock.advance(by: delta)
    }

    func waitForDeterministicWaiters(count expected: Int) async {
        await DeterministicClockProbe(clock).waitForWaiters(count: expected)
    }

    func cancel(taskId: String) {
        let snapshot = lock.withLock { generations }
        fanOutCancel(taskId: taskId, to: snapshot)
    }

    private func fanOutCancel(taskId: String, to snapshot: [TaskScheduler]) {
        for generation in snapshot {
            generation.cancel(taskId: taskId)
        }
    }

    /// Wires a fresh generation's settle/drain notification to the private reap.
    /// Called with no scheduling lock held; the hook keeps no strong cycle.
    private func attachSettleHook(to generation: TaskScheduler) {
        generation.setDrainSettledHook { [weak self] in _ = self?.reapDrainedGenerations() }
    }

    /// Pure generations read: lock, copy, sum, report. Asks no drain state,
    /// mutates nothing. Counts SUM across held generations while slot admission
    /// SHARES the one Store-owned domain, so reconfigure never doubles the
    /// configured limit during drain.
    private var summedCounts: (pending: Int, active: Int) {
        let held = lock.withLock { generations }
        var pending = 0
        var active = 0
        for generation in held {
            let counts = generation.countsSnapshot
            pending += counts.pending
            active += counts.active
        }
        return (pending, active)
    }

    private var isEmpty: Bool {
        lock.withLock { generations.isEmpty }
    }

    var pendingCount: Int {
        summedCounts.pending
    }

    var activeCount: Int {
        summedCounts.active
    }

    /// Hook-driven reap, reachable only from the settle hook above and
    /// reconfigure: performs the named pass and nothing else. Consumes the D4
    /// settle/drain notification; idempotent, reaping an already-reaped list
    /// is a no-op.
    @discardableResult
    private func reapDrainedGenerations() -> [TaskScheduler] {
        // Single allowed Store-to-Tasks crossing, copy-check-sweep: copy under
        // lock, ask drain state with no scheduling lock held, sweep under lock
        // removing only still-present non-current generations flagged drained.
        // Current is never reaped even if drained.
        // No re-check of drain state under the sweep lock: non-current
        // generations drain monotonically (new work lands only on current,
        // cancel only removes, retry re-queues within its own generation), so a
        // flagged-drained generation cannot become live before the sweep. D4
        // pump single-drain-owner re-proves this invariant under coalesced
        // pumping.
        // Drain still means empty pending plus active from one acquisition.
        // Settle/drain notification consumed from D4: the reap entry fires from
        // each generation's hook plus reconfigure.
        let copied = lock.withLock { generations }
        guard copied.count > 1 else { return copied }
        let copiedCurrentID = ObjectIdentifier(copied.last!)
        var drainedIDs = Set<ObjectIdentifier>()
        for generation in copied where ObjectIdentifier(generation) != copiedCurrentID {
            if generation.isDrained {
                drainedIDs.insert(ObjectIdentifier(generation))
            }
        }
        guard !drainedIDs.isEmpty else { return lock.withLock { generations } }
        return lock.withLock {
            guard generations.count > 1 else { return generations }
            let liveCurrentID = ObjectIdentifier(generations.last!)
            generations.removeAll { generation in
                let id = ObjectIdentifier(generation)
                guard id != liveCurrentID else { return false }
                return drainedIDs.contains(id)
            }
            return generations
        }
    }
}
