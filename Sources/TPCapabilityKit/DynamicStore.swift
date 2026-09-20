import Combine
import Foundation

/// Dynamic in-memory state database and event broadcaster for decoupled plugins.
/// Provides both state management and capability registry functionality.
///
/// ## Thread Safety
/// - Single `lock` protects all mutable state (stateSubjects, capabilities, capabilityIndex, capabilitySubjects)
/// - Changes are collected under lock and emitted after unlock, so sinks never run under lock
///
/// ## Debug Logging
/// - All debug logs are guarded by `#if DEBUG` and only appear in Debug builds
/// - Logs use `[DynamicStore]` prefix for easy filtering
/// - Error logs indicate invalid API usage (e.g., empty plugin ID)
/// - Warning logs indicate unexpected but non-fatal conditions (e.g., type mismatch)
/// Thread-safe store using NSLock for all mutable state access.
/// - Important: `@unchecked Sendable` is intentional — all mutations are
///   protected by `lock`. This has been verified through code review and
///   concurrency testing. Do not add unsynchronized mutable state.
public final class DynamicStore: @unchecked Sendable {
    /// Shared singleton instance.
    public static let shared = DynamicStore()

    // MARK: - Mutable State (all protected by single `lock`)
    private var stateSubjects: [String: CurrentValueSubject<Any?, Never>] = [:]
    private var capabilities: [String: Set<Capability>] = [:]
    private var capabilityIndex: [Capability: Set<String>] = [:]  // Reverse index for O(1) queries
    private var capabilitySubjects: [Capability: CurrentValueSubject<Bool, Never>] = [:]  // Per-capability subjects
    private let lock = NSLock()
    private let capabilitySubject = CurrentValueSubject<[String: Set<Capability>], Never>([:])

    /// Creates a new DynamicStore instance. Use `DynamicStore.shared` for the shared singleton.
    /// Internal access allows test isolation via fresh instances.
    internal init(configuration: TaskScheduler.Configuration = .init()) {
        self.schedulerConfiguration = configuration
    }

    // MARK: - Private Helpers

    private func validatePluginId(_ pluginId: String) -> Bool {
        guard !pluginId.isEmpty else {
            #if DEBUG
            print("[DynamicStore] Error: Plugin ID cannot be empty")
            #endif
            return false
        }
        return true
    }

    private func ensureSubject(for pluginId: String) -> CurrentValueSubject<Any?, Never> {
        lock.withLock {
            if let existing = stateSubjects[pluginId] {
                return existing
            }
            let subject = CurrentValueSubject<Any?, Never>(nil)
            stateSubjects[pluginId] = subject
            return subject
        }
    }

    /// Cleans up reverse index entry and per-capability subject when no providers remain.
    /// Queues a `false` notification; the caller sends it after unlocking.
    ///
    /// Must be called after removing a pluginId from capabilityIndex[cap], while holding `lock`.
    private func cleanupCapabilityIfEmpty(
        _ cap: Capability,
        pending: inout [(CurrentValueSubject<Bool, Never>, Bool)]
    ) {
        if capabilityIndex[cap]?.isEmpty == true {
            capabilityIndex.removeValue(forKey: cap)
            if let subject = capabilitySubjects.removeValue(forKey: cap) {
                pending.append((subject, false))
            }
        }
    }

    /// Removes a plugin's capabilities from the reverse index and cleans up empty entries.
    /// Must be called while holding `lock`.
    private func removeCapabilities(
        for pluginId: String,
        pending: inout [(CurrentValueSubject<Bool, Never>, Bool)]
    ) {
        guard let oldCapabilities = capabilities[pluginId] else { return }
        for cap in oldCapabilities {
            capabilityIndex[cap]?.remove(pluginId)
            cleanupCapabilityIfEmpty(cap, pending: &pending)
        }
    }

    // MARK: - Plugin Registration

    /// Registers a plugin and starts it with the current store instance.
    /// Non-empty `capabilities` are automatically registered in the capability registry.
    /// - Parameter plugin: The plugin conforming to `AppPlugin`.
    public func register(plugin: AppPlugin) {
        // Register capabilities BEFORE starting plugin to avoid TOCTOU race
        if !plugin.capabilities.isEmpty {
            registerCapability(for: plugin.id, capabilities: plugin.capabilities)
        }

        plugin.start(with: self)
    }

    /// Updates the state associated with a plugin identifier.
    /// - Parameters:
    ///   - pluginId: Unique identifier of the target plugin.
    ///   - newState: The new state value to update or broadcast.
    public func updateState<T>(pluginId: String, newState: T) {
        guard validatePluginId(pluginId) else { return }
        let subject = ensureSubject(for: pluginId)
        subject.send(newState)
    }

    /// Synchronously retrieves the current state for a plugin identifier.
    /// - Parameters:
    ///   - pluginId: Unique identifier of the target plugin.
    ///   - type: Expected type of the state.
    /// - Returns: The state cast to `T`, or `nil` if not set or type mismatch.
    public func getState<T>(pluginId: String, type: T.Type) -> T? {
        guard validatePluginId(pluginId) else { return nil }
        return lock.withLock {
            guard let subject = stateSubjects[pluginId] else {
                #if DEBUG
                print("[DynamicStore] Warning: getState called for non-existent plugin '\(pluginId)'")
                #endif
                return nil
            }
            guard let value = subject.value as? T else {
                #if DEBUG
                print("[DynamicStore] Warning: Type mismatch for plugin '\(pluginId)': expected \(T.self)")
                #endif
                return nil
            }
            return value
        }
    }

    /// Removes the state subject for a plugin identifier.
    /// Subscribers will receive `nil` before the subject is removed,
    /// allowing them to detect state removal.
    /// - Parameter pluginId: Unique identifier of the target plugin.
    public func removeState(for pluginId: String) {
        guard validatePluginId(pluginId) else { return }
        var subject: CurrentValueSubject<Any?, Never>?
        lock.withLock {
            subject = stateSubjects.removeValue(forKey: pluginId)
        }
        
        // Notify subscribers before removal so they can detect state removal
        subject?.send(nil)
    }

    /// Unregisters a plugin and cleans up its state and capabilities.
    /// - Parameter plugin: The plugin to unregister.
    public func unregister(plugin: AppPlugin) {
        removeState(for: plugin.id)
        unregisterCapability(for: plugin.id)
    }

    /// Returns all registered plugin identifiers.
    /// - Returns: Array of plugin IDs that have state or capabilities registered.
    var registeredPluginIds: [String] {
        lock.withLock {
            let stateIds = Set(stateSubjects.keys)
            let capabilityIds = Set(capabilities.keys)
            return Array(stateIds.union(capabilityIds))
        }
    }

    /// Checks whether a plugin is registered (has state or capabilities).
    /// - Parameter pluginId: Unique identifier of the target plugin.
    /// - Returns: `true` if the plugin has state or capabilities registered.
    func hasPlugin(id pluginId: String) -> Bool {
        guard validatePluginId(pluginId) else { return false }
        return lock.withLock {
            stateSubjects[pluginId] != nil || capabilities[pluginId] != nil
        }
    }

    /// Subscribes reactively to state changes for a plugin identifier.
    /// - Parameters:
    ///   - pluginId: Unique identifier of the target plugin.
    ///   - type: Expected type of the state.
    /// - Returns: A publisher emitting values matching type `T`. Subscribers must handle thread scheduling.
    /// - Note: If the plugin doesn't exist, a subject will be created automatically.
    ///   Use `removeState(for:)` to clean up unused subjects.
    /// - Note: Values are delivered synchronously on the writer's thread with no
    ///   lock held, so calling back into `query` APIs from a sink is safe.
    public func observeState<T>(pluginId: String, type: T.Type) -> AnyPublisher<T, Never> {
        let subject = ensureSubject(for: pluginId)
        return subject
            .compactMap { $0 as? T }
            .eraseToAnyPublisher()
    }

    // MARK: - Capability Registry

    /// Registers capabilities for a plugin identifier.
    /// - Parameters:
    ///   - pluginId: Unique identifier of the target plugin.
    ///   - capabilities: Set of capabilities the plugin provides.
    func registerCapability(for pluginId: String, capabilities: Set<Capability>) {
        guard validatePluginId(pluginId) else { return }
        var pending: [(CurrentValueSubject<Bool, Never>, Bool)] = []
        var snapshot: [String: Set<Capability>] = [:]
        lock.withLock {
            removeCapabilities(for: pluginId, pending: &pending)

            // Add new capabilities
            self.capabilities[pluginId] = capabilities
            for cap in capabilities {
                capabilityIndex[cap, default: []].insert(pluginId)
                if let subject = capabilitySubjects[cap] {
                    pending.append((subject, true))
                }
            }

            snapshot = self.capabilities
        }
        for (subject, value) in pending {
            subject.send(value)
        }
        capabilitySubject.send(snapshot)
    }

    /// Unregisters all capabilities for a plugin identifier.
    /// - Parameter pluginId: Unique identifier of the target plugin.
    func unregisterCapability(for pluginId: String) {
        guard validatePluginId(pluginId) else { return }
        var pending: [(CurrentValueSubject<Bool, Never>, Bool)] = []
        var snapshot: [String: Set<Capability>] = [:]
        lock.withLock {
            removeCapabilities(for: pluginId, pending: &pending)

            self.capabilities.removeValue(forKey: pluginId)
            snapshot = self.capabilities
        }
        for (subject, value) in pending {
            subject.send(value)
        }
        capabilitySubject.send(snapshot)
    }

    /// Queries whether any registered plugin provides the specified capability.
    /// - Parameter capability: The capability to query.
    /// - Returns: `true` if at least one plugin provides the capability.
    public func queryCapability(_ capability: Capability) -> Bool {
        lock.withLock {
            return capabilityIndex[capability]?.isEmpty == false
        }
    }

    /// Returns the capabilities registered by a specific plugin.
    /// - Parameter pluginId: Unique identifier of the target plugin.
    /// - Returns: Set of capabilities, or empty if plugin has none registered.
    func queryCapabilities(for pluginId: String) -> Set<Capability> {
        guard validatePluginId(pluginId) else { return [] }
        return lock.withLock {
            capabilities[pluginId] ?? []
        }
    }

    /// Returns all registered capabilities across all plugins.
    /// - Returns: Dictionary mapping plugin IDs to their capabilities.
    func queryAllCapabilities() -> [String: Set<Capability>] {
        lock.withLock {
            return capabilities
        }
    }

    /// Reactively observes whether any plugin provides the specified capability.
    /// - Parameter capability: The capability to observe.
    /// - Returns: A publisher emitting `true` when the capability becomes available, `false` otherwise.
    /// - Note: Values are delivered synchronously on the writer's thread with no
    ///   lock held, so calling back into `query` APIs from a sink is safe.
    public func observeCapability(_ capability: Capability) -> AnyPublisher<Bool, Never> {
        let subject: CurrentValueSubject<Bool, Never> = lock.withLock {
            if let existing = capabilitySubjects[capability] {
                return existing
            } else {
                let initialValue = capabilityIndex[capability]?.isEmpty == false
                let subject = CurrentValueSubject<Bool, Never>(initialValue)
                capabilitySubjects[capability] = subject
                return subject
            }
        }
        
        return subject.eraseToAnyPublisher()
    }

    /// Reactively observes capabilities changes across all plugins.
    /// - Returns: A publisher emitting the full capabilities dictionary on each change.
    func observeAllCapabilities() -> AnyPublisher<[String: Set<Capability>], Never> {
        capabilitySubject.eraseToAnyPublisher()
    }

    // MARK: - Task Execution

    /// Runs a task only if the required capability is currently available.
    /// Immediate fire; for queued work use scheduleTask.
    /// - Parameters:
    ///   - capability: The capability required to run the task.
    ///   - task: The async closure to execute.
    /// - Returns: The result of the task, or `nil` if the capability is not available.
    public func runTask<T>(
        requiring capability: Capability,
        task: () async throws -> T
    ) async rethrows -> T? {
        guard queryCapability(capability) else { return nil }
        return try await task()
    }

    /// Runs a task when the required capability becomes available, with a timeout.
    /// Shares the Tasks waiter with queued scheduling, so immediate and queued
    /// styles behave identically.
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
        await scheduleTaskAndWait(
            TaskDescriptor(requiredCapabilities: [capability], timeout: timeout),
            task: task
        )
    }

    // MARK: - Task Scheduling

    var scheduler: TaskScheduler {
        lock.withLock {
            if let existing = _scheduler { return existing }
            let new = TaskScheduler(store: self, configuration: schedulerConfiguration)
            _scheduler = new
            return new
        }
    }
    private var _scheduler: TaskScheduler?
    private var schedulerConfiguration: TaskScheduler.Configuration

    public func configureScheduler(_ configuration: TaskScheduler.Configuration) {
        lock.withLock {
            schedulerConfiguration = configuration
            _scheduler = nil
        }
    }

    /// Schedules a task for centralized execution with capability matching and priority.
    /// Queued work; for immediate fire use runTask.
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
    /// - Parameters:
    ///   - descriptor: The task descriptor.
    ///   - task: The async closure to execute.
    /// - Returns: The result, or nil if timeout/error.
    public func scheduleTaskAndWait<T: Sendable>(
        _ descriptor: TaskDescriptor,
        task: @escaping @Sendable () async throws -> T
    ) async -> T? {
        await scheduler.scheduleAndWait(descriptor, taskExecution: task)
    }

    /// Cancels a pending task by its identifier.
    public func cancelTask(taskId: String) {
        scheduler.cancel(taskId: taskId)
    }

    /// Number of pending tasks.
    public var pendingTaskCount: Int { scheduler.pendingCount }

    /// Number of active tasks.
    public var activeTaskCount: Int { scheduler.activeCount }
}
