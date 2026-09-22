import Foundation
import Combine

/// Internal error type for task execution failures.
private struct TaskExecutionError: Error, Sendable {}

/// Shared result write for the timeout race; the loser is ignored by the race outcome.
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

/// Centralized task scheduler that manages capability-based routing,
/// priority queuing, and lease lifecycle.
///
/// Inspired by Meta's Jupiter (capability matching) and Async (priority dispatching).
/// - Important: `@unchecked Sendable` is intentional — all mutable state
///   (`pendingQueue`, `lifecycle`) is protected by `lock`. Parked capability waiters are
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
    }

    /// One capability waiter owned by Tasks.
    ///
    /// Folds availability check, single-deadline wait, and slot re-check
    /// behind one `wait(descriptor, timeout)` seam serving immediate
    /// (runTaskWhenAvailable via DynamicStore.scheduleTaskAndWait) and queued
    /// paths alike. Holds the store and the injected clock (not a protocol);
    /// waiter-timeout and executor-timeout share the one expiry clock through
    /// the single `race` helper.
    struct CapabilityWaiter: Sendable {
        private weak var store: DynamicStore?
        private let clock: ExpiryClock

        init(store: DynamicStore?, clock: ExpiryClock) {
            self.store = store
            self.clock = clock
        }

        func isAvailable(_ capabilities: Set<Capability>) -> Bool {
            guard let store else { return false }
            return capabilities.allSatisfy { store.queryCapability($0) }
        }

        func isAvailable(for task: TaskDescriptor) -> Bool {
            isAvailable(task.requiredCapabilities)
        }

        func wait(for task: TaskDescriptor, timeout: TimeInterval) async -> Bool {
            let capabilities = task.requiredCapabilities
            if capabilities.isEmpty { return true }
            if isAvailable(capabilities) { return true }
            let probe = self
            return await race(timeout: timeout) {
                guard let publisher = probe.store?.observeAllCapabilities() else { return false }
                for await _ in publisher.values {
                    if probe.isAvailable(capabilities) { return true }
                }
                return false
            }
        }

        func recheck(for task: TaskDescriptor) -> Bool {
            isAvailable(for: task)
        }

        /// Single expiry race for both waiter-timeout and executor-timeout
        /// call sites; the injected clock decides the deadline.
        func race(
            timeout: TimeInterval,
            operation: @Sendable @escaping () async -> Bool
        ) async -> Bool {
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
    }

    private let waiter: CapabilityWaiter

    private var pendingQueue = PendingQueue()

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

    private var lifecycle: [String: LifecycleRow] = [:]

    init(store: DynamicStore = .shared, configuration: Configuration = .init(), clock: ExpiryClock = .live) {
        self.store = store
        self.configuration = configuration
        self.waiter = CapabilityWaiter(store: store, clock: clock)
        self.concurrencyController = ConcurrencyController(maxPerCapability: configuration.maxPerCapability, maxGlobal: configuration.maxGlobal)
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
        // Single nil-to-default resolution so waiter and executor share one expiry.
        let resolved = task.timeout ?? configuration.defaultTimeout
        let resolvedTask = task.timeout == nil
            ? TaskDescriptor(
                id: task.id,
                requiredCapabilities: task.requiredCapabilities,
                priority: task.priority,
                timeout: resolved,
                maxRetries: task.maxRetries,
                metadata: task.metadata
            )
            : task
        let lease = Lease(task: resolvedTask)

        // Same-id concurrent scheduling is unsupported: a non-terminal row for
        // this id belongs to an in-flight lease, so settle it first (expired —
        // the only outcome the Lease contract accepts from pending — so its
        // waiters are delivered exactly once, its waiter Task cancelled, its
        // slot released) before the new row takes the id. A terminal row needs
        // no settle, so sequential reuse after terminal keeps working.
        let displaced: Lease? = lock.withLock {
            guard let row = lifecycle[task.id], !row.lease.isTerminal else { return nil }
            return row.lease
        }
        if let displaced {
            settle(displaced, as: .expired)
        }

        lock.withLock {
            lifecycle[task.id] = LifecycleRow(
                lease: lease,
                place: .pending,
                execution: execution,
                waiters: completion.map { [$0] } ?? [],
                waiter: nil,
                waiting: false
            )
            pendingQueue.enqueue(id: task.id, priority: resolvedTask.priority)
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
                if lease.isTerminal {
                    return lease
                }
                guard var row = lifecycle[task.id] else { return lease }
                // Invariant: every row replacement settles our lease first
                // (displacement settles the old lease before the new row takes
                // the id; terminalize removes the row), so a mismatched row
                // means our lease is already settled — return it, never append
                // to another lease's waiter list.
                if row.lease !== lease {
                    return lease
                }
                row.waiters.append({ resume(with: $0) })
                lifecycle[task.id] = row
                return nil
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
        let target: Lease? = lock.withLock { lifecycle[taskId]?.lease }
        guard let target else { return }
        settle(target, as: .cancelled)
    }

    /// Returns the number of pending tasks.
    var pendingCount: Int {
        lock.withLock { lifecycle.values.filter { $0.place == .pending }.count }
    }

    /// Returns the number of active tasks.
    var activeCount: Int {
        lock.withLock {
            lifecycle.values.filter { $0.place == .active }.count
        }
    }

    // MARK: - Private Methods

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

    /// The single row-transition path. Owns the exactly-once guard, retry
    /// budget check, void-completion policy, rendezvous delivery, waiter
    /// cancellation, and the controller release shared with scope exit.
    /// Cancel settles via the expired path with no Lease state-shape change.
    private func settle(_ lease: Lease, as outcome: Settlement, execution: (@Sendable () async -> Any?)? = nil) {
        var waiters: [(Lease) -> Void] = []
        var waiterToCancel: Task<Void, Never>?
        var settled = false
        var didRetry = false
        lock.withLock {
            guard !lease.isTerminal else { return }
            guard var row = lifecycle[lease.task.id], row.lease === lease else { return }
            switch outcome {
            case .completed(let result):
                if result == nil, lease.canRetry {
                    lease.beginRetry()
                    row.place = .pending
                    if let execution {
                        row.execution = execution
                    }
                    lifecycle[lease.task.id] = row
                    pendingQueue.requeue(id: lease.task.id, priority: lease.task.priority)
                    didRetry = true
                    return
                }
                lifecycle.removeValue(forKey: lease.task.id)
                pendingQueue.remove(taskId: lease.task.id)
                waiterToCancel = row.waiter
                waiters = row.waiters
                if result != nil {
                    lease.complete(with: result)
                } else {
                    lease.fail(with: TaskExecutionError())
                }
                settled = true
            case .failed:
                lifecycle.removeValue(forKey: lease.task.id)
                pendingQueue.remove(taskId: lease.task.id)
                waiterToCancel = row.waiter
                waiters = row.waiters
                lease.fail(with: TaskExecutionError())
                settled = true
            case .expired, .cancelled:
                lifecycle.removeValue(forKey: lease.task.id)
                pendingQueue.remove(taskId: lease.task.id)
                waiterToCancel = row.waiter
                waiters = row.waiters
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
            // Resolved once at enqueue, so always present; failure here ends the wait instead of hanging.
            guard let timeout = nextLease.task.timeout else {
                settle(nextLease, as: .failed)
                continue
            }

            // Check capability availability
            guard waiter.isAvailable(for: nextLease.task) else {
                // Park the row with a single waiter;
                // the waiter executes or expires it when done.
                let shouldWait: Bool = lock.withLock {
                    guard var row = lifecycle[nextLease.task.id], row.lease === nextLease else { return false }
                    if row.waiting { return false }
                    row.waiting = true
                    lifecycle[nextLease.task.id] = row
                    return true
                }
                if shouldWait {
                    let waiter = Task { await self.waitForCapabilitiesAndProcess(nextLease, timeout: timeout) }
                    let alreadyTerminal: Bool = lock.withLock {
                        if var row = lifecycle[nextLease.task.id], row.lease === nextLease {
                            row.waiter = waiter
                            lifecycle[nextLease.task.id] = row
                        }
                        return nextLease.isTerminal
                    }
                    if alreadyTerminal { waiter.cancel() }
                }
                continue
            }

            // Execute the task
            await executeLease(nextLease, timeout: timeout)
        }
    }

    private func dequeueNext() -> Lease? {
        lock.withLock {
            while let id = pendingQueue.dequeue() {
                if var row = lifecycle[id] {
                    row.place = .parked
                    lifecycle[id] = row
                    return row.lease
                }
            }
            return nil
        }
    }

    private func waitForCapabilitiesAndProcess(_ lease: Lease, timeout: TimeInterval) async {
        let capabilityAvailable = await waitForCapabilities(
            lease.task,
            timeout: timeout
        )
        lock.withLock {
            if var row = lifecycle[lease.task.id], row.lease === lease {
                row.waiting = false
                row.waiter = nil
                lifecycle[lease.task.id] = row
            }
        }

        guard !lease.isTerminal else { return }

        guard capabilityAvailable else {
            settle(lease, as: .expired)
            return
        }

        await executeLease(lease, timeout: timeout)
    }

    /// Single capability wait owned by Tasks: one timeout shared by the
    /// whole set. Serves immediate (run-when-available) and queued
    /// (schedule/schedule-and-wait) execution alike, preserved across retry.
    private func waitForCapabilities(_ task: TaskDescriptor, timeout: TimeInterval) async -> Bool {
        await waiter.wait(for: task, timeout: timeout)
    }

    /// Sole production activator: every prod path to `active` goes through here
    /// (wait via the shared waiter, terminal via the single row transition).
    /// ObjC live-view tests may still call `Lease.activate()` directly to
    /// exercise the ObjcLease reflection.
    private func executeLease(_ lease: Lease, timeout: TimeInterval) async {
        guard waiter.recheck(for: lease.task) else {
            settle(lease, as: .failed)
            return
        }

        await withSlot(for: lease) {
            await self.runActivatedLease(lease, timeout: timeout)
        }
    }

    /// Scoped hold owned by the controller; scope exit shares the one release with Settlement.
    /// The defer carries this Lease's owner token, so displacing this row while
    /// active no-ops here and the new holder keeps its slot.
    private func withSlot(for lease: Lease, operation: @escaping () async -> Void) async {
        await concurrencyController.acquire(keys: lease.task.requiredCapabilities, taskId: lease.task.id, owner: ObjectIdentifier(lease))
        defer { releaseSlot(taskId: lease.task.id, owner: ObjectIdentifier(lease)) }

        guard !lease.isTerminal else { return }
        guard waiter.recheck(for: lease.task) else {
            settle(lease, as: .failed)
            return
        }

        let activated: Bool = lock.withLock {
            guard !lease.isTerminal else { return false }
            guard var row = lifecycle[lease.task.id], row.lease === lease else { return false }
            lease.activate()
            row.place = .active
            lifecycle[lease.task.id] = row
            return true
        }
        guard activated else { return }

        await operation()
    }

    private func runActivatedLease(_ lease: Lease, timeout: TimeInterval) async {
        let taskExecution: (@Sendable () async -> Any?)? = lock.withLock {
            guard let row = lifecycle[lease.task.id], row.lease === lease else { return nil }
            return row.execution
        }

        let box = OneShot<Any?>()
        let executedFirst = await waiter.race(timeout: timeout) {
            let value = await taskExecution?()
            box.store(value)
            return true
        }

        let value: Any? = executedFirst ? (box.load() ?? nil) : nil
        await settle(lease, result: value, timedOut: !executedFirst, execution: taskExecution)
    }
}
