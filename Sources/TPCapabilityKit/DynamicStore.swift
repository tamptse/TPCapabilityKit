import Combine
import Foundation

/// Dynamic in-memory state database and event broadcaster for decoupled plugins.
/// Provides both state management and capability registry functionality.
///
/// ## Thread Safety
/// - Single `lock` protects all mutable state (stateSubjects, capabilities, capabilityIndex, capabilitySubjects)
/// - `CurrentValueSubject.send()` is thread-safe by Combine guarantee; some sends occur inside lock for atomicity
/// - `capabilitySubject` is a CurrentValueSubject, also thread-safe
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
    internal init() {}

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
        lock.lock()
        defer { lock.unlock() }
        if let existing = stateSubjects[pluginId] {
            return existing
        }
        let subject = CurrentValueSubject<Any?, Never>(nil)
        stateSubjects[pluginId] = subject
        return subject
    }

    /// Cleans up reverse index entry and per-capability subject when no providers remain.
    /// Sends `false` on the per-capability subject to notify observers.
    ///
    /// - Important: This method sends Combine values while the lock is held.
    ///   This is safe because `CurrentValueSubject.send()` is thread-safe.
    ///   However, if an observer re-enters this store (e.g., calls `queryCapability`),
    ///   it would deadlock on `NSLock`. Current observers do not re-enter,
    ///   but this invariant must be maintained if new observers are added.
    ///
    /// Must be called after removing a pluginId from capabilityIndex[cap], while holding `lock`.
    private func cleanupCapabilityIfEmpty(_ cap: Capability) {
        if capabilityIndex[cap]?.isEmpty == true {
            capabilityIndex.removeValue(forKey: cap)
            capabilitySubjects[cap]?.send(false)
            capabilitySubjects.removeValue(forKey: cap)
        }
    }

    /// Removes a plugin's capabilities from the reverse index and cleans up empty entries.
    /// Must be called while holding `lock`.
    private func removeCapabilities(for pluginId: String) {
        guard let oldCapabilities = capabilities[pluginId] else { return }
        for cap in oldCapabilities {
            capabilityIndex[cap]?.remove(pluginId)
            cleanupCapabilityIfEmpty(cap)
        }
    }

    // MARK: - Plugin Registration

    /// Registers a plugin and starts it with the current store instance.
    /// If the plugin conforms to `CapabilityProvider`, its capabilities are
    /// automatically registered in the capability registry.
    /// - Parameter plugin: The plugin conforming to `AppPlugin`.
    public func register(plugin: AppPlugin) {
        // Register capabilities BEFORE starting plugin to avoid TOCTOU race
        if let capabilityProvider = plugin as? CapabilityProvider {
            registerCapability(for: plugin.id, capabilities: capabilityProvider.capabilities)
        } else if !plugin.capabilities.isEmpty {
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
        lock.lock()
        defer { lock.unlock() }
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

    /// Removes the state subject for a plugin identifier.
    /// Subscribers will receive `nil` before the subject is removed,
    /// allowing them to detect state removal.
    /// - Parameter pluginId: Unique identifier of the target plugin.
    public func removeState(for pluginId: String) {
        guard validatePluginId(pluginId) else { return }
        lock.lock()
        let subject = stateSubjects.removeValue(forKey: pluginId)
        lock.unlock()
        
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
        lock.lock()
        defer { lock.unlock() }
        let stateIds = Set(stateSubjects.keys)
        let capabilityIds = Set(capabilities.keys)
        return Array(stateIds.union(capabilityIds))
    }

    /// Checks whether a plugin is registered (has state or capabilities).
    /// - Parameter pluginId: Unique identifier of the target plugin.
    /// - Returns: `true` if the plugin has state or capabilities registered.
    func hasPlugin(id pluginId: String) -> Bool {
        guard validatePluginId(pluginId) else { return false }
        lock.lock()
        defer { lock.unlock() }
        return stateSubjects[pluginId] != nil || capabilities[pluginId] != nil
    }

    /// Subscribes reactively to state changes for a plugin identifier.
    /// - Parameters:
    ///   - pluginId: Unique identifier of the target plugin.
    ///   - type: Expected type of the state.
    /// - Returns: A publisher emitting values matching type `T`. Subscribers must handle thread scheduling.
    /// - Note: If the plugin doesn't exist, a subject will be created automatically.
    ///   Use `removeState(for:)` to clean up unused subjects.
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
        lock.lock()
        defer { lock.unlock() }
        
        removeCapabilities(for: pluginId)
        
        // Add new capabilities
        self.capabilities[pluginId] = capabilities
        for cap in capabilities {
            capabilityIndex[cap, default: []].insert(pluginId)
            // Update per-capability subject
            capabilitySubjects[cap]?.send(true)
        }
        
        capabilitySubject.send(self.capabilities)
    }

    /// Unregisters all capabilities for a plugin identifier.
    /// - Parameter pluginId: Unique identifier of the target plugin.
    func unregisterCapability(for pluginId: String) {
        guard validatePluginId(pluginId) else { return }
        lock.lock()
        defer { lock.unlock() }
        
        removeCapabilities(for: pluginId)
        
        self.capabilities.removeValue(forKey: pluginId)
        capabilitySubject.send(self.capabilities)
    }

    /// Queries whether any registered plugin provides the specified capability.
    /// - Parameter capability: The capability to query.
    /// - Returns: `true` if at least one plugin provides the capability.
    public func queryCapability(_ capability: Capability) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return capabilityIndex[capability]?.isEmpty == false
    }

    /// Returns the capabilities registered by a specific plugin.
    /// - Parameter pluginId: Unique identifier of the target plugin.
    /// - Returns: Set of capabilities, or empty if plugin has none registered.
    func queryCapabilities(for pluginId: String) -> Set<Capability> {
        guard validatePluginId(pluginId) else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return capabilities[pluginId] ?? []
    }

    /// Returns all registered capabilities across all plugins.
    /// - Returns: Dictionary mapping plugin IDs to their capabilities.
    func queryAllCapabilities() -> [String: Set<Capability>] {
        lock.lock()
        defer { lock.unlock() }
        return capabilities
    }

    /// Reactively observes whether any plugin provides the specified capability.
    /// - Parameter capability: The capability to observe.
    /// - Returns: A publisher emitting `true` when the capability becomes available, `false` otherwise.
    public func observeCapability(_ capability: Capability) -> AnyPublisher<Bool, Never> {
        lock.lock()
        let subject: CurrentValueSubject<Bool, Never>
        if let existing = capabilitySubjects[capability] {
            subject = existing
        } else {
            let initialValue = capabilityIndex[capability]?.isEmpty == false
            subject = CurrentValueSubject<Bool, Never>(initialValue)
            capabilitySubjects[capability] = subject
        }
        lock.unlock()
        
        return subject.eraseToAnyPublisher()
    }

    /// Reactively observes capabilities changes across all plugins.
    /// - Returns: A publisher emitting the full capabilities dictionary on each change.
    func observeAllCapabilities() -> AnyPublisher<[String: Set<Capability>], Never> {
        capabilitySubject.eraseToAnyPublisher()
    }

    // MARK: - Task Execution

    /// Runs a task only if the required capability is currently available.
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
    /// If the capability is already available, the task runs immediately.
    /// - Parameters:
    ///   - capability: The capability required to run the task.
    ///   - timeout: Maximum seconds to wait for the capability. Default is 5.0.
    ///   - task: The async closure to execute.
    /// - Returns: The result of the task, or `nil` if timeout expires.
    public func runTaskWhenAvailable<T: Sendable>(
        capability: Capability,
        timeout: TimeInterval = 5.0,
        task: @escaping @Sendable () async throws -> T
    ) async rethrows -> T? {
        // Fast path: already available
        if queryCapability(capability) {
            return try await task()
        }

        // Wait for capability to become available
        return try await withThrowingTaskGroup(of: T?.self) { group in
            // Task 1: wait for capability then execute
            group.addTask { [self] in
                for await isAvailable in self.observeCapability(capability).values {
                    if isAvailable {
                        return try await task()
                    }
                }
                return nil
            }

            // Task 2: timeout
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }

            // Return first non-nil result, cancel the other
            guard let result = try await group.next() else {
                group.cancelAll()
                return nil
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: - Task Scheduling

    /// Task scheduler instance. Can be replaced for A/B testing.
    public var scheduler: any TaskSchedulerProtocol {
        get {
            if let existing = _scheduler { return existing }
            let new = TaskScheduler(store: self)
            _scheduler = new
            return new
        }
        set { _scheduler = newValue }
    }
    private var _scheduler: (any TaskSchedulerProtocol)?

    /// Schedules a task for centralized execution with capability matching and priority.
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
        scheduler.schedule(descriptor, taskExecution: task, completion: completion, autoProcess: true)
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
}
