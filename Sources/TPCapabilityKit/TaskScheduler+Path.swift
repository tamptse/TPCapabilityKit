import Foundation
import Combine

extension TaskScheduler {
    func processPendingTasks() async {
        while true {
            guard let nextLease = dequeueNext() else { break }
            guard !nextLease.isTerminal else { continue }
            let deadline = Deadline(task: nextLease.task, default: configuration.defaultTimeout, clock: clock)

            guard isAvailable(for: nextLease.task) else {
                parkLeaseForCapabilities(nextLease, deadline: deadline)
                continue
            }

            await activate(nextLease, deadline: deadline)
        }
    }

    private func dequeueNext() -> Lease? {
        lock.withLock {
            lifecycleStore.dequeueNext()
        }
    }

    private func parkLeaseForCapabilities(_ lease: Lease, deadline: Deadline) {
        let shouldWait: Bool = lock.withLock {
            lifecycleStore.beginPark(for: lease)
        }
        guard shouldWait else { return }
        let waiterTask = Task { await self.waitForCapabilitiesAndProcess(lease, deadline: deadline) }
        let alreadyTerminal: Bool = lock.withLock {
            lifecycleStore.setParkWaiter(for: lease, waiter: waiterTask)
        }
        if alreadyTerminal { waiterTask.cancel() }
    }

    private func waitForCapabilitiesAndProcess(_ lease: Lease, deadline: Deadline) async {
        let capabilityAvailable = await waitForCapabilities(
            lease.task,
            deadline: deadline
        )
        lock.withLock {
            lifecycleStore.clearParkWait(for: lease)
        }

        guard !lease.isTerminal else { return }

        guard capabilityAvailable else {
            settle(lease, as: .expired)
            return
        }

        await activate(lease, deadline: deadline)
    }

    /// Single capability wait owned by Tasks: one timeout shared by the whole
    /// set across immediate and queued execution, preserved across retry.
    /// Point-in-time availability for entry and gate checks; waiting itself
    /// delegates to the registry seam below.
    private func isAvailable(for task: TaskDescriptor) -> Bool {
        guard let store else { return false }
        return task.requiredCapabilities.allSatisfy { store.queryCapability($0) }
    }

    /// Readiness crosses the registry seam: Tasks keeps park, Deadline
    /// expiry, activation, and settlement; set-matching lives in the registry.
    /// No per-emission query loop remains here.
    private func waitForCapabilities(_ task: TaskDescriptor, deadline: Deadline) async -> Bool {
        guard let store else { return false }
        // Deadline adapts to the registry-owned race: same single expiry,
        // now passed as a value instead of named across the seam.
        let race: @Sendable (@escaping CapabilityRegistry.WaitOperation) async -> Bool = { operation in
            await deadline.race(operation: operation)
        }
        return await store.waitForAllCapabilities(task.requiredCapabilities, race: race)
    }

    /// Sole production activator: every prod path to `active` goes through here
    /// (wait via the shared waiter, terminal via the single row transition).
    /// ObjC live-view tests may still call `Lease.activate()` directly to
    /// exercise the ObjcLease reflection.
    ///
    /// Reads as one flow with one scoped hold: entry availability settles failed,
    /// admission refusal returns silently, and post-admission gates decide via
    /// `gateAdmitted`. The hold exits when the activation scope ends, regardless
    /// of whether settlement retried, completed, failed, or expired.
    private func activate(_ lease: Lease, deadline: Deadline) async {
        guard isAvailable(for: lease.task) else {
            settle(lease, as: .failed)
            return
        }
        await concurrencyController.withHold(for: lease) { admitted in
            guard admitted else { return }
            switch gateAdmitted(lease) {
            case .proceed:
                await runActivatedLease(lease, deadline: deadline)
            case .failed:
                settle(lease, as: .failed)
            case .refused:
                break
            }
        }
    }

    /// Decides only; settling stays in `activate`, so this never terminalizes.
    private enum ActivationGate: Sendable, Equatable {
        case proceed
        case failed
        case refused
    }

    private func gateAdmitted(_ lease: Lease) -> ActivationGate {
        guard !lease.isTerminal else { return .refused }
        guard isAvailable(for: lease.task) else { return .failed }
        let admitted = lock.withLock { lifecycleStore.tryActivate(for: lease) }
        return admitted ? .proceed : .refused
    }

    private func runActivatedLease(_ lease: Lease, deadline: Deadline) async {
        let taskExecution: (@Sendable () async -> Any?)? = lock.withLock {
            lifecycleStore.execution(for: lease)
        }

        let outcome = await deadline.runExecution {
            await taskExecution?()
        }

        await settle(lease, result: outcome.value, timedOut: !outcome.won, execution: taskExecution)
    }

    // MARK: - Settlement (internal step of the same path)

    enum Settlement {
        case completed(Any?)
        case failed
        case expired
        case cancelled
    }

    func settle(_ lease: Lease, result: Any?, timedOut: Bool, execution: (@Sendable () async -> Any?)?) async {
        if timedOut {
            settle(lease, as: .expired)
            return
        }
        settle(lease, as: .completed(result), execution: execution)
    }

    /// The single row-transition step of the same path: budget check, row
    /// transition (retry re-queue vs terminal removal), waiter
    /// delivery/cancellation, and retry re-pump. Decides outcome and delivers
    /// waiters but never releases the slot — the activation scope-exit `defer`
    /// owns the single release. Cancel settles via the expired
    /// path with no Lease state-shape change.
    func settle(_ lease: Lease, as outcome: Settlement, execution: (@Sendable () async -> Any?)? = nil) {
        var waiters: [(Lease) -> Void] = []
        var waiterToCancel: Task<Void, Never>?
        var settled = false
        var didRetry = false
        lock.withLock {
            let target: LifecycleStore.Transition
            switch decide(lease: lease, outcome: outcome) {
            case .retry:
                target = .retry(execution)
            case .complete(let result):
                target = .terminal(.completed(result))
            case .fail:
                target = .terminal(.failed(TaskExecutionError()))
            case .expire:
                target = .terminal(.expired)
            }
            guard let applied = lifecycleStore.transition(for: lease, to: target) else { return }
            switch applied {
            case .activated:
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
            Task { await self.processPendingTasks() }
            return
        }
        for waiter in waiters {
            waiter(lease)
        }
    }
}

/// Internal error type for task execution failures.
private struct TaskExecutionError: Error, Sendable {}
