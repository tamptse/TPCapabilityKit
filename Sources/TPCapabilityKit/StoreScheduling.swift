import Foundation

extension DynamicStore {
    // MARK: - Task Scheduling facade (one facade: entries + funnel + thin delegation)

    // MARK: Fire core (one funnel; contract stated once)

    /// The one fire contract, stated once. The entry table on
    /// `runIfAvailable` and the Bridge scheduling door point here instead of
    /// restating it: sync fire skips Lease, slot admission, and
    /// the expiry race by construction — point-in-time `queryCapability` plus
    /// direct invocation, with no code path to Lease, slots, or expiry;
    /// queued waits funnel through the one waiter
    /// (`scheduler.scheduleAndWait`), so under slot pressure sync fire runs
    /// while a scheduled wait parks.
    /// Sync and async stay split — Swift concurrency forbids awaiting in a
    /// sync body — so sync-check and queued-wait ride two overload shapes of
    /// this one core. No policy value travels: the shape decides, so the
    /// crashing sync-plus-queued combination is unrepresentable.
    /// Package, not public: the documented entries are `runIfAvailable`
    /// (sync check-and-run) and `scheduleTaskAndWait` (async
    /// schedule-and-wait) plus the `runTaskWhenAvailable` single-capability
    /// convenience; the Bridge door lives in this package, so it funnels
    /// through this core directly.
    package func fire<T>(
        requiring capability: Capability,
        task: () -> T
    ) -> T? {
        guard queryCapability(capability) else { return nil }
        return task()
    }

    /// Async shape of the one fire core: builds the single-capability
    /// descriptor here, so both queued spellings share it, then funnels to
    /// the descriptor shape below. Swift default only; the Bridge pin differs
    /// by intent — see the Timeout Resolver Contract on Deadline.
    package func fire<T: Sendable>(
        requiring capability: Capability,
        timeout: TimeInterval = 5.0,
        task: @escaping @Sendable () async throws -> T
    ) async -> T? {
        await fire(
            TaskDescriptor(requiredCapabilities: [capability], timeout: timeout),
            task: task
        )
    }

    /// Async shape of the one fire core over a full descriptor: the canonical
    /// waiter path (`scheduler.scheduleAndWait`), with no Lease, slot, or
    /// expiry bypass — async callers needing a point-in-time check use the
    /// sync shape above.
    package func fire<T: Sendable>(
        _ descriptor: TaskDescriptor,
        task: @escaping @Sendable () async throws -> T
    ) async -> T? {
        await scheduling.scheduleAndWait(descriptor, taskExecution: task)
    }

    // MARK: - Fire entries (the two documented spellings + convenience)

    /// Choosing a fire entry (the one decision; Bridge comments point here).
    ///
    /// | When | Call |
    /// | Check-and-run: sync fire, @objc-compatible | `runIfAvailable` |
    /// | Schedule-and-wait: async, the one waiter | `scheduleTaskAndWait` (`runTaskWhenAvailable` is the single-capability convenience over it) |
    ///
    /// Bypass contract: stated once on `fire` — this entry is the
    /// sync-check spelling.
    public func runIfAvailable<T>(
        requiring capability: Capability,
        task: () -> T
    ) -> T? {
        fire(requiring: capability, task: task)
    }

    /// Single-capability convenience over the one waiter (see `fire`).
    /// For the entry choice see `runIfAvailable`.
    /// - Parameters:
    ///   - capability: The capability required to run the task.
    ///   - timeout: Maximum seconds to wait for the capability. Default is 5.0.
    ///   - task: The async closure to execute.
    /// - Returns: The result of the task, or `nil` if timeout expires.
    public func runTaskWhenAvailable<T: Sendable>(
        capability: Capability,
        timeout: TimeInterval = 5.0,
        task: @escaping @Sendable () async throws -> T
    ) async -> T? {
        await fire(requiring: capability, timeout: timeout, task: task)
    }

    // MARK: - Scheduling delegation (thin; no locking, fan-out, or reap of its own)

    /// Reconfigures the scheduler without orphaning in-flight work (see StoreSchedulingGenerations).
    public func configureScheduler(_ configuration: TaskScheduler.Configuration) {
        scheduling.reconfigure(configuration)
    }

    /// Schedules a task for centralized execution with capability matching and priority.
    /// Queued work; for immediate fire see the entry table on `runIfAvailable`.
    /// - Parameters:
    ///   - descriptor: The task descriptor.
    ///   - task: The async closure to execute.
    ///   - completion: Optional completion handler.
    /// - Returns: The lease for tracking.
    @discardableResult
    public func scheduleTask(
        _ descriptor: TaskDescriptor,
        task: @escaping @Sendable () async -> Void,
        completion: ((Lease) -> Void)? = nil
    ) -> Lease {
        scheduling.schedule(descriptor, taskExecution: task, completion: completion)
    }

    /// Schedules a task and waits for its result.
    /// Queued-style entry to the one shared Tasks waiter (see `fire`);
    /// `runTaskWhenAvailable` is the single-capability convenience over the
    /// same core, so both styles behave identically.
    /// - Parameters:
    ///   - descriptor: The task descriptor.
    ///   - task: The async closure to execute.
    /// - Returns: The result, or nil if timeout/error.
    public func scheduleTaskAndWait<T: Sendable>(
        _ descriptor: TaskDescriptor,
        task: @escaping @Sendable () async throws -> T
    ) async -> T? {
        await fire(descriptor, task: task)
    }

    public func cancelTask(taskId: String) {
        scheduling.cancel(taskId: taskId)
    }

    /// Best-effort point-in-time count, aggregated across live generations. For agreement use the internal countsSnapshot tuple.
    public var pendingTaskCount: Int {
        scheduling.countsSnapshot.pending
    }

    /// Best-effort point-in-time count, aggregated across live generations. For agreement use the internal countsSnapshot tuple.
    public var activeTaskCount: Int {
        scheduling.countsSnapshot.active
    }
}

// MARK: - Scheduling / store deterministic test facet

extension DynamicStore {
    func enableDeterministicTime() {
        precondition(self !== DynamicStore.shared, "deterministic time only on fresh instances")
        precondition(scheduling.isEmpty, "enableDeterministicTime must precede first schedule")
        scheduling.enableDeterministicTime()
    }

    func advanceTime(by delta: TimeInterval) async {
        await scheduling.advanceTime(by: delta)
    }

    func waitForDeterministicWaiters(count expected: Int) async {
        await scheduling.waitForDeterministicWaiters(count: expected)
    }
}
