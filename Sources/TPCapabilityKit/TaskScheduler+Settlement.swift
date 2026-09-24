import Foundation

/// Internal error type for task execution failures.
private struct TaskExecutionError: Error, Sendable {}

extension TaskScheduler {
    // MARK: - Settlement

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

    /// The single row-transition path behind one internal seam: budget check,
    /// row transition (retry re-queue vs terminal removal), single slot
    /// release, waiter delivery/cancellation, and retry re-pump. Cancel
    /// settles via the expired path with no Lease state-shape change.
    func settle(_ lease: Lease, as outcome: Settlement, execution: (@Sendable () async -> Any?)? = nil) {
        enum Decision {
            case retry
            case complete(Any?)
            case fail
            case expire
        }
        func decide(lease: Lease, outcome: Settlement) -> Decision {
            // Single terminal decision per ADR-0001/0004: Settlement owns retry
            // budget, void policy, and waiter preservation, evaluating Lease
            // state together so reviewers read one table. Lease writers stay as
            // safety no-ops; row transition below is terminal for every
            // non-terminal combo. `fail()` is active-only per the Lease
            // contract, so a failure requested for a pending lease — one that
            // never activated because its capability was withdrawn
            // mid-admission — expires instead: without this the row would be
            // removed and waiters delivered while the lease stayed pending.
            switch outcome {
            case .completed(let result):
                if result == nil, lease.canRetry { return .retry }
                if result != nil { return .complete(result) }
                return lease.isActive ? .fail : .expire
            case .failed:
                return lease.isActive ? .fail : .expire
            case .expired, .cancelled:
                return .expire
            }
        }

        var waiters: [(Lease) -> Void] = []
        var waiterToCancel: Task<Void, Never>?
        var settled = false
        var didRetry = false
        lock.withLock {
            guard !lease.isTerminal else { return }
            guard lifecycleStore.isLive(lease) else { return }
            switch decide(lease: lease, outcome: outcome) {
            case .retry:
                lease.beginRetry()
                lifecycleStore.applyRetry(for: lease, execution: execution)
                didRetry = true
                return
            case .complete(let result):
                guard let taken = lifecycleStore.takeTerminal(for: lease) else { return }
                waiterToCancel = taken.waiter
                waiters = taken.waiters
                lease.complete(with: result)
                settled = true
            case .fail:
                guard let taken = lifecycleStore.takeTerminal(for: lease) else { return }
                waiterToCancel = taken.waiter
                waiters = taken.waiters
                lease.fail(with: TaskExecutionError())
                settled = true
            case .expire:
                guard let taken = lifecycleStore.takeTerminal(for: lease) else { return }
                waiterToCancel = taken.waiter
                waiters = taken.waiters
                lease.expire()
                settled = true
            }
        }
        if didRetry {
            concurrencyController.release(lease)
            Task { await self.processPendingTasks() }
            return
        }
        guard settled else { return }
        waiterToCancel?.cancel()
        concurrencyController.release(lease)
        for waiter in waiters {
            waiter(lease)
        }
    }
}
