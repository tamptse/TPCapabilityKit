import Combine
import Foundation

extension DynamicStore {
    // MARK: - Fire core (one funnel; contract stated once)

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
    /// the descriptor shape below.
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
}
