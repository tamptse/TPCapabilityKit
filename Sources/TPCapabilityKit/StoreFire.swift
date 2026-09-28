import Combine
import Foundation

extension DynamicStore {
    // MARK: - Task Execution

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
    /// this one entry. No policy value travels: the shape decides, so the
    /// crashing sync-plus-queued combination is unrepresentable.
    public func fire<T>(
        requiring capability: Capability,
        task: () -> T
    ) -> T? {
        guard queryCapability(capability) else { return nil }
        return task()
    }

    /// Async shape of the one fire entry: builds the single-capability
    /// descriptor here, so both queued spellings share it, then funnels to
    /// the descriptor shape below.
    public func fire<T: Sendable>(
        requiring capability: Capability,
        timeout: TimeInterval = 5.0,
        task: @escaping @Sendable () async throws -> T
    ) async -> T? {
        await fire(
            TaskDescriptor(requiredCapabilities: [capability], timeout: timeout),
            task: task
        )
    }

    /// Async shape of the one fire entry over a full descriptor: the canonical
    /// waiter path (`scheduler.scheduleAndWait`), with no Lease, slot, or
    /// expiry bypass — async callers needing a point-in-time check use the
    /// sync shape above.
    public func fire<T: Sendable>(
        _ descriptor: TaskDescriptor,
        task: @escaping @Sendable () async throws -> T
    ) async -> T? {
        await scheduler.scheduleAndWait(descriptor, taskExecution: task)
    }

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

    /// Legacy async immediate, kept bit-identical for existing callers.
    /// Prefer the two documented entries (see `runIfAvailable`): sync
    /// check-and-run, or `scheduleTaskAndWait` for the queued waiter.
    @available(*, deprecated, message: "Use runIfAvailable(requiring:task:) for sync check-and-run, or scheduleTaskAndWait for the queued waiter.")
    public func runTask<T>(
        requiring capability: Capability,
        task: () async throws -> T
    ) async rethrows -> T? {
        guard queryCapability(capability) else { return nil }
        return try await task()
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
