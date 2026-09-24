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
        let observerBox = ObjcCallbackBox(observer)
        let cancellable = store.observeState(pluginId: pluginId, type: NSObject.self)
            .eraseToAnyPublisher()
        .sink { state in
            ObjcDelivery.on(queue) {
                observerBox.value(state)
            }
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
        let cap = ObjcMapper.capability(from: capability)
        let observerBox = ObjcCallbackBox(observer)
        let cancellable = store.observeCapability(cap)
            .eraseToAnyPublisher()
            .sink { available in
                ObjcDelivery.on(queue) {
                    observerBox.value(available)
                }
            }
        return ObjcCancellable(cancellable)
    }

    // MARK: - Task Execution APIs

    /// Check-and-run entry for @objc callers (the facade two-entry table on
    /// `DynamicStore.runIfAvailable`: sync fire). Delegates to the
    /// `taskScheduler` view's sync fast-path. Stays synchronous because
    /// `@objc` cannot await; blocking the calling thread on a semaphore would
    /// risk deadlock. Bypasses Lease, slot admission, and Deadline by contract;
    /// for wait-then-run use `runTaskWhenAvailable`.
    /// - Parameters:
    ///   - capability: Capability string identifier required to run the task.
    ///   - task: The task closure to execute. Must return an NSObject.
    /// - Returns: The task result, or nil if capability is not available.
    @objc public func runTask(
        capability: String,
        task: () -> NSObject
    ) -> NSObject? {
        taskScheduler.runIfAvailable(capability: capability, task: task)
    }

    /// Schedule-and-wait entry for @objc callers (the facade two-entry table:
    /// async, the one waiter). Delegates to the
    /// `taskScheduler` view, which owns descriptor building, timeout compat,
    /// queue hopping, and defaults with one delivery story. Delivers the
    /// result on the specified queue, or the main queue when omitted.
    /// Timeout compat follows the single mapper-owned fork (see `ObjcTimeout.resolve`).
    /// - Parameters:
    ///   - capability: Capability string identifier required to run the task.
    ///   - timeout: Maximum seconds to wait for the capability. Negative means
    ///     unspecified, so the scheduler Configuration default applies.
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
        taskScheduler.runWhenAvailable(
            capability: capability,
            timeout: timeout,
            queue: queue,
            task: task,
            completion: completion
        )
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
