import Combine
@preconcurrency import Foundation
import TPCapabilityKit

/// Objective-C singleton bridge exposing `DynamicStore` functionality to Objective-C modules.
@objc(TPStoreBridge)
public final class ObjcStoreBridge: NSObject, @unchecked Sendable {
    /// Shared singleton instance.
    @objc public static let shared = ObjcStoreBridge()

    private let store: DynamicStore
    private let lock = NSLock()
    private var _taskScheduler: ObjcTaskScheduler?

    internal init(store: DynamicStore = .shared) {
        self.store = store
        super.init()
    }

    // MARK: - State APIs

    /// Registers an Objective-C plugin into the store via an internal adapter.
    /// - Parameter plugin: Objective-C plugin conforming to `ObjcAppPlugin`.
    @objc public func register(plugin: ObjcAppPlugin) {
        let adapter = PluginObjcAdapter(objcPlugin: plugin)
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
        let cap = Capability(rawValue: capability)
        return store.queryCapability(cap)
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
        let cap = Capability(rawValue: capability)
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
        let cap = Capability(rawValue: capability)
        guard store.queryCapability(cap) else { return nil }
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
        let cap = Capability(rawValue: capability)
        let box = ObserverBox()
        
        // Subscribe to capability, run task when available
        box.cancellable = store.observeCapability(cap)
            .receive(on: targetQueue)
            .sink { [weak self] isAvailable in
                guard isAvailable, let self = self, box.isActive else { return }
                box.deactivate()
                let result = self.runTask(capability: capability, task: task)
                completion(result)
            }
        
        // Timeout
        box.timeoutItem = DispatchWorkItem {
            guard box.isActive else { return }
            box.deactivate()
            completion(nil)
        }
        targetQueue.asyncAfter(deadline: .now() + timeout, execute: box.timeoutItem!)
    }

    // MARK: - Task Scheduling APIs

    /// Shared task scheduler instance. Cached for consistent reference.
    @objc public var taskScheduler: ObjcTaskScheduler {
        lock.lock()
        defer { lock.unlock() }
        if let existing = _taskScheduler { return existing }
        let new = ObjcTaskScheduler(scheduler: store.scheduler, store: store)
        _taskScheduler = new
        return new
    }

    /// Schedules a task for execution.
    @objc public func scheduleTask(
        _ descriptor: ObjcTaskDescriptor,
        task: @escaping @Sendable () -> Void,
        completion: ((ObjcLease) -> Void)? = nil
    ) -> ObjcLease {
        let lease = store.scheduleTask(
            descriptor.underlying,
            task: { task() },
            completion: completion.map { handler in
                { lease in handler(ObjcLease(underlying: lease)) }
            }
        )
        return ObjcLease(underlying: lease)
    }

    /// Schedules a task and waits for result via completion handler.
    @objc public func scheduleTaskAndWait(
        _ descriptor: ObjcTaskDescriptor,
        task: @escaping @Sendable () -> NSObject,
        completion: @escaping @Sendable (NSObject?) -> Void
    ) {
        Task {
            let result = await store.scheduleTaskAndWait(
                descriptor.underlying
            ) {
                task() as NSObject
            }
            completion(result)
        }
    }

    /// Cancels a pending task.
    @objc public func cancelTask(taskId: String) {
        store.scheduler.cancel(taskId: taskId)
    }

    /// Returns number of pending tasks.
    @objc public var pendingTaskCount: Int {
        store.scheduler.pendingCount
    }

    /// Returns number of active tasks.
    @objc public var activeTaskCount: Int {
        store.scheduler.activeCount
    }

}

internal final class PluginObjcAdapter: AppPlugin {
    let id: String
    private let objcPlugin: ObjcAppPlugin

    init(objcPlugin: ObjcAppPlugin) {
        self.id = objcPlugin.id
        self.objcPlugin = objcPlugin
    }

    func start(with store: DynamicStore) {
        let bridge = ObjcStoreBridge(store: store)
        objcPlugin.start(with: bridge)
    }
}

/// Holds cancellable and timeout for runTaskWhenAvailable.
private final class ObserverBox {
    var cancellable: AnyCancellable?
    var timeoutItem: DispatchWorkItem?
    private let lock = NSLock()
    private var _active = true
    
    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _active
    }
    
    func deactivate() {
        lock.lock()
        let wasActive = _active
        _active = false
        let cancellableToCancel = cancellable
        let timeoutToCancel = timeoutItem
        cancellable = nil
        timeoutItem = nil
        lock.unlock()
        
        guard wasActive else { return }
        cancellableToCancel?.cancel()
        timeoutToCancel?.cancel()
    }
}
