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
///   (`pendingQueue`, `parkedLeases`, `activeLeases`, `taskExecutions`,
///   `rendezvous`, `waitingLeases`, `parkedWaiters`) is protected by `lock`. Parked capability waiters are
///   tracked per lease and cancelled on terminal settlement. Do not add
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

    /// Capability gate: conjunction with one shared deadline.
    ///
    /// Hides availability check, wait, and slot re-check behind one seam.
    /// Holds no lock or waiter state; single waiter, rendezvous, and expiry
    /// clock stay owned by the scheduler.
    private struct CapabilityGate: Sendable {
        private let isSatisfied: @Sendable (Set<Capability>) -> Bool
        private let snapshot: @Sendable () -> AnyPublisher<[String: Set<Capability>], Never>?
        private let race: @Sendable (TimeInterval, @Sendable @escaping () async -> Bool) async -> Bool

        init(
            isSatisfied: @escaping @Sendable (Set<Capability>) -> Bool,
            snapshot: @escaping @Sendable () -> AnyPublisher<[String: Set<Capability>], Never>?,
            race: @escaping @Sendable (TimeInterval, @Sendable @escaping () async -> Bool) async -> Bool
        ) {
            self.isSatisfied = isSatisfied
            self.snapshot = snapshot
            self.race = race
        }

        func isAvailable(_ capabilities: Set<Capability>) -> Bool {
            isSatisfied(capabilities)
        }

        func isAvailable(for task: TaskDescriptor) -> Bool {
            isAvailable(task.requiredCapabilities)
        }

        func wait(for capabilities: Set<Capability>, timeout: TimeInterval) async -> Bool {
            if capabilities.isEmpty { return true }
            if isAvailable(capabilities) { return true }
            let probe = isSatisfied
            let observe = snapshot
            return await race(timeout) {
                guard let publisher = observe() else { return false }
                for await _ in publisher.values {
                    if probe(capabilities) { return true }
                }
                return false
            }
        }

        func recheck(for task: TaskDescriptor) -> Bool {
            isAvailable(for: task)
        }
    }

    private var capabilityGate: CapabilityGate {
        let store = self.store
        return CapabilityGate(
            isSatisfied: { [weak store] capabilities in
                guard let store else { return false }
                return capabilities.allSatisfy { store.queryCapability($0) }
            },
            snapshot: { [weak store] in store?.observeAllCapabilities() },
            race: { timeout, operation in await TaskScheduler.race(timeout: timeout, operation: operation) }
        )
    }

    private static func race(
        timeout: TimeInterval,
        operation: @Sendable @escaping () async -> Bool
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
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

    private func raceAgainstTimeout(
        timeout: TimeInterval,
        operation: @Sendable @escaping () async -> Bool
    ) async -> Bool {
        await Self.race(timeout: timeout, operation: operation)
    }

    private var pendingQueue = PendingQueue()

    private var activeLeases: [String: Lease] = [:]

    private var parkedLeases: [String: Lease] = [:]

    private var taskExecutions: [String: @Sendable () async -> Any?] = [:]

    // Single rendezvous keyed by Lease identity so same-id Tasks never overwrite each other.
    private var rendezvous: [ObjectIdentifier: [(Lease) -> Void]] = [:]

    // One waiter per lease at a time, so the pending loop never spawns duplicates.
    private var waitingLeases: Set<String> = []

    // Cancelled on settlement so a parked waiter wakes promptly instead of lingering until timeout.
    private var parkedWaiters: [String: Task<Void, Never>] = [:]

    init(store: DynamicStore = .shared, configuration: Configuration = .init()) {
        self.store = store
        self.configuration = configuration
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

        lock.withLock {
            pendingQueue.enqueue(lease)
            taskExecutions[task.id] = execution
            rendezvous[ObjectIdentifier(lease)] = []
            if let completion {
                rendezvous[ObjectIdentifier(lease), default: []].append(completion)
            }
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
                rendezvous[ObjectIdentifier(lease), default: []].append({ resume(with: $0) })
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
        let target: Lease? = lock.withLock {
            pendingQueue.lease(taskId: taskId)
                ?? parkedLeases[taskId]
                ?? activeLeases[taskId]
        }
        guard let target else { return }
        settle(target, as: .cancelled)
    }

    /// Returns the number of pending tasks.
    var pendingCount: Int {
        lock.withLock { pendingQueue.count }
    }

    /// Returns the number of active tasks.
    var activeCount: Int {
        lock.withLock {
            activeLeases.count
        }
    }

    // MARK: - Private Methods

    private enum Settlement {
        case completed(Any?)
        case failed
        case expired
        case cancelled
    }

    private func settle(_ lease: Lease, as outcome: Settlement) {
        switch outcome {
        case .completed(let result):
            terminalize(lease, applyState: { $0.complete(with: result) })
        case .failed:
            let error = TaskExecutionError()
            terminalize(lease, applyState: { $0.fail(with: error) })
        case .expired, .cancelled:
            terminalize(lease, applyState: { $0.expire() })
        }
    }

    private func settle(_ lease: Lease, result: Any?, timedOut: Bool, execution: (@Sendable () async -> Any?)?) async {
        if lease.isTerminal { return }
        if timedOut {
            settle(lease, as: .expired)
            return
        }
        if result != nil {
            settle(lease, as: .completed(result))
            return
        }
        if requeueForRetry(lease, execution: execution) {
            return
        }
        if lease.isTerminal { return }
        settle(lease, as: .failed)
    }

    /// Retry path: guards `isTerminal`/`canRetry`, then `beginRetry()` resets to pending.
    /// See the Lease transition contract for the legal graph.
    private func requeueForRetry(_ lease: Lease, execution: (@Sendable () async -> Any?)?) -> Bool {
        var retried = false
        lock.withLock {
            guard !lease.isTerminal else { return }
            if lease.canRetry {
                lease.beginRetry()
                activeLeases.removeValue(forKey: lease.task.id)
                if let execution {
                    taskExecutions[lease.task.id] = execution
                }
                pendingQueue.requeue(lease)
                retried = true
            }
        }
        if retried {
            concurrencyController.release(taskId: lease.task.id)
            Task { await self.processPendingTasks() }
            return true
        }
        return false
    }

    /// Single terminal path: cleanup under lock, state decided under
    /// lock, completion outside the lock. Fires exactly once per
    /// lease via the `isTerminal` guard.
    /// See the Lease transition contract for the legal graph; cancel-of-pending
    /// settles here via `expire()`, the only terminal move accepting pending.
    private func terminalize(
        _ lease: Lease,
        applyState: (Lease) -> Void
    ) {
        var waiters: [(Lease) -> Void] = []
        var settled = false
        var waiterToCancel: Task<Void, Never>?
        lock.withLock {
            guard !lease.isTerminal else { return }
            _ = pendingQueue.remove(taskId: lease.task.id)
            activeLeases.removeValue(forKey: lease.task.id)
            parkedLeases.removeValue(forKey: lease.task.id)
            waitingLeases.remove(lease.task.id)
            waiterToCancel = parkedWaiters.removeValue(forKey: lease.task.id)
            taskExecutions.removeValue(forKey: lease.task.id)
            waiters = rendezvous.removeValue(forKey: ObjectIdentifier(lease)) ?? []
            applyState(lease)
            settled = true
        }
        guard settled else { return }
        waiterToCancel?.cancel()
        concurrencyController.release(taskId: lease.task.id)
        for waiter in waiters {
            waiter(lease)
        }
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
            guard checkCapabilities(for: nextLease.task) else {
                // Park the lease outside the queue with a single waiter;
                // the waiter executes or expires it when done.
                let shouldWait: Bool = lock.withLock {
                    if waitingLeases.contains(nextLease.task.id) { return false }
                    waitingLeases.insert(nextLease.task.id)
                    parkedLeases[nextLease.task.id] = nextLease
                    return true
                }
                if shouldWait {
                    let waiter = Task { await self.waitForCapabilitiesAndProcess(nextLease, timeout: timeout) }
                    let alreadyTerminal: Bool = lock.withLock {
                        parkedWaiters[nextLease.task.id] = waiter
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
            guard let lease = pendingQueue.dequeue() else { return nil }
            parkedLeases[lease.task.id] = lease
            return lease
        }
    }

    private func checkCapabilities(for task: TaskDescriptor) -> Bool {
        capabilityGate.isAvailable(for: task)
    }

    private func waitForCapabilitiesAndProcess(_ lease: Lease, timeout: TimeInterval) async {
        let capabilityAvailable = await waitForCapabilities(
            lease.task.requiredCapabilities,
            timeout: timeout
        )
        lock.withLock {
            waitingLeases.remove(lease.task.id)
            parkedWaiters.removeValue(forKey: lease.task.id)
        }

        guard !lease.isTerminal else { return }

        guard capabilityAvailable else {
            settle(lease, as: .expired)
            return
        }

        await executeLease(lease, timeout: timeout)
    }

    /// Single capability waiter owned by Tasks: one timeout shared by the
    /// whole set. Serves immediate (run-when-available) and queued
    /// (schedule/schedule-and-wait) execution alike, preserved across retry.
    private func waitForCapabilities(_ capabilities: Set<Capability>, timeout: TimeInterval) async -> Bool {
        await capabilityGate.wait(for: capabilities, timeout: timeout)
    }

    /// Sole production activator: every prod path to `active` goes through here
    /// (wait via the shared waiter, terminal via `terminalize`).
    /// Tests may still call `Lease.activate()` directly.
    private func executeLease(_ lease: Lease, timeout: TimeInterval) async {
        guard capabilityGate.recheck(for: lease.task) else {
            settle(lease, as: .failed)
            return
        }

        await withSlot(for: lease) {
            await self.runActivatedLease(lease, timeout: timeout)
        }
    }

    /// Scoped hold owned by the controller; scope exit shares the one idempotent release.
    private func withSlot(for lease: Lease, operation: @escaping () async -> Void) async {
        await concurrencyController.acquire(keys: lease.task.requiredCapabilities, taskId: lease.task.id)
        defer { concurrencyController.release(taskId: lease.task.id) }

        guard !lease.isTerminal else { return }
        guard capabilityGate.recheck(for: lease.task) else {
            settle(lease, as: .failed)
            return
        }

        let activated: Bool = lock.withLock {
            guard !lease.isTerminal else { return false }
            lease.activate()
            parkedLeases.removeValue(forKey: lease.task.id)
            activeLeases[lease.task.id] = lease
            return true
        }
        guard activated else { return }

        await operation()
    }

    private func runActivatedLease(_ lease: Lease, timeout: TimeInterval) async {
        let taskExecution: (@Sendable () async -> Any?)? = lock.withLock {
            taskExecutions[lease.task.id]
        }

        let box = OneShot<Any?>()
        let executedFirst = await raceAgainstTimeout(timeout: timeout) {
            let value = await taskExecution?()
            box.store(value)
            return true
        }

        let value: Any? = executedFirst ? (box.load() ?? nil) : nil
        await settle(lease, result: value, timedOut: !executedFirst, execution: taskExecution)
    }
}
