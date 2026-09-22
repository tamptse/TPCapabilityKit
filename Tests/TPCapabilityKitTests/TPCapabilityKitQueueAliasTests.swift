import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Queue Alias Tests")
struct QueueAliasTests {
    @Test("parked task stays in pendingCount")
    func parkedStaysInPendingCount() async {
        let store = DynamicStore()
        let scheduler = TaskScheduler(store: store)
        let task = TaskDescriptor(
            requiredCapabilities: [.custom("ParkCount_\(UUID().uuidString)")],
            timeout: 5.0
        )
        scheduler.schedule(task, taskExecution: {})
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(scheduler.pendingCount == 1)
        #expect(scheduler.activeCount == 0)
        scheduler.cancel(taskId: task.id)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }
}
