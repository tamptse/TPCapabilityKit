import Foundation
import Combine

/// One shared expiry race spelled beside the flow that shares it.
/// Timeout resolves once from task plus configured default; waiter and
/// executor draw from the same resolved value through the injected time
/// instance, so neither computes timeouts nor builds races directly.
/// See the time module (`Time.swift`) for the sleep seam.
/// The registry receives the race as a value and never names this helper.
private struct SharedRace: Sendable {
    let timeout: TimeInterval
    private let clock: Clock

    init(task: TaskDescriptor, default defaultTimeout: TimeInterval, clock: Clock) {
        self.timeout = task.timeout ?? defaultTimeout
        self.clock = clock
    }

    func race(operation: @Sendable @escaping () async -> Bool) async -> Bool {
        let raced = await raceValue(operation: { await operation() })
        guard let value = raced else {
            return false
        }
        return (value as? Bool) ?? false
    }

    func raceValue(operation: @Sendable @escaping () async -> Any?) async -> Any?? {
        let timeout = self.timeout
        let clock = self.clock
        struct Box: @unchecked Sendable {
            let value: Any?
        }
        return await withTaskGroup(of: Box?.self) { group in
            group.addTask {
                let value = await operation()
                return Box(value: value)
            }
            group.addTask {
                await clock.sleep(timeout)
                return nil
            }
            guard let first = await group.next() else {
                group.cancelAll()
                return nil
            }
            group.cancelAll()
            guard let box = first else {
                return nil
            }
            return .some(box.value)
        }
    }
}

extension TaskScheduler {
    func guardedDrain() async {
        defer {
            var needsRekick = false
            lock.withLock {
                guard drainInFlight else { return }
                drainInFlight = false
                needsRekick = lifecycleStore.counts.queued > 0
            }
            if needsRekick {
                kickPump()
            }
        }

        while true {
            if Task.isCancelled { break }
            while true {
                if Task.isCancelled { break }
                let next: Lease? = dequeueNext()
                guard let nextLease = next else { break }
                guard !nextLease.isTerminal else { continue }
                let race = SharedRace(task: nextLease.task, default: configuration.defaultTimeout, clock: clock)

                guard isAvailable(for: nextLease.task) else {
                    parkLeaseForCapabilities(nextLease, race: race)
                    continue
                }

                Task { await self.activate(nextLease, race: race) }
            }
            if Task.isCancelled { break }
            let shouldContinue: Bool = lock.withLock {
                if lifecycleStore.counts.queued > 0 {
                    return true
                }
                drainInFlight = false
                return false
            }
            if !shouldContinue { break }
        }
    }

    private func dequeueNext() -> Lease? {
        lock.withLock {
            lifecycleStore.dequeueNext()
        }
    }

    private func parkLeaseForCapabilities(_ lease: Lease, race: SharedRace) {
        _ = lock.withLock {
            lifecycleStore.park(for: lease) {
                Task { await self.waitForCapabilitiesAndProcess(lease, race: race) }
            }
        }
    }

    private func waitForCapabilitiesAndProcess(_ lease: Lease, race: SharedRace) async {
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
    private func waitForCapabilities(_ task: TaskDescriptor, race shared: SharedRace) async -> Bool {
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
    private func activate(_ lease: Lease, race: SharedRace) async {
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

    private func runActivatedLease(_ lease: Lease, race: SharedRace) async {
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

    func settle(_ lease: Lease, raced: Any??, execution: (@Sendable () async -> Any?)?) {
        guard let racedValue = raced else {
            settle(lease, as: .expired)
            return
        }
        settle(lease, as: .completed(racedValue), execution: execution)
    }

    /// The single row-transition step of the same path: outcome decision and
    /// row transition read as one locked block. Retry budget check, void
    /// policy (nil result with budget retries; nil without budget fails when
    /// active else expires), retry re-queue reusing the same Lease identity,
    /// waiter delivery/cancellation, and retry re-pump all live here.
    /// Failed outcomes drop the execution error and mint a fresh one once,
    /// here. `cancelled` maps to `.expired` once, here, with no Lease
    /// state-shape change. Waiters are preserved across retry and delivered
    /// exactly once at terminal. Never releases the slot — the activation
    /// scope-exit owns the single release.
    func settle(_ lease: Lease, as outcome: Settlement, execution: (@Sendable () async -> Any?)? = nil) {
        var waiters: [(Lease) -> Void] = []
        var waiterToCancel: Task<Void, Never>?
        var settled = false
        var didRetry = false
        lock.withLock {
            let target: LifecycleStore.Transition
            switch outcome {
            case .completed(let result):
                if result == nil, lease.canRetry {
                    target = .retry(execution)
                } else if result != nil {
                    target = .terminal(.completed(result))
                } else if lease.isActive {
                    target = .terminal(.failed(TaskExecutionError()))
                } else {
                    target = .terminal(.expired)
                }
            case .failed:
                if lease.isActive {
                    target = .terminal(.failed(TaskExecutionError()))
                } else {
                    target = .terminal(.expired)
                }
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
    }
}

/// Internal error type for task execution failures.
private struct TaskExecutionError: Error, Sendable {}
