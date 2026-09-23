import Combine
import Foundation

/// Dynamic in-memory state database and event broadcaster for decoupled plugins.
/// Provides both state management and capability registry functionality.
///
/// ## Thread Safety
/// - State owns its own lock, the registry owns its own lock, scheduling owns
///   its generations + clock; no caller holds a Store lock across a submodule call
/// - Changes are collected under lock and emitted after unlock, so sinks never run under lock
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

    // MARK: - Mutable State (state owns its lock; registry owns its lock; scheduling owns its generations + clock)
    private let state = StoreState()
    private let registry = CapabilityRegistry()
    private let scheduling: StoreSchedulingGenerations

    /// Creates a new DynamicStore instance. Use `DynamicStore.shared` for the shared singleton.
    /// Internal access allows test isolation via fresh instances.
    internal init(configuration: TaskScheduler.Configuration = .init()) {
        self.scheduling = StoreSchedulingGenerations(configuration: configuration)
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

    /// Registers capabilities for a plugin identifier.
    /// - Parameters:
    ///   - pluginId: Unique identifier of the target plugin.
    ///   - capabilities: Set of capabilities the plugin provides.
    func registerCapability(for pluginId: String, capabilities: Set<Capability>) {
        guard validatePluginId(pluginId) else { return }
        registry.register(for: pluginId, capabilities: capabilities)
    }

    /// Unregisters all capabilities for a plugin identifier.
    /// - Parameter pluginId: Unique identifier of the target plugin.
    func unregisterCapability(for pluginId: String) {
        guard validatePluginId(pluginId) else { return }
        registry.unregister(for: pluginId)
    }

    /// Queries whether any registered plugin provides the specified capability.
    /// - Parameter capability: The capability to query.
    /// - Returns: `true` if at least one plugin provides the capability.
    public func queryCapability(_ capability: Capability) -> Bool {
        registry.query(capability)
    }

    /// Returns the capabilities registered by a specific plugin.
    /// - Parameter pluginId: Unique identifier of the target plugin.
    /// - Returns: Set of capabilities, or empty if plugin has none registered.
    func queryCapabilities(for pluginId: String) -> Set<Capability> {
        guard validatePluginId(pluginId) else { return [] }
        return registry.queryCapabilities(for: pluginId)
    }

    /// Returns all registered capabilities across all plugins.
    /// - Returns: Dictionary mapping plugin IDs to their capabilities.
    func queryAllCapabilities() -> [String: Set<Capability>] {
        registry.queryAll()
    }

    /// Reactively observes whether any plugin provides the specified capability.
    /// Per-Capability grain for UI-style subscribers; the Tasks waiter uses
    /// whole-snapshot observation to re-evaluate multi-capability descriptors.
    /// - Parameter capability: The capability to observe.
    /// - Returns: A publisher emitting `true` when the capability becomes available, `false` otherwise.
    /// - Note: Values are delivered synchronously on the writer's thread with no
    ///   lock held, so calling back into `query` APIs from a sink is safe.
    public func observeCapability(_ capability: Capability) -> AnyPublisher<Bool, Never> {
        registry.observe(capability)
    }

    /// Reactively observes capabilities changes across all plugins.
    /// Whole-snapshot grain for the Tasks waiter; UI-style subscribers prefer
    /// per-Capability observation of a single `Bool`.
    /// - Returns: A publisher emitting the full capabilities dictionary on each change.
    func observeAllCapabilities() -> AnyPublisher<[String: Set<Capability>], Never> {
        registry.observeAll()
    }

    // MARK: - Task Execution

    /// Runs a task only if the required capability is currently available.
    /// Immediate fire without waiting; for queued work use scheduleTask.
    /// `runTaskWhenAvailable` is the waiting counterpart and shares the one
    /// Tasks waiter with `scheduleTaskAndWait`.
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
    /// Immediate-style entry to the one shared Tasks waiter; delegates to
    /// `scheduleTaskAndWait`, so immediate and queued styles behave identically.
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

    // MARK: - Task Scheduling (facade over StoreSchedulingGenerations)

    private var scheduler: TaskScheduler {
        scheduling.current(owner: self)
    }

    internal func enableDeterministicTime() {
        precondition(self !== DynamicStore.shared, "deterministic time only on fresh instances")
        scheduling.enableDeterministicTime()
    }

    internal func advanceTime(by delta: TimeInterval) async {
        precondition(self !== DynamicStore.shared, "deterministic time only on fresh instances")
        await scheduling.advanceTime(by: delta)
    }

    internal func waitForDeterministicWaiters(count expected: Int) async {
        precondition(self !== DynamicStore.shared, "deterministic time only on fresh instances")
        await scheduling.waitForWaiters(count: expected)
    }

    internal var deterministicWaiterCount: Int {
        scheduling.waiterCount
    }

    internal var generationCount: Int {
        scheduling.generationCount
    }

    /// Reconfigures the scheduler without orphaning in-flight work: the live
    /// generations keep draining naturally, new work enters a fresh generation,
    /// and pending/active counts aggregate across live generations until the
    /// drained ones release.
    public func configureScheduler(_ configuration: TaskScheduler.Configuration) {
        scheduling.reconfigure(configuration, owner: self)
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
    /// Queued-style entry to the one shared Tasks waiter; `runTaskWhenAvailable`
    /// delegates here, so both styles behave identically.
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

/// State storage behind the Store seam.
/// Writers get-or-create on update; observation alone never creates; removal
/// completes detached subscribers and the next update creates a fresh subject.
/// Empty plugin identifiers are rejected here: writes and removals are no-ops,
/// reads return nil, observations return an immediately-completed publisher.
final class StoreState: @unchecked Sendable {
    private let lock = NSLock()
    private var subjects: [String: CurrentValueSubject<Any?, Never>] = [:]
    private var creationSequence: UInt64 = 0
    private let creationClock = CurrentValueSubject<UInt64, Never>(0)

    private func validate(pluginId: String) -> Bool {
        guard !pluginId.isEmpty else {
            #if DEBUG
            print("[DynamicStore] Error: Plugin ID cannot be empty")
            #endif
            return false
        }
        return true
    }

    func update<T>(pluginId: String, newState: T) {
        guard validate(pluginId: pluginId) else { return }
        let (subject, sequence): (CurrentValueSubject<Any?, Never>, UInt64?) = lock.withLock {
            if let existing = subjects[pluginId] {
                return (existing, nil)
            }
            let created = CurrentValueSubject<Any?, Never>(nil)
            subjects[pluginId] = created
            creationSequence &+= 1
            return (created, creationSequence)
        }
        if let sequence {
            creationClock.send(sequence)
        }
        subject.send(newState)
    }

    func get<T>(pluginId: String, type: T.Type) -> T? {
        guard validate(pluginId: pluginId) else { return nil }
        return lock.withLock {
            guard let subject = subjects[pluginId] else {
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

    func remove(pluginId: String) {
        guard validate(pluginId: pluginId) else { return }
        let subject: CurrentValueSubject<Any?, Never>? = lock.withLock {
            subjects.removeValue(forKey: pluginId)
        }
        subject?.send(completion: .finished)
    }

    func observe<T>(pluginId: String, type: T.Type) -> AnyPublisher<T, Never> {
        guard validate(pluginId: pluginId) else {
            return Empty(completeImmediately: true).eraseToAnyPublisher()
        }
        return Deferred { [weak self] () -> AnyPublisher<T, Never> in
            guard let self else {
                return Empty(completeImmediately: true).eraseToAnyPublisher()
            }
            let (subject, sequence): (CurrentValueSubject<Any?, Never>?, UInt64) = self.lock.withLock {
                (self.subjects[pluginId], self.creationSequence)
            }
            if let subject {
                return subject
                    .compactMap { $0 as? T }
                    .eraseToAnyPublisher()
            }
            return self.creationClock
                .filter { $0 > sequence }
                .map { [weak self] _ -> CurrentValueSubject<Any?, Never>? in
                    guard let self else { return nil }
                    return self.lock.withLock { self.subjects[pluginId] }
                }
                .compactMap { $0 }
                .first()
                .map { $0.compactMap { $0 as? T }.eraseToAnyPublisher() }
                .switchToLatest()
                .eraseToAnyPublisher()
        }
        .eraseToAnyPublisher()
    }
}

final class StoreSchedulingGenerations: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [TaskScheduler] = []
    private var configuration: TaskScheduler.Configuration
    private var virtualClock: StoreVirtualClock?
    private var storedExpiryClock: TaskScheduler.ExpiryClock = .live

    init(configuration: TaskScheduler.Configuration) {
        self.configuration = configuration
    }

    func current(owner: DynamicStore) -> TaskScheduler {
        lock.withLock {
            if let current = generations.last { return current }
            let new = TaskScheduler(store: owner, configuration: configuration, clock: storedExpiryClock)
            generations.append(new)
            return new
        }
    }

    func reconfigure(_ newConfiguration: TaskScheduler.Configuration, owner: DynamicStore) {
        lock.withLock {
            configuration = newConfiguration
            let new = TaskScheduler(store: owner, configuration: configuration, clock: storedExpiryClock)
            generations.append(new)
        }
        pruneDrainedGenerations()
    }

    func cancel(taskId: String) {
        let snapshot = lock.withLock { generations }
        for generation in snapshot {
            generation.cancel(taskId: taskId)
        }
    }

    var pendingCount: Int {
        pruneDrainedGenerations()
        return countsWithoutPruning().pending
    }

    var activeCount: Int {
        pruneDrainedGenerations()
        return countsWithoutPruning().active
    }

    var generationCount: Int {
        lock.withLock { generations.count }
    }

    var waiterCount: Int {
        lock.withLock { virtualClock?.waiterCount ?? 0 }
    }

    func enableDeterministicTime() {
        lock.withLock {
            precondition(virtualClock == nil, "deterministic time already enabled")
            precondition(generations.isEmpty, "enableDeterministicTime must precede first schedule")
            let virtual = StoreVirtualClock()
            virtualClock = virtual
            storedExpiryClock = TaskScheduler.ExpiryClock(sleep: { timeout in
                await virtual.sleep(timeout)
            })
        }
    }

    func advanceTime(by delta: TimeInterval) async {
        let clock: StoreVirtualClock = lock.withLock {
            guard let virtual = virtualClock else {
                preconditionFailure("deterministic time not enabled; call enableDeterministicTime() first")
            }
            return virtual
        }
        await clock.waitForWaiters(count: 1)
        clock.advance(by: delta)
        await Task.yield()
        await Task.yield()
    }

    func waitForWaiters(count expected: Int) async {
        let clock: StoreVirtualClock = lock.withLock {
            guard let virtual = virtualClock else {
                preconditionFailure("deterministic time not enabled")
            }
            return virtual
        }
        await clock.waitForWaiters(count: expected)
    }

    private func countsWithoutPruning() -> (pending: Int, active: Int) {
        let snapshot = lock.withLock { generations }
        var pending = 0
        var active = 0
        for generation in snapshot {
            pending += generation.pendingCount
            active += generation.activeCount
        }
        return (pending, active)
    }

    private func pruneDrainedGenerations() {
        let snapshot = lock.withLock { generations }
        guard snapshot.count > 1 else { return }
        var drainedIDs = Set<ObjectIdentifier>()
        for generation in snapshot.dropLast() {
            if generation.pendingCount == 0 && generation.activeCount == 0 {
                drainedIDs.insert(ObjectIdentifier(generation))
            }
        }
        guard !drainedIDs.isEmpty else { return }
        lock.withLock {
            guard generations.count > 1 else { return }
            let currentID = ObjectIdentifier(generations.last!)
            generations.removeAll { generation in
                let id = ObjectIdentifier(generation)
                return id != currentID && drainedIDs.contains(id)
            }
        }
    }
}
