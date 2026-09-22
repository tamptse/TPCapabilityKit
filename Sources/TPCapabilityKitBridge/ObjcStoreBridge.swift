import Combine
@preconcurrency import Foundation
import TPCapabilityKit

/// Objective-C singleton bridge exposing `DynamicStore` functionality to Objective-C modules.
@objc(TPStoreBridge)
public final class ObjcStoreBridge: NSObject, @unchecked Sendable {
    /// Shared singleton instance.
    @objc public static let shared = ObjcStoreBridge()

    private let store: DynamicStore

    internal init(store: DynamicStore = .shared) {
        self.store = store
        super.init()
    }

    // MARK: - State APIs

    /// Registers an Objective-C plugin into the store via an internal adapter.
    /// - Parameter plugin: Objective-C plugin conforming to `ObjcAppPlugin`.
    @objc public func register(plugin: ObjcAppPlugin) {
        #if DEBUG
        print("[ObjcStoreBridge] Registered ObjC plugin '\(plugin.id)' as consumer-only; it provides no capabilities.")
        #endif
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

    /// Single availability predicate for immediate-run; wait-then-run delegates
    /// to the store waiter built on the same query, so both agree.
    private func isAvailable(_ capability: Capability) -> Bool {
        store.queryCapability(capability)
    }

    /// Runs a task immediately if the required capability is available.
    /// Mirrors `DynamicStore.runTask(requiring:)` semantics synchronously:
    /// query the capability, run the closure inline, otherwise return nil.
    /// True async delegation is impossible here — `@objc` cannot await the
    /// store's async `runTask`, and blocking the calling thread on a semaphore
    /// would risk deadlock. For wait-then-run use `runTaskWhenAvailable`.
    /// - Parameters:
    ///   - capability: Capability string identifier required to run the task.
    ///   - task: The task closure to execute. Must return an NSObject.
    /// - Returns: The task result, or nil if capability is not available.
    @objc public func runTask(
        capability: String,
        task: () -> NSObject
    ) -> NSObject? {
        guard isAvailable(ObjcMapper.capability(from: capability)) else { return nil }
        return task()
    }

    /// Runs a task when the required capability becomes available, with a timeout.
    /// Delivers the result on the specified queue.
    /// Availability matches `runTask` — same query behind both, so sync and async agree.
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
            let result: NSObject? = await store.runTaskWhenAvailable(capability: cap, timeout: timeout) {
                taskBox.value()
            }
            targetQueue.async {
                completionBox.value(result)
            }
        }
    }

    // MARK: - Task Scheduling APIs

    /// Scheduling adapter for Objective-C callers. A fresh stateless live view
    /// on every access — all reads delegate to the store, so there is no cache
    /// to go stale. The translation between ObjC and Swift task types lives in
    /// `ObjcTaskScheduler`, so there is exactly one scheduling path behind
    /// the Bridge.
    @objc public var taskScheduler: ObjcTaskScheduler {
        ObjcTaskScheduler(store: store)
    }

}
