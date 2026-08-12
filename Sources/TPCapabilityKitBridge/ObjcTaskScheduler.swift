@preconcurrency import Foundation
import TPCapabilityKit

/// Objective-C wrapper for task scheduling.
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
    @objc public func scheduleAndWait(
        _ descriptor: ObjcTaskDescriptor,
        task: @escaping @Sendable () -> NSObject,
        completion: @escaping @Sendable (NSObject?) -> Void
    ) {
        Task {
            let result: NSObject? = await store.scheduleTaskAndWait(
                descriptor.underlying
            ) {
                task() as NSObject
            }
            completion(result)
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
