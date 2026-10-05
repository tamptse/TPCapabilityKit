import Foundation
import Testing
@testable import TPCapabilityKit

@Suite("Counts agreement tuple")
struct TPCapabilityKitCountsAgreementTests {
    @Test("scheduler tuple agrees with itself; drained iff empty")
    func schedulerTupleAgrees() {
        let store = DynamicStore()
        let snap0 = store.scheduling.countsSnapshot
        #expect(snap0.pending == 0 && snap0.active == 0)
        #expect(snap0.isDrained)
        #expect(store.pendingTaskCount == 0 && store.activeTaskCount == 0)
    }

    @Test("pending task keeps tuple self-consistent")
    func pendingTupleConsistent() async {
        let store = DynamicStore()
        let missing = Capability.custom("countsAgree_\(UUID().uuidString)")
        let lease = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [missing], timeout: 30.0),
            task: {},
            completion: { _ in }
        )
        let snap = store.scheduling.countsSnapshot
        #expect(snap.pending == store.pendingTaskCount)
        #expect(snap.active == store.activeTaskCount)
        #expect(!snap.isDrained)
        #expect(snap.isDrained == (snap.pending == 0 && snap.active == 0))
        store.cancelTask(taskId: lease.task.id)
    }
}
