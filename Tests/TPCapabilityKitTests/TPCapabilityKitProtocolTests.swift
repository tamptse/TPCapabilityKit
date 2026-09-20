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
    private let lock = NSLock()
    
    private var _wasScheduleCalled = false
    private var _wasScheduleAndWaitCalled = false
    private var _wasCancelCalled = false
    private var _lastDescriptor: TaskDescriptor?
    private var _lastCancelledTaskId: String?
    
    var wasScheduleCalled: Bool { lock.withLock { _wasScheduleCalled } }
    var wasScheduleAndWaitCalled: Bool { lock.withLock { _wasScheduleAndWaitCalled } }
    var wasCancelCalled: Bool { lock.withLock { _wasCancelCalled } }
    var lastDescriptor: TaskDescriptor? { lock.withLock { _lastDescriptor } }
    var lastCancelledTaskId: String? { lock.withLock { _lastCancelledTaskId } }
    
    init(store: DynamicStore) {
        self.store = store
    }
    
    func schedule(
        _ task: TaskDescriptor,
        taskExecution: @escaping @Sendable () async -> Void,
        completion: ((Lease) -> Void)? = nil
    ) -> Lease {
        lock.withLock {
            _wasScheduleCalled = true
            _lastDescriptor = task
        }
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
        lock.withLock {
            _wasScheduleAndWaitCalled = true
            _lastDescriptor = task
        }
        return try? await taskExecution()
    }
    
    func cancel(taskId: String) {
        lock.withLock {
            _wasCancelCalled = true
            _lastCancelledTaskId = taskId
        }
    }
    
    var pendingCount: Int { 0 }
    var activeCount: Int { 0 }
}
