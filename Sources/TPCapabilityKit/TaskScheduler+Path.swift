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
        return await store.waitForAllCapabilities(task.requiredCapabilities, deadline: deadline)
    }

    /// Sole production activator: every prod path to `active` goes through here
    /// (wait via the shared waiter, terminal via the single row transition).
    /// ObjC live-view tests may still call `Lease.activate()` directly to
    /// exercise the ObjcLease reflection.
    ///
    /// Reads as one flow with one release: entry availability settles failed,
    /// admission refusal returns silently, and post-admission gates decide via
    /// `gateAdmitted`. The `defer` below is the sole slot-release site: every
    /// hold exits here when the activation scope ends, regardless of whether
    /// settlement retried, completed, failed, or expired.
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

    // MARK: - Settlement (internal step of the same path)

    enum Settlement {
        case completed(Any?)
        case failed
        case expired
        case cancelled
    }

    /// Single terminal table: Settlement owns retry budget, void policy, and
    /// waiter preservation; Lease writers are safety no-ops per the Lease contract.
    private enum Decision {
        case retry
        case complete(Any?)
        case fail
        case expire
    }

    private func decide(lease: Lease, outcome: Settlement) -> Decision {
        // Single terminal decision per ADR-0001/0004; see Lease transition contract.
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
            guard !lease.isTerminal else { return }
            guard lifecycleStore.isLive(lease) else { return }
            let terminalDecision: Decision
            switch decide(lease: lease, outcome: outcome) {
            case .retry:
                lease.beginRetry()
                lifecycleStore.applyRetry(for: lease, execution: execution)
                didRetry = true
                return
            case .complete(let result):
                terminalDecision = .complete(result)
            case .fail:
                terminalDecision = .fail
            case .expire:
                terminalDecision = .expire
            }
            guard let taken = lifecycleStore.takeTerminal(for: lease) else { return }
            waiterToCancel = taken.waiter
            waiters = taken.waiters
            switch terminalDecision {
            case .retry:
                return
            case .complete(let result):
                lease.complete(with: result)
            case .fail:
                lease.fail(with: TaskExecutionError())
            case .expire:
                lease.expire()
            }
            settled = true
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

    /// Queued portion of pending, internal-only: Tasks tests read the split,
    /// Store facade exposes pending/active only.
    var queuedCount: Int {
        lock.withLock { lifecycleStore.counts.queued }
    }

    /// Parked portion of pending, internal-only: Tasks tests read the split,
    /// Store facade exposes pending/active only.
    var parkedCount: Int {
        lock.withLock { lifecycleStore.counts.parked }
    }

    func waitForCounts(parked: Int? = nil, pending: Int? = nil, timeout: TimeInterval = 2.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let satisfied = lock.withLock {
                (parked == nil || lifecycleStore.counts.parked == parked)
                    && (pending == nil || lifecycleStore.counts.pending == pending)
            }
            if satisfied { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

/// Internal error type for task execution failures.
private struct TaskExecutionError: Error, Sendable {}

extension TaskScheduler {
    private enum Place: Sendable {
        case pending
        case parked
        case active
    }

    private struct LifecycleRow {
        var lease: Lease
        var place: Place
        var execution: (@Sendable () async -> Any?)?
        var waiters: [(Lease) -> Void]
        var waiter: Task<Void, Never>?
        var waiting: Bool
    }

    struct LifecycleStore {
        struct Counts: Sendable, Equatable {
            let pending: Int
            let queued: Int
            let parked: Int
            let active: Int
        }

        private var rows: [String: LifecycleRow] = [:]
        private var order = OrderIndex()
        private var snapshot = Counts(pending: 0, queued: 0, parked: 0, active: 0)

        var counts: Counts { snapshot }

        private mutating func move(from: Place?, to: Place?) {
            var queued = snapshot.queued
            var parked = snapshot.parked
            var active = snapshot.active
            switch from {
            case .pending: queued -= 1
            case .parked: parked -= 1
            case .active: active -= 1
            case nil: break
            }
            switch to {
            case .pending: queued += 1
            case .parked: parked += 1
            case .active: active += 1
            case nil: break
            }
            snapshot = Counts(
                pending: queued + parked,
                queued: queued,
                parked: parked,
                active: active
            )
        }

        mutating func insert(
            lease: Lease,
            execution: (@Sendable () async -> Any?)?,
            waiters: [(Lease) -> Void]
        ) {
            let old = rows[lease.task.id]?.place
            rows[lease.task.id] = LifecycleRow(
                lease: lease,
                place: .pending,
                execution: execution,
                waiters: waiters,
                waiter: nil,
                waiting: false
            )
            order.enqueue(id: lease.task.id, priority: lease.task.priority)
            move(from: old, to: .pending)
        }

        func nonTerminalLease(for id: String) -> Lease? {
            guard let row = rows[id], !row.lease.isTerminal else { return nil }
            return row.lease
        }

        func lease(for id: String) -> Lease? {
            rows[id]?.lease
        }

        func isLive(_ lease: Lease) -> Bool {
            guard let row = rows[lease.task.id] else { return false }
            return row.lease === lease
        }

        mutating func appendScheduleWaiter(
            for lease: Lease,
            waiter: @escaping (Lease) -> Void
        ) -> Lease? {
            if lease.isTerminal { return lease }
            guard var row = rows[lease.task.id] else { return lease }
            if row.lease !== lease { return lease }
            row.waiters.append(waiter)
            rows[lease.task.id] = row
            return nil
        }

        mutating func beginPark(for lease: Lease) -> Bool {
            mutateParkRow(for: lease) { row in
                guard !row.waiting else { return false }
                row.waiting = true
                return true
            } ?? false
        }

        mutating func setParkWaiter(for lease: Lease, waiter: Task<Void, Never>) -> Bool {
            mutateParkRow(for: lease) { $0.waiter = waiter }
            return lease.isTerminal
        }

        mutating func clearParkWait(for lease: Lease) {
            mutateParkRow(for: lease) {
                $0.waiting = false
                $0.waiter = nil
            }
        }

        private mutating func mutateParkRow<T>(for lease: Lease, _ body: (inout LifecycleRow) -> T) -> T? {
            guard var row = rows[lease.task.id], row.lease === lease else { return nil }
            let result = body(&row)
            rows[lease.task.id] = row
            return result
        }

        mutating func dequeueNext() -> Lease? {
            while let id = order.dequeue() {
                if var row = rows[id] {
                    move(from: row.place, to: .parked)
                    row.place = .parked
                    rows[id] = row
                    return row.lease
                }
            }
            return nil
        }

        func execution(for lease: Lease) -> (@Sendable () async -> Any?)? {
            guard let row = rows[lease.task.id], row.lease === lease else { return nil }
            return row.execution
        }

        mutating func tryActivate(for lease: Lease) -> Bool {
            guard !lease.isTerminal else { return false }
            guard var row = rows[lease.task.id], row.lease === lease else { return false }
            move(from: row.place, to: .active)
            lease.activate()
            row.place = .active
            rows[lease.task.id] = row
            return true
        }

        mutating func applyRetry(
            for lease: Lease,
            execution: (@Sendable () async -> Any?)?
        ) {
            guard var row = rows[lease.task.id], row.lease === lease else { return }
            move(from: row.place, to: .pending)
            row.place = .pending
            if let execution {
                row.execution = execution
            }
            rows[lease.task.id] = row
            order.enqueue(id: lease.task.id, priority: lease.task.priority)
        }

        mutating func takeTerminal(for lease: Lease) -> (waiters: [(Lease) -> Void], waiter: Task<Void, Never>?)? {
            guard let row = rows[lease.task.id], row.lease === lease else { return nil }
            move(from: row.place, to: nil)
            rows.removeValue(forKey: lease.task.id)
            order.remove(taskId: lease.task.id)
            return (row.waiters, row.waiter)
        }

        private struct OrderIndex: Sendable {
            private static let dequeueOrder = TaskPriority.allCases.sorted(by: >)

            private var queues: [TaskPriority: [String]] = [:]
            private var prioritiesById: [String: TaskPriority] = [:]

            mutating func enqueue(id: String, priority: TaskPriority) {
                if let existing = prioritiesById[id] {
                    queues[existing]?.removeAll { $0 == id }
                }
                prioritiesById[id] = priority
                queues[priority, default: []].append(id)
            }

            mutating func dequeue() -> String? {
                for priority in Self.dequeueOrder {
                    guard var queue = queues[priority], !queue.isEmpty else { continue }
                    let id = queue.removeFirst()
                    queues[priority] = queue
                    prioritiesById.removeValue(forKey: id)
                    return id
                }
                return nil
            }

            @discardableResult
            mutating func remove(taskId: String) -> Bool {
                guard let priority = prioritiesById[taskId] else { return false }
                queues[priority]?.removeAll { $0 == taskId }
                prioritiesById.removeValue(forKey: taskId)
                return true
            }
        }
    }
}
