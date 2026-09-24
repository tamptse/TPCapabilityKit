import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("PendingQueue Tests (path internal mechanics: row storage + order + single snapshot)")
struct PendingQueueTests {
    private func makeLease(id: String = UUID().uuidString, priority: TaskPriority = .normal) -> Lease {
        Lease(task: TaskDescriptor(id: id, requiredCapabilities: [], priority: priority))
    }

    private func insert(_ store: inout TaskScheduler.LifecycleStore, _ lease: Lease) {
        store.insert(lease: lease, execution: nil, waiters: [])
    }

    private func dequeuedId(_ store: inout TaskScheduler.LifecycleStore) -> String? {
        store.dequeueNext()?.task.id
    }

    private func expectConsistent(_ store: TaskScheduler.LifecycleStore) {
        let snapshot = store.counts
        #expect(snapshot.pending == snapshot.queued + snapshot.parked)
    }

    @Test("dequeue returns highest priority first regardless of enqueue order")
    func dequeuePriorityOrder() {
        var store = TaskScheduler.LifecycleStore()
        let background = makeLease(priority: .background)
        let low = makeLease(priority: .low)
        let normal = makeLease(priority: .normal)
        let high = makeLease(priority: .high)
        let critical = makeLease(priority: .critical)
        insert(&store, background)
        insert(&store, normal)
        insert(&store, critical)
        insert(&store, low)
        insert(&store, high)

        #expect(store.counts.pending == 5)
        #expect(store.counts.queued == 5)
        #expect(store.counts.parked == 0)
        expectConsistent(store)

        #expect(dequeuedId(&store) == critical.task.id)
        #expect(dequeuedId(&store) == high.task.id)
        #expect(dequeuedId(&store) == normal.task.id)
        #expect(dequeuedId(&store) == low.task.id)
        #expect(dequeuedId(&store) == background.task.id)
        #expect(dequeuedId(&store) == nil)
        let snapshot = store.counts
        #expect(snapshot.pending == 5)
        #expect(snapshot.queued == 0)
        #expect(snapshot.parked == 5)
        expectConsistent(store)
    }

    @Test("dequeue is FIFO within the same priority")
    func dequeueFIFOWithinPriority() {
        var store = TaskScheduler.LifecycleStore()
        let first = makeLease()
        let second = makeLease()
        let third = makeLease()
        insert(&store, first)
        insert(&store, second)
        insert(&store, third)

        #expect(dequeuedId(&store) == first.task.id)
        #expect(dequeuedId(&store) == second.task.id)
        #expect(dequeuedId(&store) == third.task.id)
        expectConsistent(store)
    }

    @Test("enqueue, dequeue and terminal take track order")
    func enqueueDequeueRemoveOrder() {
        var store = TaskScheduler.LifecycleStore()
        #expect(dequeuedId(&store) == nil)

        let first = makeLease(priority: .high)
        let second = makeLease(priority: .low)
        insert(&store, first)
        insert(&store, second)

        #expect(dequeuedId(&store) == first.task.id)

        #expect(store.takeTerminal(for: second) != nil)
        #expect(dequeuedId(&store) == nil)
        expectConsistent(store)
        #expect(store.counts.pending == 1)
        #expect(store.counts.parked == 1)
        #expect(store.counts.queued == 0)
    }

    @Test("terminal take of unknown id is nil and dequeue on empty returns nil")
    func unknownRemoveAndEmptyDequeue() {
        var store = TaskScheduler.LifecycleStore()
        #expect(dequeuedId(&store) == nil)
        #expect(store.takeTerminal(for: makeLease(id: "unknown-id")) == nil)

        let lease = makeLease()
        insert(&store, lease)
        #expect(store.takeTerminal(for: makeLease(id: "unknown-id")) == nil)
        #expect(dequeuedId(&store) == lease.task.id)
        #expect(dequeuedId(&store) == nil)
        expectConsistent(store)
    }

    @Test("dequeued row stays parked until terminal take")
    func lookupAfterDequeue() {
        var store = TaskScheduler.LifecycleStore()
        let lease = makeLease(priority: .high)
        insert(&store, lease)

        #expect(dequeuedId(&store) == lease.task.id)
        #expect(dequeuedId(&store) == nil)
        #expect(store.counts.parked == 1)
        expectConsistent(store)

        #expect(store.takeTerminal(for: lease) != nil)
        #expect(store.takeTerminal(for: lease) == nil)
        #expect(store.counts.pending == 0)
    }

    @Test("terminal take of queued row drains order")
    func removeAfterDequeue() {
        var store = TaskScheduler.LifecycleStore()
        let first = makeLease()
        let second = makeLease()
        insert(&store, first)
        insert(&store, second)

        #expect(dequeuedId(&store) == first.task.id)

        #expect(store.takeTerminal(for: second) != nil)
        #expect(dequeuedId(&store) == nil)
        expectConsistent(store)
    }

    @Test("same id dequeues again after terminal take")
    func enqueueSameIdentityAgain() {
        var store = TaskScheduler.LifecycleStore()
        let first = makeLease(id: "reuse-id")
        insert(&store, first)

        #expect(dequeuedId(&store) == first.task.id)
        #expect(dequeuedId(&store) == nil)

        #expect(store.takeTerminal(for: first) != nil)

        let second = makeLease(id: "reuse-id")
        insert(&store, second)
        #expect(dequeuedId(&store) == second.task.id)
        #expect(dequeuedId(&store) == nil)
        expectConsistent(store)
    }

    @Test("terminal take removes pending id, preserves order of remainder")
    func cancelClearsLookupAndPreservesOrder() {
        var store = TaskScheduler.LifecycleStore()
        let first = makeLease()
        let cancelled = makeLease()
        let last = makeLease()
        insert(&store, first)
        insert(&store, cancelled)
        insert(&store, last)

        #expect(store.takeTerminal(for: cancelled) != nil)
        #expect(store.takeTerminal(for: cancelled) == nil)

        #expect(dequeuedId(&store) == first.task.id)
        #expect(dequeuedId(&store) == last.task.id)
        #expect(dequeuedId(&store) == nil)
        expectConsistent(store)
    }

    @Test("terminal take of highest priority promotes next priority")
    func cancelPromotesNextPriority() {
        var store = TaskScheduler.LifecycleStore()
        let high = makeLease(priority: .high)
        let critical = makeLease(priority: .critical)
        insert(&store, high)
        insert(&store, critical)

        #expect(store.takeTerminal(for: critical) != nil)
        #expect(dequeuedId(&store) == high.task.id)
        #expect(dequeuedId(&store) == nil)
        expectConsistent(store)
    }

    @Test("middle terminal take preserves FIFO order of remainder")
    func middleRemovalPreservesFIFO() {
        var store = TaskScheduler.LifecycleStore()
        let a = makeLease()
        let b = makeLease()
        let c = makeLease()
        let d = makeLease()
        insert(&store, a)
        insert(&store, b)
        insert(&store, c)
        insert(&store, d)

        #expect(store.takeTerminal(for: b) != nil)
        #expect(dequeuedId(&store) == a.task.id)
        #expect(dequeuedId(&store) == c.task.id)
        #expect(dequeuedId(&store) == d.task.id)
        #expect(dequeuedId(&store) == nil)
        expectConsistent(store)
    }

    @Test("retry re-queue appends to tail behind waiting ids")
    func enqueueAfterDequeueAppendsToTail() {
        var store = TaskScheduler.LifecycleStore()
        let first = makeLease()
        let second = makeLease()
        insert(&store, first)
        insert(&store, second)

        #expect(dequeuedId(&store) == first.task.id)
        store.applyRetry(for: first, execution: nil)

        #expect(dequeuedId(&store) == second.task.id)
        #expect(dequeuedId(&store) == first.task.id)
        #expect(dequeuedId(&store) == nil)
        expectConsistent(store)
    }

    @Test("re-queue of queued id moves it to the tail")
    func duplicateEnqueueMovesToTail() {
        var store = TaskScheduler.LifecycleStore()
        let first = makeLease()
        let second = makeLease()
        insert(&store, first)
        insert(&store, second)
        store.applyRetry(for: first, execution: nil)

        #expect(dequeuedId(&store) == second.task.id)
        #expect(dequeuedId(&store) == first.task.id)
        #expect(dequeuedId(&store) == nil)
        expectConsistent(store)
    }

    @Test("single snapshot keeps queued plus parked equal to pending")
    func singleSnapshotInvariant() {
        var store = TaskScheduler.LifecycleStore()
        let a = makeLease(priority: .high)
        let b = makeLease()
        let c = makeLease(priority: .low)
        insert(&store, a)
        insert(&store, b)
        insert(&store, c)

        var snapshot = store.counts
        #expect(snapshot.pending == 3)
        #expect(snapshot.pending == snapshot.queued + snapshot.parked)

        #expect(dequeuedId(&store) == a.task.id)
        snapshot = store.counts
        #expect(snapshot.pending == 3)
        #expect(snapshot.queued == 2)
        #expect(snapshot.parked == 1)
        #expect(snapshot.pending == snapshot.queued + snapshot.parked)

        #expect(store.takeTerminal(for: b) != nil)
        snapshot = store.counts
        #expect(snapshot.pending == 2)
        #expect(snapshot.pending == snapshot.queued + snapshot.parked)
    }
}
