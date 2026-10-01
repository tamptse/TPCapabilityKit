import Combine
@preconcurrency import Foundation
import TPCapabilityKit

/// Objective-C singleton bridge exposing `DynamicStore` functionality to Objective-C modules.
/// ObjC grain: only NSObject crosses; wrong-typed reads as absent; removals complete; never emits nil.
@objc(TPStoreBridge)
public final class ObjcStoreBridge: NSObject, @unchecked Sendable {
    @objc public static let shared = ObjcStoreBridge()

    private let store: DynamicStore

    internal init(store: DynamicStore = .shared) {
        self.store = store
        super.init()
    }

#if DEBUG
    private func warnIfNonNSObjectGrain(pluginId: String, raw: Any?) {
        if let raw, !(raw is NSObject) {
            print("[ObjcStoreBridge] Warning: non-NSObject state for plugin '\(pluginId)' reads as absent on ObjC path.")
        }
    }
#endif

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
    /// ObjC grain: wrong-typed reads as absent.
    /// - Parameter pluginId: Unique identifier of the plugin.
    /// - Returns: `NSObject` state or `nil`.
    @objc public func getState(pluginId: String) -> NSObject? {
        #if DEBUG
        warnIfNonNSObjectGrain(pluginId: pluginId, raw: store.getState(pluginId: pluginId, type: Any.self))
        #endif
        return store.getState(pluginId: pluginId, type: NSObject.self)
    }

    /// Subscribes to state updates for a plugin.
    /// ObjC grain: wrong-typed reads as absent; removals complete; never emits nil.
    /// Delivery via `ObjcBridgeDoor`.
    /// - Parameters:
    ///   - pluginId: Unique identifier of the plugin.
    ///   - queue: Delivery queue (see `ObjcBridgeDoor`).
    ///   - observer: Closure invoked via `ObjcBridgeDoor` with updated state.
    /// - Returns: An `ObjcCancellable` token to manage subscription lifecycle.
    @objc public func subscribe(
        pluginId: String,
        queue: DispatchQueue? = nil,
        observer: @escaping (NSObject?) -> Void
    ) -> ObjcCancellable {
        #if DEBUG
        warnIfNonNSObjectGrain(pluginId: pluginId, raw: store.getState(pluginId: pluginId, type: Any.self))
        #endif
        return ObjcBridgeDoor.subscribeState(store: store, pluginId: pluginId, queue: queue, observer: observer)
    }

    // MARK: - Plugin Detach

    // Death half of the State-API birth half above: detach entries are keyed
    // by Plugin id string like the read/write/subscribe entries and delegate
    // straight to the Store detach entries with no guard of their own, so the
    // observable empty-id no-op stays identical to doing nothing.

    /// Removes the state for a plugin identifier.
    /// - Parameter pluginId: Unique identifier of the plugin.
    @objc public func removeState(pluginId: String) {
        store.removeState(for: pluginId)
    }

    /// Unregisters a plugin by its identifier: state cleared with detached
    /// subscribers completed plus capability-row detach.
    /// ObjC plugins are capability-consumers only — no Capabilities parameter
    /// here — so detach can never provision.
    /// - Parameter pluginId: Unique identifier of the plugin.
    @objc public func unregister(pluginId: String) {
        store.unregister(pluginId: pluginId)
    }

    // MARK: - Capability APIs

    /// Queries whether any registered plugin provides the specified capability.
    /// - Parameter capability: Capability string identifier.
    /// - Returns: `true` if at least one plugin provides the capability.
    @objc public func queryCapability(_ capability: String) -> Bool {
        store.queryCapability(ObjcMapper.capability(from: capability))
    }

    /// Subscribes to capability availability updates.
    /// Delivery via `ObjcBridgeDoor`.
    /// - Parameters:
    ///   - capability: Capability string identifier to observe.
    ///   - queue: Delivery queue (see `ObjcBridgeDoor`).
    ///   - observer: Closure invoked via `ObjcBridgeDoor` with capability availability.
    /// - Returns: An `ObjcCancellable` token to manage subscription lifecycle.
    @objc public func subscribeCapability(
        _ capability: String,
        queue: DispatchQueue? = nil,
        observer: @escaping (Bool) -> Void
    ) -> ObjcCancellable {
        let cap = ObjcMapper.capability(from: capability)
        return ObjcBridgeDoor.subscribeCapability(store: store, capability: cap, queue: queue, observer: observer)
    }

    // MARK: - Task Execution APIs

    /// Deprecated forwarder to the single scheduling door
    /// (`taskScheduler.runIfAvailable`). Holds no scheduling policy of its own:
    /// sync-vs-wait agreement is stated once on `DynamicStore.fire`.
    /// - Parameters:
    ///   - capability: Capability string identifier required to run the task.
    ///   - task: The task closure to execute. Must return an NSObject.
    /// - Returns: The task result, or nil if capability is not available.
    @available(*, deprecated, message: "Use taskScheduler.runIfAvailable — the taskScheduler live view is the single scheduling door.")
    @objc public func runTask(
        capability: String,
        task: () -> NSObject
    ) -> NSObject? {
        taskScheduler.runIfAvailable(capability: capability, task: task)
    }

    /// Deprecated forwarder to the single scheduling door
    /// (`taskScheduler.runWhenAvailable`). Holds no scheduling policy of its
    /// own (see the one contract on `DynamicStore.fire`).
    /// Delivery via `ObjcBridgeDoor`.
    /// - Parameters:
    ///   - capability: Capability string identifier required to run the task.
    ///   - timeout: Maximum seconds to wait for the capability. Negative means
    ///     unspecified, so the scheduler Configuration default applies.
    ///   - queue: Delivery queue (see `ObjcBridgeDoor`).
    ///   - task: The task closure to execute. Must return an NSObject.
    ///   - completion: Called via `ObjcBridgeDoor` with the result, or nil if timeout.
    @available(*, deprecated, message: "Use taskScheduler.runWhenAvailable — the taskScheduler live view is the single scheduling door.")
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
