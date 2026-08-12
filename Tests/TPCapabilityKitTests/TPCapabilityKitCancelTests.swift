import Testing
import Combine
@testable import TPCapabilityKit

@Suite("Cancel Task Tests")
struct CancelTests {
    @Test("cancel sends only one expired event")
    func cancelSendsOneEvent() async {
        let store = DynamicStore()
        let scheduler = TaskScheduler(store: store)
        var eventCount = 0
        
        let cancellable = scheduler.events.sink { event in
            if case .taskExpired = event {
                eventCount += 1
            }
        }
        
        let descriptor = TaskDescriptor(requiredCapabilities: [])
        let lease = scheduler.schedule(descriptor, taskExecution: {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        })
        
        // Wait for task to potentially start
        try? await Task.sleep(nanoseconds: 10_000_000)
        
        scheduler.cancel(taskId: lease.task.id)
        
        // Wait for any async processing
        try? await Task.sleep(nanoseconds: 50_000_000)
        
        #expect(eventCount == 1)
        cancellable.cancel()
    }
}
