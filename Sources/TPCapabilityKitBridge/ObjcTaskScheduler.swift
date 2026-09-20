@preconcurrency import Foundation
import TPCapabilityKit

/// Objective-C wrapper for task scheduling.
///
/// The single scheduling adapter behind the Bridge: a stateless live view over
/// `DynamicStore` translating ObjC task types to the Swift Tasks Interface
/// (`schedule/cancel/pending/active`). Holds no queue or count state — every
/// call delegates to the store, so reads are always live.
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
    /// Delivers the result on the specified queue.
    @objc public func scheduleAndWait(
        _ descriptor: ObjcTaskDescriptor,
        queue: DispatchQueue? = nil,
        task: @escaping @Sendable () -> NSObject,
        completion: @escaping @Sendable (NSObject?) -> Void
    ) {
        let targetQueue = queue ?? .main
        Task {
            let result: NSObject? = await store.scheduleTaskAndWait(
                descriptor.underlying
            ) {
                task() as NSObject
            }
            targetQueue.async {
                completion(result)
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
