import Foundation
import Combine

/// Expiry race owner: `Deadline` in the time module (`Time.swift`).
/// Sole resolver of unspecified timeouts (`task.timeout ?? defaultTimeout`);
/// waiter and executor draw from the same resolved value through the threaded
/// clock, so neither computes timeouts nor builds races directly.

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

    /// Single same-id displace handoff: row-take under the scheduler lock in
    /// insert, then outside the lock waiter-cancel, then waiter-delivery,
    /// then slot-evict, then pump kick. Controller self-locks only around its
    /// own queue with waiter resumes outside; never holds the scheduler lock
    /// across delivery or controller calls. Stale drains before newcomer
    /// admission is considered; generations stay evict-free.
    func finishExchange(result: LifecycleStore.ExchangeResult, fresh: Lease) {
        deliverDisplaced(result: result, fresh: fresh)
        kickPump()
    }

    func deliverDisplaced(result: LifecycleStore.ExchangeResult, fresh: Lease) {
        guard let displaced = result.displaced else { return }
        result.waiter?.cancel()
        for waiter in result.waiters {
            waiter(displaced)
        }
        concurrencyController.evictStale(taskId: fresh.task.id, owner: ObjectIdentifier(fresh))
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

    /// Fused settlement: decide-then-transition in one locked path adjacent to
    /// the single row transition it feeds. Fused despite the former do-not-fuse
    /// split because the pure table could pass while the locked caller diverged —
    /// void-nil plus `isActive` routing plus waiter preservation plus re-pump lived
    /// only in the caller, so a green table test coexisted with a dropped waiter or
    /// double delivery; here the table cannot run except through the lock that
    /// applies it. Lease stays dumb state (`activate`/`terminalize`/`beginRetry`
    /// plus `canRetry`/`isActive`/`isTerminal` views); the gate stays
    /// pre-admission-only beside this settle and never terminalizes. Retry re-queues
    /// the same Lease identity with waiters preserved, terminal delivery fires
    /// exactly once, and this step never releases the slot — the activation
    /// scope-exit owns the single release. Decision stays beside the settle that
    /// applies it, not in the lifecycle table (single writer of Lease mutation plus
    /// row write; path is the only flow reader).
    func settle(_ lease: Lease, as outcome: Settlement, execution: (@Sendable () async -> Any?)? = nil) {
        var waiters: [(Lease) -> Void] = []
        var waiterToCancel: Task<Void, Never>?
        var settled = false
        var didRetry = false
        lock.withLock {
            let target: LifecycleStore.Transition
            switch outcome {
            case .completed(let result):
                if result != nil {
                    target = .terminal(.completed(result))
                } else if lease.canRetry {
                    target = .retry(execution)
                } else if lease.isActive {
                    target = .terminal(.failed(TaskExecutionError()))
                } else {
                    target = .terminal(.expired)
                }
            case .failed:
                target = lease.isActive
                    ? .terminal(.failed(TaskExecutionError()))
                    : .terminal(.expired)
            case .expired, .cancelled:
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
