import Foundation
import Combine

/// Expiry race owner: `Deadline` in the time module (`Time.swift`).
/// Timeout resolves once from task plus configured default; waiter and
/// executor draw from the same resolved value through the threaded clock,
/// so neither computes timeouts nor builds races directly.

extension TaskScheduler {
    @discardableResult
    func enqueue(
        _ task: TaskDescriptor,
        execution: @escaping @Sendable () async -> Any?,
        completion: ((Lease) -> Void)?
    ) -> Lease {
        let lease = Lease(task: task)

        let exchanged = lock.withLock {
            lifecycleStore.insert(
                lease: lease,
                execution: execution,
                waiters: completion.map { [$0] } ?? []
            )
        }
        finishExchange(result: exchanged, fresh: lease)

        return lease
    }

    /// Lock order: runs outside scheduler `lock` to avoid nesting; controller self-locks, waiters run outside lock.
    /// Note after delivery in same batch so stale drains before newcomer admission.
    /// Generations stay evict-free; obligation is still minted in insert.
    func finishExchange(result: LifecycleStore.ExchangeResult, fresh: Lease) {
        deliverDisplaced(
            displaced: result.displaced,
            waiters: result.waiters,
            waiter: result.waiter,
            evicted: result.evict != nil,
            fresh: fresh
        )
        kickPump()
    }

    func deliverDisplaced(
        displaced: Lease?,
        waiters: [(Lease) -> Void],
        waiter: Task<Void, Never>?,
        evicted: Bool,
        fresh: Lease
    ) {
        if let displaced {
            waiter?.cancel()
            for waiter in waiters {
                waiter(displaced)
            }
        }
        if evicted { concurrencyController.noteDisplaced(fresh: fresh) }
    }

    func guardedDrain() async {
        defer {
            completeDrainHandover()
        }

        if Task.isCancelled { return }
        while true {
            if Task.isCancelled { return }
            let next: Lease? = dequeueNext()
            guard let nextLease = next else { break }
            guard !nextLease.isTerminal else { continue }
            let race = Deadline(task: nextLease.task, default: configuration.defaultTimeout, clock: clock)

            guard isAvailable(for: nextLease.task) else {
                parkLeaseForCapabilities(nextLease, race: race)
                continue
            }

            Task { await self.activate(nextLease, race: race) }
        }
    }

    private func completeDrainHandover() {
        let handover: DrainOwner.Handover = lock.withLock {
            drainOwner.finish(queuedCount: lifecycleStore.counts.queued)
        }
        switch handover {
        case .rekick:
            kickPump()
        case .exited:
            notifyDrainSettled()
        case .idle:
            break
        }
    }

    private func dequeueNext() -> Lease? {
        lock.withLock {
            lifecycleStore.dequeueNext()
        }
    }

    private func parkLeaseForCapabilities(_ lease: Lease, race: Deadline) {
        _ = lock.withLock {
            lifecycleStore.park(for: lease) {
                Task { await self.waitForCapabilitiesAndProcess(lease, race: race) }
            }
        }
    }

    private func waitForCapabilitiesAndProcess(_ lease: Lease, race: Deadline) async {
        let capabilityAvailable = await waitForCapabilities(
            lease.task,
            race: race
        )
        _ = lock.withLock {
            lifecycleStore.transition(for: lease, to: .wake)
        }

        guard !lease.isTerminal else { return }

        guard capabilityAvailable else {
            settle(lease, as: .expired)
            return
        }

        await activate(lease, race: race)
    }

    /// Point-in-time availability query for the entries and the gate below.
    /// Waiting itself delegates to the registry seam below.
    private func isAvailable(for task: TaskDescriptor) -> Bool {
        guard let store else { return false }
        return task.requiredCapabilities.allSatisfy { store.queryCapability($0) }
    }

    /// Readiness crosses the registry seam: Tasks keeps park, shared expiry
    /// race, activation, and settlement; set-matching lives in the registry.
    /// No per-emission query loop remains here.
    private func waitForCapabilities(_ task: TaskDescriptor, race shared: Deadline) async -> Bool {
        guard let store else { return false }
        let race: @Sendable (@escaping CapabilityRegistry.WaitOperation) async -> Bool = { operation in
            await shared.race(operation: operation)
        }
        return await store.waitForAllCapabilities(task.requiredCapabilities, race: race)
    }

    /// Sole production activator: every prod path to `active` goes through here
    /// (wait via the shared waiter, terminal via the single row transition).
    /// ObjC live-view tests may still call `Lease.activate()` directly to
    /// exercise the ObjcLease reflection.
    ///
    /// Entry early exit defers to the availability gate below.
    private func activate(_ lease: Lease, race: Deadline) async {
        // Entry early exit; the availability gate below decides.
        guard isAvailable(for: lease.task) else {
            settle(lease, as: .failed)
            return
        }
        await concurrencyController.withHold(for: lease) { admitted in
            guard admitted else { return }
            switch gateAdmitted(lease) {
            case .proceed:
                await runActivatedLease(lease, race: race)
            case .failed:
                settle(lease, as: .failed)
            case .refused:
                break
            }
        }
    }

    /// Availability gate: terminal refusal, availability re-check, and row
    /// activation read as one decide-then-apply path with settling kept in
    /// `activate`, so this never terminalizes.
    ///
    /// Hold-suspension window stated once here: entry checks are review-only
    /// early exits, the post-admission re-check decides, and admission refusal
    /// returns silently without settling. The hold exits when the activation
    /// scope ends, regardless of whether settlement retried, completed,
    /// failed, or expired.
    private enum ActivationGate: Sendable, Equatable {
        case proceed
        case failed
        case refused
    }

    private func gateAdmitted(_ lease: Lease) -> ActivationGate {
        guard !lease.isTerminal else { return .refused }
        guard isAvailable(for: lease.task) else { return .failed }
        let admitted: Bool = lock.withLock {
            if case .activated = lifecycleStore.transition(for: lease, to: .activate) {
                return true
            }
            return false
        }
        return admitted ? .proceed : .refused
    }

    private func runActivatedLease(_ lease: Lease, race: Deadline) async {
        let taskExecution: (@Sendable () async -> Any?)? = lock.withLock {
            lifecycleStore.execution(for: lease)
        }

        let raced = await race.raceValue {
            await taskExecution?()
        }
        settle(lease, raced: raced, execution: taskExecution)
    }

    // MARK: - Settlement (internal step of the same path)

    /// Tasks-side alias to the single terminal vocabulary owned by Lease.
    /// No duplicate terminal enum lives here.
    typealias Terminal = Lease.Terminal

    /// Settlement input vocabulary. Terminal cases share the unified
    /// `Terminal` spelling; `cancelled` is input-only and maps to `.expired`
    /// at the single settle site with no Lease shape change.
    enum Settlement {
        case completed(Any?)
        case failed
        case expired
        case cancelled
    }

    /// Single settlement-adjacent decode of the raced outcome: outer-absent
    /// (timeout won) settles expired without consulting the carried value;
    /// outer-present (operation won) settles completed, leaving stored-nil to
    /// the void policy in `settle(as:)` (retry vs fail vs expire).
    func settle(_ lease: Lease, raced: Any??, execution: (@Sendable () async -> Any?)?) {
        guard let racedValue = raced else {
            settle(lease, as: .expired)
            return
        }
        settle(lease, as: .completed(racedValue), execution: execution)
    }

    /// Phase table (intentional, do not fuse): decision owned beside
    /// `Lease.Terminal` (`Lease.settleDecision`); input `Settlement`
    /// (`cancelled`→`.expired`) vs `Lease.SettleDirective` vs `Lease.Terminal`
    /// (owner) vs pre-admission `ActivationGate` (never terminalizes).
    /// Retry reuses same Lease identity.

    /// The single row-transition step of the same path: reads the named
    /// decision table, then applies one row transition. Retry re-queue reuses
    /// the same Lease identity, waiters are preserved across retry and
    /// delivered exactly once at terminal, and retry re-pumps. Fail mints a
    /// fresh execution error once, here. Never releases the slot — the
    /// activation scope-exit owns the single release.
    func settle(_ lease: Lease, as outcome: Settlement, execution: (@Sendable () async -> Any?)? = nil) {
        var waiters: [(Lease) -> Void] = []
        var waiterToCancel: Task<Void, Never>?
        var settled = false
        var didRetry = false
        lock.withLock {
            let directive = Lease.settleDecision(for: outcome, canRetry: lease.canRetry, isActive: lease.isActive)
            let target: LifecycleStore.Transition
            switch directive {
            case .retry:
                target = .retry(execution)
            case .complete(let value):
                target = .terminal(.completed(value))
            case .fail:
                target = .terminal(.failed(TaskExecutionError()))
            case .expire:
                target = .terminal(.expired)
            }
            guard let applied = lifecycleStore.transition(for: lease, to: target) else { return }
            switch applied {
            case .activated, .parked, .woken:
                return
            case .retried:
                didRetry = true
                return
            case .terminal(let takenWaiters, let takenWaiter):
                waiterToCancel = takenWaiter
                waiters = takenWaiters
                settled = true
            }
        }
        guard didRetry || settled else { return }
        waiterToCancel?.cancel()
        if didRetry {
            kickPump()
            return
        }
        for waiter in waiters {
            waiter(lease)
        }
        // Terminal settle re-pumps so handover-exit observes the drained state
        // and fires the settle notification; the drain owner coalesces idle kicks.
        kickPump()
    }
}

/// Internal error type for task execution failures.
private struct TaskExecutionError: Error, Sendable {}
