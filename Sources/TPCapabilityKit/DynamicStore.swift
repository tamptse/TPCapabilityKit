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
    let scheduling: StoreSchedulingGenerations

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
}
