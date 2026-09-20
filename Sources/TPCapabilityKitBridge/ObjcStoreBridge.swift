import Combine
@preconcurrency import Foundation
import TPCapabilityKit

/// Single mapping point between Objective-C primitives and Swift domain types.
enum ObjcMapper {
    static func capability(from string: String) -> Capability {
        Capability(rawValue: string)
    }

    static func taskPriority(from rawValue: Int) -> TaskPriority {
        TaskPriority(rawValue: rawValue) ?? .normal
    }
}

/// Objective-C singleton bridge exposing `DynamicStore` functionality to Objective-C modules.
@objc(TPStoreBridge)
public final class ObjcStoreBridge: NSObject, @unchecked Sendable {
    /// Shared singleton instance.
    @objc public static let shared = ObjcStoreBridge()

    private let store: DynamicStore
    private let lock = NSLock()
    private var _cachedScheduler: ObjcTaskScheduler?

    internal init(store: DynamicStore = .shared) {
        self.store = store
        super.init()
    }

    // MARK: - State APIs

    /// Registers an Objective-C plugin into the store via an internal adapter.
    /// - Parameter plugin: Objective-C plugin conforming to `ObjcAppPlugin`.
    @objc public func register(plugin: ObjcAppPlugin) {
        let adapter = PluginObjcAdapter(objcPlugin: plugin, bridge: self)
        store.register(plugin: adapter)
    }

    /// Updates state for a specified plugin.
    /// - Parameters:
    ///   - pluginId: Unique identifier of the plugin.
    ///   - newState: `NSObject` state value to update.
    @objc public func updateState(pluginId: String, newState: NSObject) {
        store.updateState(pluginId: pluginId, newState: newState)
    }

    /// Synchronously retrieves state for a specified plugin.
    /// - Parameter pluginId: Unique identifier of the plugin.
    /// - Returns: `NSObject` state or `nil`.
    @objc public func getState(pluginId: String) -> NSObject? {
        return store.getState(pluginId: pluginId, type: NSObject.self)
    }

    /// Subscribes to state updates for a plugin, delivering callbacks on the specified queue.
    /// - Parameters:
    ///   - pluginId: Unique identifier of the plugin.
    ///   - queue: Queue for callback delivery. Pass `nil` for main queue.
    ///   - observer: Closure invoked with updated state on specified queue.
    /// - Returns: An `ObjcCancellable` token to manage subscription lifecycle.
    @objc public func subscribe(
        pluginId: String,
        queue: DispatchQueue? = nil,
        observer: @escaping (NSObject?) -> Void
    ) -> ObjcCancellable {
        let targetQueue = queue ?? .main
        let cancellable = store.observeState(pluginId: pluginId, type: NSObject.self)
            .receive(on: targetQueue)
            .sink { state in
                observer(state)
            }
        return ObjcCancellable(cancellable)
    }

    // MARK: - Capability APIs

    /// Queries whether any registered plugin provides the specified capability.
    /// - Parameter capability: Capability string identifier.
    /// - Returns: `true` if at least one plugin provides the capability.
    @objc public func queryCapability(_ capability: String) -> Bool {
        store.queryCapability(ObjcMapper.capability(from: capability))
    }

    /// Subscribes to capability availability updates, delivering callbacks on the specified queue.
    /// - Parameters:
    ///   - capability: Capability string identifier to observe.
    ///   - queue: Queue for callback delivery. Pass `nil` for main queue.
    ///   - observer: Closure invoked with capability availability on specified queue.
    /// - Returns: An `ObjcCancellable` token to manage subscription lifecycle.
    @objc public func subscribeCapability(
        _ capability: String,
        queue: DispatchQueue? = nil,
        observer: @escaping (Bool) -> Void
    ) -> ObjcCancellable {
        let targetQueue = queue ?? .main
        let cap = ObjcMapper.capability(from: capability)
        let cancellable = store.observeCapability(cap)
            .receive(on: targetQueue)
            .sink { observer($0) }
        return ObjcCancellable(cancellable)
    }

    // MARK: - Task Execution APIs

    /// Runs a task immediately if the required capability is available.
    /// - Parameters:
    ///   - capability: Capability string identifier required to run the task.
    ///   - task: The task closure to execute. Must return an NSObject.
    /// - Returns: The task result, or nil if capability is not available.
    @objc public func runTask(
        capability: String,
        task: () -> NSObject
    ) -> NSObject? {
        guard store.queryCapability(ObjcMapper.capability(from: capability)) else { return nil }
        return task()
    }

    /// Runs a task when the required capability becomes available, with a timeout.
    /// Delivers the result on the specified queue.
    /// - Parameters:
    ///   - capability: Capability string identifier required to run the task.
    ///   - timeout: Maximum seconds to wait for the capability.
    ///   - queue: Queue for callback delivery. Pass `nil` for main queue.
    ///   - task: The task closure to execute. Must return an NSObject.
    ///   - completion: Called on specified queue with the result, or nil if timeout.
    @objc public func runTaskWhenAvailable(
        capability: String,
        timeout: TimeInterval,
        queue: DispatchQueue? = nil,
        task: @escaping () -> NSObject,
        completion: @escaping (NSObject?) -> Void
    ) {
        let targetQueue = queue ?? .main
        let cap = ObjcMapper.capability(from: capability)
        let taskBox = ObjcCallbackBox(task)
        let completionBox = ObjcCallbackBox(completion)
        Task {
            let result: NSObject? = try? await store.runTaskWhenAvailable(capability: cap, timeout: timeout) {
                taskBox.value()
            }
            targetQueue.async {
                completionBox.value(result)
            }
        }
    }

    // MARK: - Task Scheduling APIs

    /// Shared task scheduler instance. Cached for a stable wrapper; counts read live from the store.
    @objc public var taskScheduler: ObjcTaskScheduler {
        lock.withLock {
            if let cached = _cachedScheduler { return cached }
            let scheduler = ObjcTaskScheduler(store: store)
            _cachedScheduler = scheduler
            return scheduler
        }
    }

    /// Schedules a task for execution.
    @objc public func scheduleTask(
        _ descriptor: ObjcTaskDescriptor,
        task: @escaping @Sendable () -> Void,
        completion: (@Sendable (ObjcLease) -> Void)? = nil
    ) -> ObjcLease {
        taskScheduler.schedule(descriptor, task: task, completion: completion)
    }

    /// Schedules a task and waits for result via completion handler.
    @objc public func scheduleTaskAndWait(
        _ descriptor: ObjcTaskDescriptor,
        task: @escaping @Sendable () -> NSObject,
        completion: @escaping @Sendable (NSObject?) -> Void
    ) {
        taskScheduler.scheduleAndWait(descriptor, task: task, completion: completion)
    }

    /// Cancels a pending task.
    @objc public func cancelTask(taskId: String) {
        taskScheduler.cancel(taskId: taskId)
    }

    /// Returns number of pending tasks.
    @objc public var pendingTaskCount: Int {
        taskScheduler.pendingCount
    }

    /// Returns number of active tasks.
    @objc public var activeTaskCount: Int {
        taskScheduler.activeCount
    }

}

/// @unchecked Sendable box for passing non-Sendable ObjC closures into Tasks.
private final class ObjcCallbackBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

internal final class PluginObjcAdapter: AppPlugin {
    let id: String
    private let objcPlugin: ObjcAppPlugin
    private let bridge: ObjcStoreBridge

    init(objcPlugin: ObjcAppPlugin, bridge: ObjcStoreBridge) {
        self.id = objcPlugin.id
        self.objcPlugin = objcPlugin
        self.bridge = bridge
    }

    func start(with store: DynamicStore) {
        objcPlugin.start(with: bridge)
    }
}
