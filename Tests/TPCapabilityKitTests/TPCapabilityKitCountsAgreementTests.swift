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

    @Test("scalars project from tuple across drain lifecycle")
    func scalarsProjectFromTupleAcrossLifecycle() {
        let store = DynamicStore()
        let snap0 = store.scheduling.countsSnapshot
        #expect(snap0.pending == store.pendingTaskCount)
        #expect(snap0.active == store.activeTaskCount)
        #expect(snap0.isDrained == (snap0.pending == 0 && snap0.active == 0))

        let missing = Capability.custom("countsLifecycle_\(UUID().uuidString)")
        let lease = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [missing], timeout: 30.0),
            task: {},
            completion: { _ in }
        )
        let snap1 = store.scheduling.countsSnapshot
        #expect(snap1.pending == store.pendingTaskCount)
        #expect(snap1.active == store.activeTaskCount)
        #expect(snap1.isDrained == (snap1.pending == 0 && snap1.active == 0))

        store.cancelTask(taskId: lease.task.id)
        let snap2 = store.scheduling.countsSnapshot
        #expect(snap2.pending == 0 && snap2.active == 0)
        #expect(snap2.pending == store.pendingTaskCount)
        #expect(snap2.active == store.activeTaskCount)
        #expect(snap2.isDrained)
        #expect(snap2.isDrained == (snap2.pending == 0 && snap2.active == 0))
    }

    @Test("reconfigure keeps tuple sum agreeing")
    func reconfigureKeepsTupleSumAgreeing() {
        let store = DynamicStore()
        let firstMissing = Capability.custom("countsReconf1_\(UUID().uuidString)")
        let secondMissing = Capability.custom("countsReconf2_\(UUID().uuidString)")
        let first = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [firstMissing], timeout: 30.0),
            task: {},
            completion: { _ in }
        )
        let snap1 = store.scheduling.countsSnapshot
        #expect(snap1.pending == 1 && snap1.active == 0)
        #expect(snap1.isDrained == (snap1.pending == 0 && snap1.active == 0))

        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 20))
        let snapAfterReconf = store.scheduling.countsSnapshot
        #expect(snapAfterReconf.pending == 1 && snapAfterReconf.active == 0)
        #expect(snapAfterReconf.pending == store.pendingTaskCount)
        #expect(snapAfterReconf.active == store.activeTaskCount)
        #expect(snapAfterReconf.isDrained == (snapAfterReconf.pending == 0 && snapAfterReconf.active == 0))

        let second = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [secondMissing], timeout: 30.0),
            task: {},
            completion: { _ in }
        )
        let snap2 = store.scheduling.countsSnapshot
        #expect(snap2.pending == 2 && snap2.active == 0)
        #expect(!snap2.isDrained)
        #expect(snap2.pending == store.pendingTaskCount)
        #expect(snap2.active == store.activeTaskCount)
        #expect(snap2.pending + snap2.active == 2)
        #expect(store.pendingTaskCount + store.activeTaskCount == 2)
        #expect(snap2.isDrained == (snap2.pending == 0 && snap2.active == 0))

        store.cancelTask(taskId: first.task.id)
        store.cancelTask(taskId: second.task.id)
        let snap3 = store.scheduling.countsSnapshot
        #expect(snap3.pending == 0 && snap3.active == 0)
        #expect(snap3.isDrained)
        #expect(snap3.pending == store.pendingTaskCount)
        #expect(snap3.active == store.activeTaskCount)
    }
}
