import Testing
import Foundation
import Combine
@testable import TPCapabilityKit

struct TaskSchedulerProtocolTests {
    @Test func taskSchedulerConformsToProtocol() {
        let store = DynamicStore()
        let scheduler = TaskScheduler(store: store)
        
        // Verify TaskScheduler conforms to TaskSchedulerProtocol
        let protocolRef: any TaskSchedulerProtocol = scheduler
        #expect(protocolRef.pendingCount == 0)
    }

    @Test func dynamicStoreReturnsProtocol() {
        let store = DynamicStore()
        let scheduler: any TaskSchedulerProtocol = store.scheduler
        
        #expect(scheduler.pendingCount == 0)
    }

    @Test func customSchedulerImplementation() async {
        let store = DynamicStore()
        let mockScheduler = MockTaskScheduler(store: store)
        store.scheduler = mockScheduler
        
        let descriptor = TaskDescriptor(requiredCapabilities: [.heavyTask])
        let lease = store.scheduleTask(descriptor) { }
        
        #expect(mockScheduler.wasScheduleCalled)
        #expect(mockScheduler.lastDescriptor?.id == descriptor.id)
    }

    @Test func customSchedulerScheduleAndWait() async {
        let store = DynamicStore()
        let mockScheduler = MockTaskScheduler(store: store)
        store.scheduler = mockScheduler
        
        let descriptor = TaskDescriptor(requiredCapabilities: [.heavyTask])
        let result: String? = await store.scheduleTaskAndWait(descriptor) {
            "MockResult"
        }
        
        #expect(result == "MockResult")
        #expect(mockScheduler.wasScheduleAndWaitCalled)
    }

    @Test func customSchedulerCancel() {
        let store = DynamicStore()
        let mockScheduler = MockTaskScheduler(store: store)
        store.scheduler = mockScheduler
        
        store.scheduler.cancel(taskId: "test-id")
        
        #expect(mockScheduler.wasCancelCalled)
        #expect(mockScheduler.lastCancelledTaskId == "test-id")
    }
}

// Mock scheduler for testing
private final class MockTaskScheduler: TaskSchedulerProtocol, @unchecked Sendable {
    private let store: DynamicStore
    private let eventSubject = PassthroughSubject<TaskScheduler.SchedulerEvent, Never>()
    
    var wasScheduleCalled = false
    var wasScheduleAndWaitCalled = false
    var wasCancelCalled = false
    var lastDescriptor: TaskDescriptor?
    var lastCancelledTaskId: String?
    
    init(store: DynamicStore) {
        self.store = store
    }
    
    func schedule(
        _ task: TaskDescriptor,
        taskExecution: @escaping @Sendable () async -> Void,
        completion: ((Lease) -> Void)?,
        autoProcess: Bool
    ) -> Lease {
        wasScheduleCalled = true
        lastDescriptor = task
        let lease = Lease(task: task)
        lease.activate()
        lease.complete(with: nil)
        completion?(lease)
        return lease
    }
    
    func scheduleAndWait<T: Sendable>(
        _ task: TaskDescriptor,
        taskExecution: @escaping @Sendable () async throws -> T
    ) async -> T? {
        wasScheduleAndWaitCalled = true
        lastDescriptor = task
        return try? await taskExecution()
    }
    
    func cancel(taskId: String) {
        wasCancelCalled = true
        lastCancelledTaskId = taskId
    }
    
    var pendingCount: Int { 0 }
    var activeCount: Int { 0 }
    var events: AnyPublisher<TaskScheduler.SchedulerEvent, Never> {
        eventSubject.eraseToAnyPublisher()
    }
}
