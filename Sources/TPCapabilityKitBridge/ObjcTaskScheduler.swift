@preconcurrency import Foundation
import TPCapabilityKit

/// Objective-C wrapper for task scheduling.
///
/// The single scheduling door behind the Bridge: a stateless live view over
/// `DynamicStore` translating ObjC task types to the Swift Tasks Interface
/// (`schedule/cancel/pending/active`). Holds no queue or count state — every
/// call delegates to the store, so reads are always live.
///
/// Single delivery story via `ObjcBridgeDoor` alongside the Bridge subscribes.
/// Descriptor building and timeout compat stay in `ObjcMapper`; the sync
/// fast-path (`runIfAvailable`) consults the same registry state the Tasks
/// waiter resolves, so sync and wait-then-run agree by construction.
@objc(TPTaskScheduler)
public final class ObjcTaskScheduler: NSObject, @unchecked Sendable {
    private let store: DynamicStore

    internal init(store: DynamicStore) {
        self.store = store
        super.init()
    }

    /// Schedules a task for execution.
    /// Delivery via `ObjcBridgeDoor`.
    @objc public func schedule(
        _ descriptor: ObjcTaskDescriptor,
        task: @escaping @Sendable () -> Void,
        completion: ((ObjcLease) -> Void)? = nil
    ) -> ObjcLease {
        schedule(descriptor, queue: nil, task: task, completion: completion)
    }

    /// Schedules a task for execution.
    /// Delivery via `ObjcBridgeDoor`.
    @objc(schedule:queue:task:completion:)
    public func schedule(
        _ descriptor: ObjcTaskDescriptor,
        queue: DispatchQueue?,
        task: @escaping @Sendable () -> Void,
        completion: ((ObjcLease) -> Void)? = nil
    ) -> ObjcLease {
        let completionBox = ObjcCallbackBox(completion)
        let lease = store.scheduleTask(
            descriptor.underlying,
            task: { task() },
            completion: completionBox.value == nil ? nil : { lease in
                let leaseBox = ObjcCallbackBox(lease)
                ObjcBridgeDoor.deliverScheduleCompletion(queue: queue) {
                    completionBox.value?(ObjcLease(underlying: leaseBox.value))
                }
            }
        )
        return ObjcLease(underlying: lease)
    }

    /// Schedules a task and waits for result via completion handler.
    /// Queued-wait spelling over the door core (bypass rule:
    /// see the one contract on `DynamicStore.fire`).
    /// Delivery via `ObjcBridgeDoor`.
    @objc public func scheduleAndWait(
        _ descriptor: ObjcTaskDescriptor,
        queue: DispatchQueue? = nil,
        task: @escaping @Sendable () -> NSObject,
        completion: @escaping @Sendable (NSObject?) -> Void
    ) {
        ObjcBridgeDoor.waitThenRun(
            store: store,
            descriptor: ObjcBridgeDoor.translate(descriptor),
            queue: queue,
            task: task,
            completion: completion
        )
    }

    /// Runs a task when the required capability becomes available, with a timeout.
    /// Queued-wait spelling over the door core (bypass rule:
    /// see the one contract on `DynamicStore.fire`).
    /// Delivery via `ObjcBridgeDoor`.
    /// - Parameters:
    ///   - capability: Capability string identifier required to run the task.
    ///   - timeout: Maximum seconds to wait for the capability. Negative means
    ///     unspecified, so the scheduler Configuration default applies.
    ///   - queue: Delivery queue (see `ObjcBridgeDoor`).
    ///   - task: The task closure to execute. Must return an NSObject.
    ///   - completion: Called via `ObjcBridgeDoor` with the result, or nil if timeout.
    @objc public func runWhenAvailable(
        capability: String,
        timeout: TimeInterval,
        queue: DispatchQueue? = nil,
        task: @escaping () -> NSObject,
        completion: @escaping (NSObject?) -> Void
    ) {
        let descriptor = ObjcTaskDescriptor(capabilities: [capability], timeout: timeout)
        ObjcBridgeDoor.waitThenRun(
            store: store,
            descriptor: ObjcBridgeDoor.translate(descriptor),
            queue: queue,
            task: task,
            completion: completion
        )
    }

    /// Check-and-run entry over the sync-check shape of the one contract
    /// on `DynamicStore.fire`. Stays synchronous because `@objc` cannot await.
    /// - Parameters:
    ///   - capability: Capability string identifier required to run the task.
    ///   - task: The task closure to execute. Must return an NSObject.
    /// - Returns: The task result, or nil if capability is not available.
    @objc public func runIfAvailable(
        capability: String,
        task: () -> NSObject
    ) -> NSObject? {
        store.fire(requiring: ObjcMapper.capability(from: capability), task: task)
    }

    /// Cancels a pending task.
    @objc public func cancel(taskId: String) {
        store.cancelTask(taskId: taskId)
    }

    /// Number of pending tasks.
    @objc public var pendingCount: Int { store.pendingTaskCount }

    /// Number of active tasks.
    @objc public var activeCount: Int { store.activeTaskCount }
}
