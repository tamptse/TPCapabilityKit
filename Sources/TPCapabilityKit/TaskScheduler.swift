import Foundation
import Combine

/// Internal error type for task execution failures.
private struct TaskExecutionError: Error, Sendable {}

/// Centralized task scheduler that manages capability-based routing,
/// priority queuing, and lease lifecycle.
///
/// Inspired by Meta's Jupiter (capability matching) and Async (priority dispatching).
/// - Important: `@unchecked Sendable` is intentional — all mutable state
///   (`lifecycleStore`) is protected by `lock`. Parked capability waiters are
///   tracked per row and cancelled on terminal settlement. Do not add
///   unsynchronized mutable state.
public final class TaskScheduler: @unchecked Sendable {
    public struct Configuration: Sendable {
        public let defaultTimeout: TimeInterval
        public let maxPerCapability: Int?
        public let maxGlobal: Int?

        public init(
            defaultTimeout: TimeInterval = 30.0,
            maxPerCapability: Int? = 5,
            maxGlobal: Int? = 20
        ) {
            self.defaultTimeout = defaultTimeout
            self.maxPerCapability = maxPerCapability
            self.maxGlobal = maxGlobal
        }

        public static let `default` = Configuration()
    }

    private weak var store: DynamicStore?
    private let configuration: Configuration
    private let concurrencyController: ConcurrencyController
    private let lock = NSLock()

    /// Owns the whole expiry story behind one seam: timeout resolves once at
    /// Deadline construction from the task plus the configured default, the
    /// single race serves both the capability wait and the execution path,
    /// and virtual sleep plus the advance policy live here for deterministic
    /// tests. Waiter and executor cross `race(operation:)`; Store
    /// deterministic helpers delegate to `Clock` below; neither computes
    /// timeouts nor builds task groups directly. The execution result box
    /// lives here too, so the race outcome plus the winning value cross one
    /// seam. Expiry reads from lease state plus completion delivery alone.
    struct Deadline: Sendable {
        /// Shared expiry clock behind the Deadline seam: live sleep by
        /// default, virtual sleep plus advance policy once deterministic time
        /// is enabled, custom sleep only for pinned timeout tests.
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var now: TimeInterval = 0
            private var nextID: UInt64 = 0
            private var waiters: [UInt64: (deadline: TimeInterval, continuation: CheckedContinuation<Void, Never>)] = [:]
            private var virtualEnabled = false
            private let sleepOverride: (@Sendable (TimeInterval) async -> Void)?

            init() {
                self.sleepOverride = nil
            }

            init(sleep: @Sendable @escaping (TimeInterval) async -> Void) {
                self.sleepOverride = sleep
            }

            static var live: Clock {
                Clock()
            }

            var waiterCount: Int {
                lock.withLock { waiters.count }
            }

            func enableDeterministic() {
                lock.withLock {
                    precondition(!virtualEnabled, "deterministic time already enabled")
                    virtualEnabled = true
                }
            }

            func sleep(_ timeout: TimeInterval) async {
                if let override = sleepOverride {
                    await override(timeout)
                    return
                }
                let virtual: Bool = lock.withLock { virtualEnabled }
                if !virtual {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                    return
                }
                if timeout <= 0 { return }
                if Task.isCancelled { return }
                let id: UInt64 = lock.withLock {
                    nextID &+= 1
                    return nextID
                }
                await withTaskCancellationHandler {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        var immediate: CheckedContinuation<Void, Never>?
                        lock.withLock {
                            let deadline = now + timeout
                            if deadline <= now {
                                immediate = cont
                            } else {
                                waiters[id] = (deadline, cont)
                            }
                        }
                        immediate?.resume()
                    }
                } onCancel: {
                    var cont: CheckedContinuation<Void, Never>?
                    lock.withLock { cont = waiters.removeValue(forKey: id)?.continuation }
                    cont?.resume()
                }
            }

            func waitForWaiters(count expected: Int) async {
                let isVirtual: Bool = lock.withLock { virtualEnabled }
                precondition(isVirtual, "deterministic time not enabled")
                await waitForWaitersNoPrecondition(count: expected)
            }

            func advance(by delta: TimeInterval) async {
                precondition(delta >= 0)
                let isVirtual: Bool = lock.withLock { virtualEnabled }
                precondition(isVirtual, "deterministic time not enabled; call enableDeterministicTime() first")
                await waitForWaitersNoPrecondition(count: 1)
                var expired: [CheckedContinuation<Void, Never>] = []
                lock.withLock {
                    now += delta
                    let current = now
                    var remaining: [UInt64: (deadline: TimeInterval, continuation: CheckedContinuation<Void, Never>)] = [:]
                    remaining.reserveCapacity(waiters.count)
                    for (id, waiter) in waiters {
                        if waiter.deadline <= current {
                            expired.append(waiter.continuation)
                        } else {
                            remaining[id] = waiter
                        }
                    }
                    waiters = remaining
                }
                for cont in expired {
                    cont.resume()
                }
                await Task.yield()
                await Task.yield()
            }

            private func waitForWaitersNoPrecondition(count expected: Int) async {
                let deadline = Date().addingTimeInterval(5.0)
                while Date() < deadline {
                    if lock.withLock({ waiters.count }) >= expected { return }
                    await Task.yield()
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                preconditionFailure("Deadline.Clock: no waiter registered within 5s (expected \(expected))")
            }
        }

        /// Result write for the execution race; the loser is ignored by the race outcome.
        private final class OneShot<T>: @unchecked Sendable {
            private let lock = NSLock()
            private var value: T?

            func store(_ newValue: T?) {
                lock.withLock { value = newValue }
            }

            func load() -> T? {
                lock.withLock { value }
            }
        }

        let timeout: TimeInterval
        private let clock: Clock

        init(task: TaskDescriptor, default defaultTimeout: TimeInterval, clock: Clock) {
            self.timeout = task.timeout ?? defaultTimeout
            self.clock = clock
        }

        func race(operation: @Sendable @escaping () async -> Bool) async -> Bool {
            let timeout = self.timeout
            let clock = self.clock
            return await withTaskGroup(of: Bool.self) { group in
                group.addTask(operation: operation)
                group.addTask {
                    await clock.sleep(timeout)
                    return false
                }
                guard let first = await group.next() else {
                    group.cancelAll()
                    return false
                }
                group.cancelAll()
                return first
            }
        }

        func runExecution(
            _ operation: @Sendable @escaping () async -> Any?
        ) async -> (won: Bool, value: Any?) {
            let box = OneShot<Any?>()
            let won = await race {
                let value = await operation()
                box.store(value)
                return true
            }
            return (won, won ? (box.load() ?? nil) : nil)
        }
    }

    private let clock: Deadline.Clock

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
        // Single owner: rows owns place and counts; order is a derived index
        // mutated only via insert/dequeueNext/takeTerminal/applyRetry, so the
        // two cannot disagree and no dangling-head repair is needed.
        struct Counts: Sendable, Equatable {
            let pending: Int
            let queued: Int
            let parked: Int
            let active: Int
        }

        private var rows: [String: LifecycleRow] = [:]
        private var order = OrderIndex()

        var counts: Counts {
            var queued = 0
            var parked = 0
            var active = 0
            for row in rows.values {
                switch row.place {
                case .pending:
                    queued += 1
                case .parked:
                    parked += 1
                case .active:
                    active += 1
                }
            }
            return Counts(pending: queued + parked, queued: queued, parked: parked, active: active)
        }

        mutating func insert(
            lease: Lease,
            execution: (@Sendable () async -> Any?)?,
            waiters: [(Lease) -> Void]
        ) {
            rows[lease.task.id] = LifecycleRow(
                lease: lease,
                place: .pending,
                execution: execution,
                waiters: waiters,
                waiter: nil,
                waiting: false
            )
            order.enqueue(id: lease.task.id, priority: lease.task.priority)
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
            row.place = .pending
            if let execution {
                row.execution = execution
            }
            rows[lease.task.id] = row
            order.enqueue(id: lease.task.id, priority: lease.task.priority)
        }

        mutating func takeTerminal(for lease: Lease) -> (waiters: [(Lease) -> Void], waiter: Task<Void, Never>?)? {
            guard let row = rows[lease.task.id], row.lease === lease else { return nil }
            rows.removeValue(forKey: lease.task.id)
            order.remove(taskId: lease.task.id)
            return (row.waiters, row.waiter)
        }

        private struct OrderIndex: Sendable {
            private static let dequeueOrder = TaskPriority.allCases.sorted(by: >)

            private var prioritiesById: [String: TaskPriority] = [:]
            private var heads: [TaskPriority: String] = [:]
            private var tails: [TaskPriority: String] = [:]
            private var nextById: [String: String] = [:]
            private var prevById: [String: String] = [:]

            mutating func enqueue(id: String, priority: TaskPriority) {
                if let existing = prioritiesById[id] {
                    unlink(taskId: id, priority: existing)
                }
                prioritiesById[id] = priority
                if let tailId = tails[priority] {
                    nextById[tailId] = id
                    prevById[id] = tailId
                    tails[priority] = id
                    nextById.removeValue(forKey: id)
                } else {
                    heads[priority] = id
                    tails[priority] = id
                    prevById.removeValue(forKey: id)
                    nextById.removeValue(forKey: id)
                }
            }

            mutating func dequeue() -> String? {
                for priority in Self.dequeueOrder {
                    guard let headId = heads[priority] else { continue }
                    unlink(taskId: headId, priority: priority)
                    prioritiesById.removeValue(forKey: headId)
                    return headId
                }
                return nil
            }

            @discardableResult
            mutating func remove(taskId: String) -> Bool {
                guard let priority = prioritiesById[taskId] else { return false }
                unlink(taskId: taskId, priority: priority)
                prioritiesById.removeValue(forKey: taskId)
                return true
            }

            private mutating func unlink(taskId: String, priority: TaskPriority) {
                let prevId = prevById[taskId]
                let nextId = nextById[taskId]
                if let prevId {
                    if let nextId {
                        nextById[prevId] = nextId
                        prevById[nextId] = prevId
                    } else {
                        nextById.removeValue(forKey: prevId)
                        tails[priority] = prevId
                    }
                } else if let nextId {
                    heads[priority] = nextId
                    prevById.removeValue(forKey: nextId)
                } else {
                    heads.removeValue(forKey: priority)
                    tails.removeValue(forKey: priority)
                }
                prevById.removeValue(forKey: taskId)
                nextById.removeValue(forKey: taskId)
            }
        }
    }

    private var lifecycleStore = LifecycleStore()

    init(store: DynamicStore = .shared, configuration: Configuration = .init(), clock: Deadline.Clock = .live, concurrencyController: ConcurrencyController? = nil) {
        self.store = store
        self.configuration = configuration
        self.clock = clock
        self.concurrencyController = concurrencyController ?? ConcurrencyController(maxPerCapability: configuration.maxPerCapability, maxGlobal: configuration.maxGlobal)
    }

    /// Schedules a task for execution with a closure.
    /// - Parameters:
    ///   - task: The task descriptor to schedule.
    ///   - taskExecution: The async closure to execute when capability is available.
    ///   - completion: Optional completion handler called when task reaches a terminal state.
    /// - Returns: The lease for tracking the task.
    @discardableResult
    func schedule(
        _ task: TaskDescriptor,
        taskExecution: @escaping @Sendable () async -> Void,
        completion: ((Lease) -> Void)? = nil
    ) -> Lease {
        let lease = enqueue(task, execution: {
            await taskExecution()
            return ()
        }, completion: completion)
        Task { await self.processPendingTasks() }
        return lease
    }

    @discardableResult
    private func enqueue(
        _ task: TaskDescriptor,
        execution: @escaping @Sendable () async -> Any?,
        completion: ((Lease) -> Void)?
    ) -> Lease {
        let lease = Lease(task: task)

        // Same-id concurrent scheduling is unsupported: a non-terminal row for
        // this id belongs to an in-flight lease, so settle it first (expired —
        // the only outcome the Lease contract accepts from pending — so its
        // waiters are delivered exactly once, its waiter Task cancelled, its
        // slot released) before the new row takes the id. A terminal row needs
        // no settle, so sequential reuse after terminal keeps working.
        let displaced: Lease? = lock.withLock {
            lifecycleStore.nonTerminalLease(for: task.id)
        }
        if let displaced {
            settle(displaced, as: .expired)
        }

        lock.withLock {
            lifecycleStore.insert(
                lease: lease,
                execution: execution,
                waiters: completion.map { [$0] } ?? []
            )
        }

        return lease
    }

    /// Schedules a task and waits for its result.
    /// - Parameters:
    ///   - task: The task descriptor to schedule.
    ///   - taskExecution: The async closure to execute when capability is available.
    /// - Returns: The result of the task, or nil if timeout/error.
    func scheduleAndWait<T: Sendable>(
        _ task: TaskDescriptor,
        taskExecution: @escaping @Sendable () async throws -> T
    ) async -> T? {
        let lease = enqueue(task, execution: {
            return try? await taskExecution()
        }, completion: nil)

        return await withCheckedContinuation { continuation in
            func resume(with settled: Lease) {
                switch settled.state {
                case .completed:
                    continuation.resume(returning: settled.result as? T)
                default:
                    continuation.resume(returning: nil)
                }
            }

            let settledEarly: Lease? = lock.withLock {
                // Invariant: every row replacement settles our lease first
                // (displacement settles the old lease before the new row takes
                // the id; terminalize removes the row), so a mismatched row
                // means our lease is already settled — return it, never append
                // to another lease's waiter list.
                lifecycleStore.appendScheduleWaiter(for: lease, waiter: { resume(with: $0) })
            }
            if let settled = settledEarly {
                resume(with: settled)
                return
            }

            Task { await self.processPendingTasks() }
        }
    }

    /// Cancels a pending task.
    /// - Parameter taskId: The ID of the task to cancel.
    func cancel(taskId: String) {
        let target: Lease? = lock.withLock { lifecycleStore.lease(for: taskId) }
        guard let target else { return }
        settle(target, as: .cancelled)
    }

    /// Returns the number of pending tasks (queued plus parked; parked-in-pending stays).
    var pendingCount: Int {
        lock.withLock { lifecycleStore.counts.pending }
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

    /// Returns the number of active tasks.
    var activeCount: Int {
        lock.withLock { lifecycleStore.counts.active }
    }

    // MARK: - Settlement

    private enum Settlement {
        case completed(Any?)
        case failed
        case expired
        case cancelled
    }

    /// Single entry for execution outcomes: timeout vs result.
    /// The void-completion policy lives in the row transition below, not here.
    private func settle(_ lease: Lease, result: Any?, timedOut: Bool, execution: (@Sendable () async -> Any?)?) async {
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
    private func settle(_ lease: Lease, as outcome: Settlement, execution: (@Sendable () async -> Any?)? = nil) {
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
            // non-terminal combo, matching the pre-existing settlement shape —
            // including pending re-check failures, which deliver instead of
            // stalling the row.
            switch outcome {
            case .completed(let result):
                if result == nil, lease.canRetry { return .retry }
                if result != nil { return .complete(result) }
                return .fail
            case .failed:
                return .fail
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

    private func processPendingTasks() async {
        // Process tasks in priority order
        while true {
            guard let nextLease = dequeueNext() else { break }
            guard !nextLease.isTerminal else { continue }
            let deadline = Deadline(task: nextLease.task, default: configuration.defaultTimeout, clock: clock)

            // Check capability availability
            guard isAvailable(for: nextLease.task) else {
                parkLeaseForCapabilities(nextLease, deadline: deadline)
                continue
            }

            // Execute the task
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

    /// Single capability wait owned by Tasks: one timeout shared by the
    /// whole set. Serves immediate (run-when-available) and queued
    /// (schedule/schedule-and-wait) execution alike, preserved across retry.
    /// The per-key check below serves the park decision plus both
    /// pre-admission re-checks; the wait crosses the Deadline seam, sharing
    /// one expiry with the executor.
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
    private func activate(_ lease: Lease, deadline: Deadline) async {
        guard isAvailable(for: lease.task) else {
            settle(lease, as: .failed)
            return
        }
        guard await concurrencyController.acquire(lease) else { return }
        defer { concurrencyController.release(lease) }
        guard !lease.isTerminal else { return }
        guard self.isAvailable(for: lease.task) else {
            self.settle(lease, as: .failed)
            return
        }
        let activated: Bool = self.lock.withLock {
            lifecycleStore.tryActivate(for: lease)
        }
        guard activated else { return }
        await runActivatedLease(lease, deadline: deadline)
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
