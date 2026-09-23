import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Queue Alias Tests")
struct QueueAliasTests {
    @Test("parked task stays in pendingCount")
    func parkedStaysInPendingCount() async {
        let store = DynamicStore()
        store.enableDeterministicTime()
        let task = TaskDescriptor(
            requiredCapabilities: [.custom("ParkCount_\(UUID().uuidString)")],
            timeout: 5.0
        )
        let done = AsyncStream<Void>.makeStream()
        let lease = store.scheduleTask(task, task: {}, completion: { _ in
            done.continuation.yield()
        })
        #expect(store.pendingTaskCount == 1)
        #expect(store.activeTaskCount == 0)
        store.cancelTask(taskId: task.id)
        for await _ in done.stream { break }
        #expect(lease.state == .expired)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
