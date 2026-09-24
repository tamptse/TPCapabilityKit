@preconcurrency import Foundation
import TPCapabilityKit

/// Objective-C wrapper for task scheduling.
///
/// The single scheduling door behind the Bridge: a stateless live view over
/// `DynamicStore` translating ObjC task types to the Swift Tasks Interface
/// (`schedule/cancel/pending/active`). Holds no queue or count state — every
/// call delegates to the store, so reads are always live.
///
/// One delivery story: `schedule` completion fires on the Tasks execution
/// context with no hop, while every value-returning wait (`scheduleAndWait`,
/// `runWhenAvailable`) delivers its completion through the single delivery
/// module (`ObjcBridgeDelivery`), which owns the given-or-main queue hop
/// alongside the Bridge subscribes. Descriptor building and timeout compat stay
/// in `ObjcMapper`; the sync fast-path (`runIfAvailable`) consults the same
/// registry state the Tasks waiter resolves, so sync and wait-then-run agree
/// by construction.
@objc(TPTaskScheduler)
public final class ObjcTaskScheduler: NSObject, @unchecked Sendable {
    private let store: DynamicStore

    internal init(store: DynamicStore) {
        self.store = store
        super.init()
    }

    /// Schedules a task for execution.
    @objc public func schedule(
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
    /// Delivers the result on the specified queue, or the main queue when omitted.
    @objc public func scheduleAndWait(
        _ descriptor: ObjcTaskDescriptor,
        queue: DispatchQueue? = nil,
        task: @escaping @Sendable () -> NSObject,
        completion: @escaping @Sendable (NSObject?) -> Void
    ) {
        waitThenRun(descriptor: descriptor.underlying, queue: queue, task: task, completion: completion)
    }

    /// Runs a task when the required capability becomes available, with a timeout.
    /// Shares the one `waitThenRun` delivery core with `scheduleAndWait`.
    /// Delivers the result on the specified queue, or the main queue when omitted.
    /// - Parameters:
    ///   - capability: Capability string identifier required to run the task.
    ///   - timeout: Maximum seconds to wait for the capability. Negative means
    ///     unspecified, so the scheduler Configuration default applies.
    ///   - queue: Queue for callback delivery. Pass `nil` for main queue.
    ///   - task: The task closure to execute. Must return an NSObject.
    ///   - completion: Called on the delivery queue with the result, or nil if timeout.
    @objc public func runWhenAvailable(
        capability: String,
        timeout: TimeInterval,
        queue: DispatchQueue? = nil,
        task: @escaping () -> NSObject,
        completion: @escaping (NSObject?) -> Void
    ) {
        let descriptor = ObjcTaskDescriptor(
            capabilities: [capability],
            priority: TaskPriority.normal.rawValue,
            timeout: timeout,
            maxRetries: 0,
            metadata: [:]
        )
        waitThenRun(descriptor: descriptor.underlying, queue: queue, task: task, completion: completion)
    }

    /// Runs a task only if the required capability is currently available.
    /// Crosses the single Store sync-check seam, so sync and wait-then-run agree
    /// by construction. Stays synchronous because `@objc` cannot await.
    /// - Parameters:
    ///   - capability: Capability string identifier required to run the task.
    ///   - task: The task closure to execute. Must return an NSObject.
    /// - Returns: The task result, or nil if capability is not available.
    @objc public func runIfAvailable(
        capability: String,
        task: () -> NSObject
    ) -> NSObject? {
        store.runIfAvailable(requiring: ObjcMapper.capability(from: capability), task: task)
    }

    /// The one delivery core for every value-returning wait behind the view.
    private func waitThenRun(
        descriptor: TaskDescriptor,
        queue: DispatchQueue?,
        task: @escaping () -> NSObject,
        completion: @escaping (NSObject?) -> Void
    ) {
        let taskBox = ObjcCallbackBox(task)
        let completionBox = ObjcCallbackBox(completion)
        Task {
            let result: NSObject? = await store.scheduleTaskAndWait(descriptor) {
                taskBox.value()
            }
            ObjcBridgeDelivery.deliver(on: queue) {
                completionBox.value(result)
            }
        }
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
