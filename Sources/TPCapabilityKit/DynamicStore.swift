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

    /// Whole-set readiness for the Tasks waiter: thin delegation to the
    /// registry interface, so park/Deadline/activate/settle stay in Tasks
    /// while set-matching lives in the registry.
    func waitForAllCapabilities(
        _ required: Set<Capability>,
        race: @Sendable @escaping (@escaping CapabilityRegistry.WaitOperation) async -> Bool
    ) async -> Bool {
        await registry.waitForAll(required, race: race)
    }

    // MARK: - Task Execution

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

    /// Choosing a fire entry (the one decision; Bridge comments point here).
    ///
    /// | When | Call |
    /// | Check-and-run: sync fire, @objc-compatible | `runIfAvailable` |
    /// | Schedule-and-wait: async, the one waiter | `scheduleTaskAndWait` (`runTaskWhenAvailable` is the single-capability convenience over it) |
    ///
    /// Immediate entries bypass Lease, slot admission, and Deadline by contract:
    /// fire-and-forget must not queue, so under slot pressure sync fire runs
    /// while a scheduled wait parks.
    public func runIfAvailable<T>(
        requiring capability: Capability,
        task: () -> T
    ) -> T? {
        guard queryCapability(capability) else { return nil }
        return task()
    }

    /// Single-capability convenience over `scheduleTaskAndWait` (the one waiter).
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
        await scheduling.waitForDeterministicWaiters(count: expected)
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

    private enum CreationRendezvous {
        case existing(CurrentValueSubject<Any?, Never>)
        case created(CurrentValueSubject<Any?, Never>, UInt64)
        case pending(AnyPublisher<CurrentValueSubject<Any?, Never>, Never>)
    }

    private func creationRendezvous(pluginId: String, createIfMissing: Bool) -> CreationRendezvous {
        enum Decision {
            case existing(CurrentValueSubject<Any?, Never>)
            case created(CurrentValueSubject<Any?, Never>, UInt64)
            case pending(UInt64)
        }
        let decision: Decision = lock.withLock {
            if let existing = subjects[pluginId] {
                return .existing(existing)
            }
            if createIfMissing {
                let created = CurrentValueSubject<Any?, Never>(nil)
                subjects[pluginId] = created
                creationSequence &+= 1
                return .created(created, creationSequence)
            }
            return .pending(creationSequence)
        }
        switch decision {
        case .existing(let subject):
            return .existing(subject)
        case .created(let subject, let notice):
            return .created(subject, notice)
        case .pending(let after):
            let awaited: AnyPublisher<CurrentValueSubject<Any?, Never>, Never> = creationClock
                .filter { $0 > after }
                .map { [weak self] _ -> CurrentValueSubject<Any?, Never>? in
                    guard let self else { return nil }
                    return self.lock.withLock { self.subjects[pluginId] }
                }
                .compactMap { $0 }
                .first()
                .eraseToAnyPublisher()
            return .pending(awaited)
        }
    }

    func update<T>(pluginId: String, newState: T) {
        guard validatePluginId(pluginId) else { return }
        switch creationRendezvous(pluginId: pluginId, createIfMissing: true) {
        case .existing(let subject):
            subject.send(newState)
        case .created(let subject, let notice):
            creationClock.send(notice)
            subject.send(newState)
        case .pending:
            assertionFailure("State creation rendezvous produced no subject for a writer")
        }
    }

    func get<T>(pluginId: String, type: T.Type) -> T? {
        guard validatePluginId(pluginId) else { return nil }
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
        guard validatePluginId(pluginId) else { return }
        let subject: CurrentValueSubject<Any?, Never>? = lock.withLock {
            subjects.removeValue(forKey: pluginId)
        }
        subject?.send(completion: .finished)
    }

    func observe<T>(pluginId: String, type: T.Type) -> AnyPublisher<T, Never> {
        guard validatePluginId(pluginId) else {
            return Empty(completeImmediately: true).eraseToAnyPublisher()
        }
        return Deferred { [weak self] () -> AnyPublisher<T, Never> in
            guard let self else {
                return Empty(completeImmediately: true).eraseToAnyPublisher()
            }
            switch self.creationRendezvous(pluginId: pluginId, createIfMissing: false) {
            case .existing(let subject), .created(let subject, _):
                return subject
                    .compactMap { $0 as? T }
                    .eraseToAnyPublisher()
            case .pending(let awaited):
                return awaited
                    .map { $0.compactMap { $0 as? T }.eraseToAnyPublisher() }
                    .switchToLatest()
                    .eraseToAnyPublisher()
            }
        }
        .eraseToAnyPublisher()
    }
}

final class StoreSchedulingGenerations: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [TaskScheduler] = []
    private var configuration: TaskScheduler.Configuration
    private let slots: ConcurrencyController
    /// One time instance shared across live generations, so reconfigure never
    /// forks virtual time. Fixed here at construction, never threaded per call.
    private let clock: Clock

    init(configuration: TaskScheduler.Configuration, clock: Clock) {
        self.configuration = configuration
        self.clock = clock
        self.slots = ConcurrencyController(maxPerCapability: configuration.maxPerCapability, maxGlobal: configuration.maxGlobal)
    }

    func current(owner: DynamicStore) -> TaskScheduler {
        lock.withLock {
            if let current = generations.last { return current }
            let new = TaskScheduler(store: owner, configuration: configuration, clock: clock, concurrencyController: slots)
            generations.append(new)
            return new
        }
    }

    func reconfigure(_ newConfiguration: TaskScheduler.Configuration, owner: DynamicStore) {
        lock.withLock {
            configuration = newConfiguration
            slots.updateLimits(maxPerCapability: newConfiguration.maxPerCapability, maxGlobal: newConfiguration.maxGlobal)
            let new = TaskScheduler(store: owner, configuration: configuration, clock: clock, concurrencyController: slots)
            generations.append(new)
        }
        prunedSnapshot()
    }

    /// Deterministic-time controls live here next to the generations they
    /// gate: precede-first-use is checked against the pruned count in exactly
    /// one place, enable-once and virtual-only inside the time module. The
    /// Store keeps thin spelling-only delegation.
    func enableDeterministicTime() {
        precondition(generationCount == 0, "enableDeterministicTime must precede first schedule")
        clock.enableDeterministic()
    }

    func advanceTime(by delta: TimeInterval) async {
        await clock.advance(by: delta)
    }

    func waitForDeterministicWaiters(count expected: Int) async {
        await clock.waitForWaiters(count: expected)
    }

    func cancel(taskId: String) {
        let snapshot = lock.withLock { generations }
        for generation in snapshot {
            generation.cancel(taskId: taskId)
        }
    }

    /// Single generations read in one prune-then-loop pass: counts SUM across
    /// live generations while slot admission SHARES the one Store-owned domain,
    /// so reconfigure never doubles the configured limit during drain.
    var snapshot: (pending: Int, active: Int, generationCount: Int) {
        let live = prunedSnapshot()
        var pending = 0
        var active = 0
        for generation in live {
            let counts = generation.countsSnapshot
            pending += counts.pending
            active += counts.active
        }
        return (pending, active, live.count)
    }

    var pendingCount: Int {
        snapshot.pending
    }

    var activeCount: Int {
        snapshot.active
    }

    var generationCount: Int {
        snapshot.generationCount
    }

    @discardableResult
    private func prunedSnapshot() -> [TaskScheduler] {
        // Store→Tasks: Store lock held while reading each non-current generation's drain state.
        lock.withLock {
            guard generations.count > 1 else { return generations }
            let currentID = ObjectIdentifier(generations.last!)
            generations.removeAll { generation in
                guard ObjectIdentifier(generation) != currentID else { return false }
                return generation.isDrained
            }
            return generations
        }
    }
}
