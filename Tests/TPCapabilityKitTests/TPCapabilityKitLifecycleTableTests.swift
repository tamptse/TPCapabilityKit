import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Lifecycle Table Single Owner Tests (path internal mechanics + Tasks seam)")
struct LifecycleTableTests {
    private func makeLease(id: String = UUID().uuidString, priority: TaskPriority = .normal) -> Lease {
        Lease(task: TaskDescriptor(id: id, requiredCapabilities: [], priority: priority))
    }

    @Test("dequeue parks exactly once, second beginPark is false")
    func doubleParkImpossible() {
        var store = TaskScheduler.LifecycleStore()
        let lease = makeLease()
        store.insert(lease: lease, execution: nil, waiters: [])

        let first = store.dequeueNext()
        #expect(first?.task.id == lease.task.id)
        #expect(store.counts.queued == 0)
        #expect(store.counts.parked == 1)
        #expect(store.counts.pending == 1)

        #expect(store.dequeueNext() == nil)

        #expect(store.beginPark(for: lease) == true)
        #expect(store.beginPark(for: lease) == false)

        _ = store.transition(for: lease, to: .terminal(.expired))
        #expect(store.counts.pending == 0)
        #expect(store.counts.queued == 0)
        #expect(store.counts.parked == 0)
    }

    @Test("terminal removal cleans order, same id reschedules through Tasks seam")
    func cancelThenRescheduleSameId() async {
        let store = DynamicStore()
        let scheduler = makeScheduler(store: store)
        let missing = Capability.custom("lifecycleTable_\(UUID().uuidString)")
        let id = "lifecycle-reuse_\(UUID().uuidString)"

        let firstDone = AsyncGate()
        let first = TaskDescriptor(id: id, requiredCapabilities: [missing], timeout: 10.0)
        let firstLease = scheduler.schedule(first, taskExecution: {}, completion: { _ in
            firstDone.signal()
        })

        #expect(scheduler.pendingCount == 1)
        #expect(scheduler.activeCount == 0)
        #expect(!firstLease.isTerminal)

        scheduler.cancel(taskId: id)
        await firstDone.wait()

        #expect(firstLease.isTerminal)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)

        let secondDone = AsyncGate()
        let second = TaskDescriptor(id: id, requiredCapabilities: [missing], timeout: 10.0)
        let secondLease = scheduler.schedule(second, taskExecution: {}, completion: { _ in
            secondDone.signal()
        })

        #expect(scheduler.pendingCount == 1)
        #expect(scheduler.activeCount == 0)
        #expect(!secondLease.isTerminal)

        scheduler.cancel(taskId: id)
        await secondDone.wait()

        #expect(secondLease.isTerminal)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("retry re-queue restores pending through Store facade")
    func retryRestoresPending() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "lifecycleRetry")
        defer { store.unregisterCapability(for: pluginId) }

        let attempts = Probe()
        struct Flaky: Error {}
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 1)
        let result = await store.scheduleTaskAndWait(task) { () async throws -> String in
            let n = await attempts.next()
            if n == 1 { throw Flaky() }
            return "recovered"
        }

        #expect(result == "recovered")
        #expect(await attempts.count == 2)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
