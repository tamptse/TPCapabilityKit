import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("PendingQueue Tests")
struct PendingQueueTests {
    private func makeId() -> String { UUID().uuidString }

    @Test("dequeue returns highest priority first regardless of enqueue order")
    func dequeuePriorityOrder() {
        var queue = PendingQueue()
        let background = makeId()
        let low = makeId()
        let normal = makeId()
        let high = makeId()
        let critical = makeId()
        queue.enqueue(id: background, priority: .background)
        queue.enqueue(id: normal, priority: .normal)
        queue.enqueue(id: critical, priority: .critical)
        queue.enqueue(id: low, priority: .low)
        queue.enqueue(id: high, priority: .high)

        #expect(queue.dequeue() == critical)
        #expect(queue.dequeue() == high)
        #expect(queue.dequeue() == normal)
        #expect(queue.dequeue() == low)
        #expect(queue.dequeue() == background)
        #expect(queue.dequeue() == nil)
    }

    @Test("dequeue is FIFO within the same priority")
    func dequeueFIFOWithinPriority() {
        var queue = PendingQueue()
        let first = makeId()
        let second = makeId()
        let third = makeId()
        queue.enqueue(id: first, priority: .normal)
        queue.enqueue(id: second, priority: .normal)
        queue.enqueue(id: third, priority: .normal)

        #expect(queue.dequeue() == first)
        #expect(queue.dequeue() == second)
        #expect(queue.dequeue() == third)
    }

    @Test("count tracks enqueue, dequeue and remove")
    func countTracksTransitions() {
        var queue = PendingQueue()
        #expect(queue.count == 0)

        let first = makeId()
        let second = makeId()
        queue.enqueue(id: first, priority: .high)
        #expect(queue.count == 1)
        queue.enqueue(id: second, priority: .low)
        #expect(queue.count == 2)

        _ = queue.dequeue()
        #expect(queue.count == 1)

        #expect(queue.remove(taskId: second) == true)
        #expect(queue.count == 0)
    }

    @Test("remove returns false for unknown id and dequeue on empty returns nil")
    func unknownRemoveAndEmptyDequeue() {
        var queue = PendingQueue()
        #expect(queue.dequeue() == nil)
        #expect(queue.remove(taskId: "unknown-id") == false)

        let id = makeId()
        queue.enqueue(id: id, priority: .normal)
        #expect(queue.remove(taskId: "unknown-id") == false)
        #expect(queue.count == 1)
    }

    @Test("dequeued id is gone from the queue")
    func lookupAfterDequeue() {
        var queue = PendingQueue()
        let id = makeId()
        queue.enqueue(id: id, priority: .high)

        #expect(queue.dequeue() == id)
        #expect(queue.count == 0)
        #expect(queue.remove(taskId: id) == false)
    }

    @Test("remove after dequeue returns false and count stays derived")
    func removeAfterDequeueStaysDerived() {
        var queue = PendingQueue()
        let first = makeId()
        let second = makeId()
        queue.enqueue(id: first, priority: .normal)
        queue.enqueue(id: second, priority: .normal)

        _ = queue.dequeue()
        #expect(queue.count == 1)
        #expect(queue.remove(taskId: first) == false)
        #expect(queue.count == 1)

        #expect(queue.remove(taskId: second) == true)
        #expect(queue.count == 0)
        #expect(queue.dequeue() == nil)
    }

    @Test("requeued id dequeues again")
    func requeueSameIdentity() {
        var queue = PendingQueue()
        let id = makeId()
        queue.enqueue(id: id, priority: .normal)

        #expect(queue.dequeue() == id)
        #expect(queue.count == 0)

        queue.requeue(id: id, priority: .normal)
        #expect(queue.count == 1)
        #expect(queue.dequeue() == id)
        #expect(queue.count == 0)
    }

    @Test("cancel removes pending id, preserves order of remainder")
    func cancelClearsLookupAndPreservesOrder() {
        var queue = PendingQueue()
        let first = makeId()
        let cancelled = makeId()
        let last = makeId()
        queue.enqueue(id: first, priority: .normal)
        queue.enqueue(id: cancelled, priority: .normal)
        queue.enqueue(id: last, priority: .normal)

        #expect(queue.remove(taskId: cancelled) == true)
        #expect(queue.count == 2)
        #expect(queue.remove(taskId: cancelled) == false)

        #expect(queue.dequeue() == first)
        #expect(queue.dequeue() == last)
        #expect(queue.dequeue() == nil)
        #expect(queue.count == 0)
    }

    @Test("cancel of highest priority promotes next priority")
    func cancelPromotesNextPriority() {
        var queue = PendingQueue()
        let critical = makeId()
        let high = makeId()
        queue.enqueue(id: high, priority: .high)
        queue.enqueue(id: critical, priority: .critical)

        #expect(queue.remove(taskId: critical) == true)
        #expect(queue.count == 1)
        #expect(queue.dequeue() == high)
    }

    @Test("middle removal preserves FIFO order of remainder")
    func middleRemovalPreservesFIFO() {
        var queue = PendingQueue()
        let a = makeId()
        let b = makeId()
        let c = makeId()
        let d = makeId()
        queue.enqueue(id: a, priority: .normal)
        queue.enqueue(id: b, priority: .normal)
        queue.enqueue(id: c, priority: .normal)
        queue.enqueue(id: d, priority: .normal)

        #expect(queue.remove(taskId: b) == true)
        #expect(queue.count == 3)
        #expect(queue.dequeue() == a)
        #expect(queue.dequeue() == c)
        #expect(queue.dequeue() == d)
        #expect(queue.dequeue() == nil)
    }

    @Test("requeue appends to tail behind waiting ids")
    func requeueAppendsToTail() {
        var queue = PendingQueue()
        let first = makeId()
        let second = makeId()
        queue.enqueue(id: first, priority: .normal)
        queue.enqueue(id: second, priority: .normal)

        #expect(queue.dequeue() == first)
        queue.requeue(id: first, priority: .normal)

        #expect(queue.dequeue() == second)
        #expect(queue.dequeue() == first)
        #expect(queue.dequeue() == nil)
    }

    @Test("enqueue of the same id moves it to the tail")
    func duplicateEnqueueMovesToTail() {
        var queue = PendingQueue()
        let first = makeId()
        let second = makeId()
        queue.enqueue(id: first, priority: .normal)
        queue.enqueue(id: second, priority: .normal)
        queue.enqueue(id: first, priority: .normal)

        #expect(queue.count == 2)
        #expect(queue.dequeue() == second)
        #expect(queue.dequeue() == first)
        #expect(queue.dequeue() == nil)
    }
}
