@preconcurrency import Foundation
import TPCapabilityKit

/// Objective-C wrapper for TaskSchedulerProtocol.
@objc(TPTaskScheduler)
public final class ObjcTaskScheduler: NSObject, @unchecked Sendable {
    private let scheduler: any TaskSchedulerProtocol
    private let store: DynamicStore

    internal init(scheduler: any TaskSchedulerProtocol, store: DynamicStore) {
        self.scheduler = scheduler
        self.store = store
        super.init()
    }

    /// Schedules a task for execution.
    @objc public func schedule(
        _ descriptor: ObjcTaskDescriptor,
        task: @escaping @Sendable () -> Void,
        completion: ((ObjcLease) -> Void)? = nil
    ) -> ObjcLease {
        let lease = scheduler.schedule(
            descriptor.underlying,
            taskExecution: { task() },
            completion: completion.map { handler in
                { lease in handler(ObjcLease(underlying: lease)) }
            },
            autoProcess: true
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
            let result: NSObject? = await scheduler.scheduleAndWait(
                descriptor.underlying
            ) {
                task() as NSObject
            }
            completion(result)
        }
    }

    /// Cancels a pending task.
    @objc public func cancel(taskId: String) {
        scheduler.cancel(taskId: taskId)
    }

    /// Number of pending tasks.
    @objc public var pendingCount: Int { scheduler.pendingCount }

    /// Number of active tasks.
    @objc public var activeCount: Int { scheduler.activeCount }
}
