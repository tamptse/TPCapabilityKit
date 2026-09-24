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
    private func isAvailable(for task: TaskDescriptor) -> Bool {
        guard let store else { return false }
        return task.requiredCapabilities.allSatisfy { store.queryCapability($0) }
    }

    private func waitForCapabilities(_ task: TaskDescriptor, deadline: Deadline) async -> Bool {
        if task.requiredCapabilities.isEmpty { return true }
        if isAvailable(for: task) { return true }
        let store = self.store
        let required = task.requiredCapabilities
        return await deadline.race {
            guard let publisher = store?.observeAllCapabilities() else { return false }
            for await _ in publisher.values {
                if required.allSatisfy({ store?.queryCapability($0) ?? false }) { return true }
            }
            return false
        }
    }

    /// Sole production activator: every prod path to `active` goes through here
    /// (wait via the shared waiter, terminal via the single row transition).
    /// ObjC live-view tests may still call `Lease.activate()` directly to
    /// exercise the ObjcLease reflection.
    ///
    /// Reads as one flow with one release: entry availability settles failed,
    /// admission refusal returns silently, and post-admission gates decide via
    /// `gateAdmitted` while the scope-exit release stays owned here.
    private func activate(_ lease: Lease, deadline: Deadline) async {
        guard isAvailable(for: lease.task) else {
            settle(lease, as: .failed)
            return
        }
        guard await concurrencyController.acquire(lease) else { return }
        defer { concurrencyController.release(lease) }
        switch gateAdmitted(lease) {
        case .proceed:
            await runActivatedLease(lease, deadline: deadline)
        case .failed:
            settle(lease, as: .failed)
        case .refused:
            break
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
}
