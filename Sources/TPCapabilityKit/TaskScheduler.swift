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

    /// Injectable expiry clock shared by the waiter-timeout and
    /// executor-timeout races. Value type holding the sleep function;
    /// defaults to live time so all existing call sites behave identically.
    /// Internal so timeout behavior pins deterministically in tests.
    /// Scheduler-level (@testable, internal) seam only — the Store facade
    /// always uses live time.
    struct ExpiryClock: Sendable {
        var sleep: @Sendable (TimeInterval) async -> Void

        static var live: ExpiryClock {
            ExpiryClock(
                sleep: { timeout in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                }
            )
        }

        /// Single expiry race mechanics shared by waiter-timeout and
        /// executor-timeout; crossed only through `Deadline`.
        func race(
            timeout: TimeInterval,
            operation: @Sendable @escaping () async -> Bool
        ) async -> Bool {
            let clock = self
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
    }

    /// Owns the whole expiry story behind one seam: timeout resolves once at
    /// Deadline construction from the task plus the configured default, and
    /// the single race serves both the capability wait and the execution path. Waiter and executor cross
    /// `race(_:operation:)`; neither computes timeouts nor builds task groups
    /// directly. The execution result box lives here too, so the race outcome
    /// plus the winning value cross one seam. Expiry reads from lease state
    /// plus completion delivery alone.
    struct Deadline: Sendable {
        enum Race: Sendable, Equatable {
            case wait
            case execution
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
        private let clock: ExpiryClock

        init(task: TaskDescriptor, default defaultTimeout: TimeInterval, clock: ExpiryClock) {
            self.timeout = task.timeout ?? defaultTimeout
            self.clock = clock
        }

        func race(_ kind: Race, operation: @Sendable @escaping () async -> Bool) async -> Bool {
            await clock.race(timeout: timeout, operation: operation)
        }

        func runExecution(
            _ operation: @Sendable @escaping () async -> Any?
        ) async -> (won: Bool, value: Any?) {
            let box = OneShot<Any?>()
            let won = await race(.execution) {
                let value = await operation()
                box.store(value)
                return true
            }
            return (won, won ? (box.load() ?? nil) : nil)
        }
    }

    /// One capability waiter owned by Tasks.
    ///
    /// Folds availability check, single-deadline wait, and slot re-check
    /// behind one `wait(descriptor, deadline)` seam serving immediate
    /// (runTaskWhenAvailable via DynamicStore.scheduleTaskAndWait) and queued
    /// paths alike. Holds the store (not a protocol); the wait crosses the
    /// Deadline seam, sharing one expiry with the executor. The single
    /// `isAvailable(for:)` check serves the park decision plus both
    /// pre-admission re-checks.
    struct CapabilityWaiter: Sendable {
        private weak var store: DynamicStore?

        init(store: DynamicStore?) {
            self.store = store
        }

        func isAvailable(for task: TaskDescriptor) -> Bool {
            guard let store else { return false }
            return task.requiredCapabilities.allSatisfy { store.queryCapability($0) }
        }

        func wait(for task: TaskDescriptor, deadline: Deadline) async -> Bool {
            if task.requiredCapabilities.isEmpty { return true }
            if isAvailable(for: task) { return true }
            let probe = self
            return await deadline.race(.wait) {
                guard let publisher = probe.store?.observeAllCapabilities() else { return false }
                for await _ in publisher.values {
                    if probe.isAvailable(for: task) { return true }
                }
                return false
            }
        }
    }

    private let waiter: CapabilityWaiter
    private let clock: ExpiryClock

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
            var pending: Int
            var queued: Int
            var parked: Int
            var active: Int
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

        var pendingTotal: Int {
            counts.pending
        }

        var queued: Int {
            counts.queued
        }

        var parked: Int {
            counts.parked
        }

        var active: Int {
            counts.active
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

        fileprivate mutating func beginPark(for lease: Lease) -> Bool {
            guard var row = rows[lease.task.id], row.lease === lease else { return false }
            if row.waiting { return false }
            row.waiting = true
            rows[lease.task.id] = row
            return true
        }

        fileprivate mutating func setParkWaiter(for lease: Lease, waiter: Task<Void, Never>) -> Bool {
            if var row = rows[lease.task.id], row.lease === lease {
                row.waiter = waiter
                rows[lease.task.id] = row
            }
            return lease.isTerminal
        }

        fileprivate mutating func clearParkWait(for lease: Lease) {
            if var row = rows[lease.task.id], row.lease === lease {
                row.waiting = false
                row.waiter = nil
                rows[lease.task.id] = row
            }
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
                    guard prioritiesById[headId] != nil else {
                        repairDanglingHead(headId, priority: priority)
                        continue
                    }
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

            private mutating func repairDanglingHead(_ headId: String, priority: TaskPriority) {
                if let nextId = nextById[headId] {
                    heads[priority] = nextId
                    prevById.removeValue(forKey: nextId)
                } else {
                    heads.removeValue(forKey: priority)
                    tails.removeValue(forKey: priority)
                }
                nextById.removeValue(forKey: headId)
                prevById.removeValue(forKey: headId)
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

    init(store: DynamicStore = .shared, configuration: Configuration = .init(), clock: ExpiryClock = .live) {
        self.store = store
        self.configuration = configuration
        self.clock = clock
        self.waiter = CapabilityWaiter(store: store)
        let controller = ConcurrencyController(maxPerCapability: configuration.maxPerCapability, maxGlobal: configuration.maxGlobal)
        self.concurrencyController = controller
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

    /// Queued portion of pending: rows still in order waiting for dequeue.
    var queuedCount: Int {
        lock.withLock { lifecycleStore.counts.queued }
    }

    /// Parked portion of pending: rows dequeued and waiting for capabilities or slots.
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
            releaseSlot(taskId: lease.task.id, owner: ObjectIdentifier(lease))
            Task { await self.processPendingTasks() }
            return
        }
        guard settled else { return }
        waiterToCancel?.cancel()
        releaseSlot(taskId: lease.task.id, owner: ObjectIdentifier(lease))
        for waiter in waiters {
            waiter(lease)
        }
    }

    /// Single controller release shared by terminal, retry, and scope exit;
    /// guarded by the Lease owner token so a stale scope-exit defer no-ops.
    private func releaseSlot(taskId: String, owner: ObjectIdentifier) {
        concurrencyController.release(taskId: taskId, owner: owner)
    }

    private func processPendingTasks() async {
        // Process tasks in priority order
        while true {
            guard let nextLease = dequeueNext() else { break }
            guard !nextLease.isTerminal else { continue }
            let deadline = Deadline(task: nextLease.task, default: configuration.defaultTimeout, clock: clock)

            // Check capability availability
            guard waiter.isAvailable(for: nextLease.task) else {
                parkLeaseForCapabilities(nextLease, deadline: deadline)
                continue
            }

            // Execute the task
            await executeLease(nextLease, deadline: deadline)
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

        await executeLease(lease, deadline: deadline)
    }

    /// Single capability wait owned by Tasks: one timeout shared by the
    /// whole set. Serves immediate (run-when-available) and queued
    /// (schedule/schedule-and-wait) execution alike, preserved across retry.
    private func waitForCapabilities(_ task: TaskDescriptor, deadline: Deadline) async -> Bool {
        await waiter.wait(for: task, deadline: deadline)
    }

    /// Sole production activator: every prod path to `active` goes through here
    /// (wait via the shared waiter, terminal via the single row transition).
    /// ObjC live-view tests may still call `Lease.activate()` directly to
    /// exercise the ObjcLease reflection.
    private func executeLease(_ lease: Lease, deadline: Deadline) async {
        guard waiter.isAvailable(for: lease.task) else {
            settle(lease, as: .failed)
            return
        }

        await withSlot(for: lease) {
            await self.runActivatedLease(lease, deadline: deadline)
        }
    }

    /// Scoped hold owned by the controller: one call per hold, admission,
    /// FIFO wake, cancellable wait, and scope-exit release through the single
    /// Settlement release guarded by this Lease's owner token. A rejected
    /// hold (cancelled or duplicate) means Settlement already settled this
    /// row, so there is nothing to run.
    private func withSlot(for lease: Lease, operation: @Sendable @escaping () async -> Void) async {
        let owner = ObjectIdentifier(lease)
        guard await concurrencyController.acquire(
            keys: lease.task.requiredCapabilities,
            taskId: lease.task.id,
            owner: owner
        ) else { return }
        defer { releaseSlot(taskId: lease.task.id, owner: owner) }
        guard !lease.isTerminal else { return }
        guard self.waiter.isAvailable(for: lease.task) else {
            self.settle(lease, as: .failed)
            return
        }

        let activated: Bool = self.lock.withLock {
            lifecycleStore.tryActivate(for: lease)
        }
        guard activated else { return }

        await operation()
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
