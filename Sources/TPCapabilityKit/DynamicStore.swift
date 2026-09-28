import Combine
import Foundation

/// Dynamic in-memory state database and event broadcaster for decoupled plugins.
/// Provides both state management and capability registry functionality.
///
/// ## Thread Safety
/// - State owns its own lock, the registry owns its own lock, scheduling owns
///   its generations + clock; no caller holds a Store lock across a submodule call
///   except the generations reap pass, the single allowed Store-to-Tasks crossing,
///   which asks drain state with no scheduling lock held
/// - Changes are collected under lock and emitted after unlock, so sinks never run under lock
///
/// ## Plugin Lifecycle Order
/// - Register-before-start: capabilities register before `start` runs, so `start` can query them synchronously.
/// - Unregister postconditions: state cleared with detached subscribers completed and next update starting fresh; capabilities detached with plugin row and reverse-index entries cleared and snapshot clean.
/// - Empty-id ownership stays per domain (state owns update/get/remove/observe guards, registry owns register/unregister/query guards); facade delegates without guarding, so empty-id lifecycle entries stay observably identical to no-op.
///
/// ## Debug Logging
/// - All debug logs are guarded by `#if DEBUG` and only appear in Debug builds
/// - Logs use `[DynamicStore]` prefix for easy filtering
/// - Error logs indicate invalid API usage (e.g., empty plugin ID)
/// - Warning logs indicate unexpected but non-fatal conditions (e.g., type mismatch)
/// Thread-safe store with submodule-owned locks for all mutable state access.
/// - Important: `@unchecked Sendable` is intentional — all mutations are
///   protected by submodule locks (state, registry, scheduling own theirs). This has been verified through code review and
///   concurrency testing. Do not add unsynchronized mutable state.
public final class DynamicStore: @unchecked Sendable {
    /// Shared singleton instance.
    public static let shared = DynamicStore()

    // MARK: - Mutable State (state owns its lock; registry owns its lock; scheduling owns generations + shared time)
    private let state = StoreState()
    private let registry = CapabilityRegistry()
    private let scheduling: StoreSchedulingGenerations

    /// Creates a new DynamicStore instance. Use `DynamicStore.shared` for the shared singleton.
    /// Internal access allows test isolation via fresh instances.
    internal init(configuration: TaskScheduler.Configuration = .init()) {
        self.scheduling = StoreSchedulingGenerations(configuration: configuration, clock: .live)
    }

    // MARK: - Private Helpers

    // MARK: - Plugin Registration

    /// Registers a plugin and starts it with the current store instance.
    /// Non-empty `capabilities` are automatically registered in the capability registry.
    /// Capabilities register before `start` runs, so `start` can query them synchronously.
    /// - Parameter plugin: The plugin conforming to `AppPlugin`.
    public func register(plugin: AppPlugin) {
        // Register capabilities BEFORE starting plugin to avoid TOCTOU race
        if !plugin.capabilities.isEmpty {
            registerCapability(for: plugin.id, capabilities: plugin.capabilities)
        }

        plugin.start(with: self)
    }

    /// Updates the state for a plugin identifier.
    public func updateState<T>(pluginId: String, newState: T) {
        state.update(pluginId: pluginId, newState: newState)
    }

    /// Returns the current state for a plugin identifier.
    public func getState<T>(pluginId: String, type: T.Type) -> T? {
        return state.get(pluginId: pluginId, type: type)
    }

    /// Removes the state for a plugin identifier.
    public func removeState(for pluginId: String) {
        state.remove(pluginId: pluginId)
    }

    /// Unregisters a plugin and cleans up its state and capabilities.
    /// - Parameter plugin: The plugin to unregister.
    public func unregister(plugin: AppPlugin) {
        removeState(for: plugin.id)
        unregisterCapability(for: plugin.id)
    }

    /// Observes state changes for a plugin identifier.
    public func observeState<T>(pluginId: String, type: T.Type) -> AnyPublisher<T, Never> {
        return state.observe(pluginId: pluginId, type: type)
    }

    // MARK: - Capability Registry
    // Readiness facade in two grains (grouping is prose only; each method
    // delegates thinly to the registry, which owns set-matching):
    // - UI pair: queryCapability plus observeCapability, per-Capability Bool
    //   grain for UI-style subscribers.
    // - Tasks-only waiter: observeAllCapabilities plus waitForAllCapabilities,
    //   whole-snapshot grain for the scheduler's multi-capability descriptors.
    // Do not rebuild the whole-set wait in callers out of snapshot observation
    // plus re-query: that relearns emission ordering and drifts the empty-set
    // and already-satisfied fast paths per call site.

    /// Registers capabilities for a plugin identifier.
    /// - Parameters:
    ///   - pluginId: Unique identifier of the target plugin.
    ///   - capabilities: Set of capabilities the plugin provides.
    func registerCapability(for pluginId: String, capabilities: Set<Capability>) {
        registry.register(for: pluginId, capabilities: capabilities)
    }

    /// Unregisters all capabilities for a plugin identifier.
    /// - Parameter pluginId: Unique identifier of the target plugin.
    func unregisterCapability(for pluginId: String) {
        registry.unregister(for: pluginId)
    }

    /// UI pair half: queries whether any registered plugin provides the specified capability.
    /// Single-capability point-in-time grain for UI-style subscribers; pair with
    /// `observeCapability` rather than whole-snapshot observation or the whole-set wait.
    /// - Parameter capability: The capability to query.
    /// - Returns: `true` if at least one plugin provides the capability.
    public func queryCapability(_ capability: Capability) -> Bool {
        registry.query(capability)
    }

    /// Returns the capabilities registered by a specific plugin.
    /// - Parameter pluginId: Unique identifier of the target plugin.
    /// - Returns: Set of capabilities, or empty if plugin has none registered.
    func queryCapabilities(for pluginId: String) -> Set<Capability> {
        return registry.queryCapabilities(for: pluginId)
    }

    /// Returns all registered capabilities across all plugins.
    /// - Returns: Dictionary mapping plugin IDs to their capabilities.
    func queryAllCapabilities() -> [String: Set<Capability>] {
        registry.queryAll()
    }

    /// UI pair half: reactively observes whether any plugin provides the specified capability.
    /// Per-Capability grain for UI-style subscribers; pairs with `queryCapability`.
    /// The Tasks waiter uses whole-snapshot observation to re-evaluate
    /// multi-capability descriptors instead of this per-Capability grain.
    /// - Parameter capability: The capability to observe.
    /// - Returns: A publisher emitting `true` when the capability becomes available, `false` otherwise.
    /// - Note: Values are delivered synchronously on the writer's thread with no
    ///   lock held, so calling back into `query` APIs from a sink is safe.
    public func observeCapability(_ capability: Capability) -> AnyPublisher<Bool, Never> {
        registry.observe(capability)
    }

    /// Tasks-only waiter half: reactively observes capabilities changes across all plugins.
    /// Whole-snapshot grain for the Tasks waiter; pairs with `waitForAllCapabilities`
    /// for multi-capability descriptors. UI-style subscribers prefer the UI pair's
    /// per-Capability observation of a single `Bool`.
    /// - Returns: A publisher emitting the full capabilities dictionary on each change.
    func observeAllCapabilities() -> AnyPublisher<[String: Set<Capability>], Never> {
        registry.observeAll()
    }

    /// Tasks-only waiter half: whole-set readiness for the Tasks waiter.
    /// Thin delegation to the registry interface, so park/expiry/activate/settle
    /// stay in Tasks while set-matching lives in the registry. Pairs with
    /// `observeAllCapabilities`; do not rebuild this wait in callers out of
    /// snapshot observation plus re-query.
    func waitForAllCapabilities(
        _ required: Set<Capability>,
        race: @Sendable @escaping (@escaping CapabilityRegistry.WaitOperation) async -> Bool
    ) async -> Bool {
        await registry.waitForAll(required, race: race)
    }

    // MARK: - Task Execution

    /// One fire policy for every entry (see `fire`): sync check-and-run or
    /// queued schedule-and-wait. Binary and exclusive — a fire either bypasses
    /// the waiter or goes through it — so cases, not flags.
    public enum FirePolicy: Sendable {
        /// Point-in-time check plus direct invocation; never queues.
        case syncCheck
        /// Funnels through the one shared waiter; parks under pressure.
        case queuedWait
    }

    /// The one fire contract, stated once. The entry table on
    /// `runIfAvailable` and the Bridge scheduling door point here instead of
    /// restating it: sync fire (`syncCheck`) skips Lease, slot admission, and
    /// the expiry race by construction — point-in-time `queryCapability` plus
    /// direct invocation, with no code path to Lease, slots, or expiry;
    /// queued waits (`queuedWait`) funnel through the one waiter
    /// (`scheduler.scheduleAndWait`), so under slot pressure sync fire runs
    /// while a scheduled wait parks.
    /// Sync and async stay split — Swift concurrency forbids awaiting in a
    /// sync body — so the policy rides two overload shapes of this one entry.
    public func fire<T>(
        requiring capability: Capability,
        policy: FirePolicy,
        task: () -> T
    ) -> T? {
        switch policy {
        case .syncCheck:
            guard queryCapability(capability) else { return nil }
            return task()
        case .queuedWait:
            preconditionFailure("FirePolicy.queuedWait needs the async fire shape — await fire(_:policy:task:) — because a queued wait cannot complete synchronously.")
        }
    }

    /// Async shape of the one fire entry: builds the single-capability
    /// descriptor here, so both queued spellings share it, then funnels to
    /// the descriptor shape below.
    public func fire<T: Sendable>(
        requiring capability: Capability,
        timeout: TimeInterval = 5.0,
        policy: FirePolicy,
        task: @escaping @Sendable () async throws -> T
    ) async -> T? {
        await fire(
            TaskDescriptor(requiredCapabilities: [capability], timeout: timeout),
            policy: policy,
            task: task
        )
    }

    /// Async shape of the one fire entry over a full descriptor. The queued
    /// branch is the canonical waiter path (`scheduler.scheduleAndWait`); the
    /// sync branch is the point-in-time check plus direct invocation, with no
    /// Lease, slot, or expiry path.
    public func fire<T: Sendable>(
        _ descriptor: TaskDescriptor,
        policy: FirePolicy,
        task: @escaping @Sendable () async throws -> T
    ) async -> T? {
        switch policy {
        case .syncCheck:
            guard descriptor.requiredCapabilities.allSatisfy({ queryCapability($0) }) else { return nil }
            return try? await task()
        case .queuedWait:
            return await scheduler.scheduleAndWait(descriptor, taskExecution: task)
        }
    }

    /// Choosing a fire entry (the one decision; Bridge comments point here).
    ///
    /// | When | Call |
    /// | Check-and-run: sync fire, @objc-compatible | `runIfAvailable` |
    /// | Schedule-and-wait: async, the one waiter | `scheduleTaskAndWait` (`runTaskWhenAvailable` is the single-capability convenience over it) |
    ///
    /// Bypass contract: stated once on `fire` — this entry carries the
    /// sync-check policy.
    public func runIfAvailable<T>(
        requiring capability: Capability,
        task: () -> T
    ) -> T? {
        fire(requiring: capability, policy: .syncCheck, task: task)
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
        await fire(requiring: capability, timeout: timeout, policy: .queuedWait, task: task)
    }

    // MARK: - Task Scheduling (facade over StoreSchedulingGenerations)

    private var scheduler: TaskScheduler {
        scheduling.current(owner: self)
    }

    /// Reconfigures the scheduler without orphaning in-flight work (see StoreSchedulingGenerations).
    public func configureScheduler(_ configuration: TaskScheduler.Configuration) {
        scheduling.reconfigure(configuration, owner: self)
    }

    /// Deterministic-time delegates, spelling-only forwards to the generations module.
    internal func enableDeterministicTime(owner: DynamicStore) {
        scheduling.enableDeterministicTime(owner: owner)
    }

    internal func advanceTime(by delta: TimeInterval) async {
        await scheduling.advanceTime(by: delta)
    }

    internal func waitForDeterministicWaiters(count expected: Int) async {
        await scheduling.waitForDeterministicWaiters(count: expected)
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
        scheduler.schedule(descriptor, taskExecution: task, completion: completion)
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
        await fire(descriptor, policy: .queuedWait, task: task)
    }

    /// Cancels a pending task by its identifier.
    public func cancelTask(taskId: String) {
        scheduling.cancel(taskId: taskId)
    }

    /// Number of pending tasks, aggregated across live generations.
    public var pendingTaskCount: Int {
        scheduling.pendingCount
    }

    /// Number of active tasks, aggregated across live generations.
    public var activeTaskCount: Int {
        scheduling.activeCount
    }
}
