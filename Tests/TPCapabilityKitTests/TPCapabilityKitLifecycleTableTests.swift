import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Lifecycle Table Single Owner Tests")
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

        _ = store.takeTerminal(for: lease)
        #expect(store.counts.pending == 0)
        #expect(store.counts.queued == 0)
        #expect(store.counts.parked == 0)
    }

    @Test("terminal removal cleans order, same id reschedules through Tasks seam")
    func cancelThenRescheduleSameId() async {
        let store = DynamicStore()
        let scheduler = TaskScheduler(store: store, concurrencyController: ConcurrencyController())
        let missing = Capability.custom("lifecycleTable_\(UUID().uuidString)")
        let id = "lifecycle-reuse_\(UUID().uuidString)"

        let firstDone = AsyncStream<Void>.makeStream()
        let first = TaskDescriptor(id: id, requiredCapabilities: [missing], timeout: 10.0)
        let firstLease = scheduler.schedule(first, taskExecution: {}, completion: { _ in
            firstDone.continuation.yield()
        })

        #expect(await scheduler.waitForCounts(parked: 1))
        #expect(scheduler.parkedCount == 1)
        #expect(scheduler.queuedCount == 0)
        #expect(scheduler.pendingCount == 1)

        scheduler.cancel(taskId: id)
        for await _ in firstDone.stream { break }

        #expect(firstLease.isTerminal)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.queuedCount == 0)
        #expect(scheduler.parkedCount == 0)

        let secondDone = AsyncStream<Void>.makeStream()
        let second = TaskDescriptor(id: id, requiredCapabilities: [missing], timeout: 10.0)
        let secondLease = scheduler.schedule(second, taskExecution: {}, completion: { _ in
            secondDone.continuation.yield()
        })

        #expect(await scheduler.waitForCounts(parked: 1))
        #expect(scheduler.parkedCount == 1)
        #expect(scheduler.pendingCount == 1)
        #expect(!secondLease.isTerminal)

        scheduler.cancel(taskId: id)
        for await _ in secondDone.stream { break }

        #expect(secondLease.isTerminal)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.queuedCount == 0)
        #expect(scheduler.parkedCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("retry re-queue restores pending through Store facade")
    func retryRestoresPending() async {
        let store = DynamicStore()
        let pluginId = "lifecycleRetry_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }

        actor Attempts {
            var count = 0
            func next() -> Int {
                count += 1
                return count
            }
        }
        let attempts = Attempts()
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
