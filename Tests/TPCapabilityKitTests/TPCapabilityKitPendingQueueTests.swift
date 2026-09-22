import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("PendingQueue Tests")
struct PendingQueueTests {
    private func makeLease(id: String = UUID().uuidString, priority: TaskPriority) -> Lease {
        Lease(task: TaskDescriptor(id: id, requiredCapabilities: [], priority: priority))
    }

    @Test("dequeue returns highest priority first regardless of enqueue order")
    func dequeuePriorityOrder() {
        var queue = PendingQueue()
        let background = makeLease(priority: .background)
        let low = makeLease(priority: .low)
        let normal = makeLease(priority: .normal)
        let high = makeLease(priority: .high)
        let critical = makeLease(priority: .critical)
        queue.enqueue(background)
        queue.enqueue(normal)
        queue.enqueue(critical)
        queue.enqueue(low)
        queue.enqueue(high)

        #expect(queue.dequeue() === critical)
        #expect(queue.dequeue() === high)
        #expect(queue.dequeue() === normal)
        #expect(queue.dequeue() === low)
        #expect(queue.dequeue() === background)
        #expect(queue.dequeue() == nil)
    }

    @Test("dequeue is FIFO within the same priority")
    func dequeueFIFOWithinPriority() {
        var queue = PendingQueue()
        let first = makeLease(priority: .normal)
        let second = makeLease(priority: .normal)
        let third = makeLease(priority: .normal)
        queue.enqueue(first)
        queue.enqueue(second)
        queue.enqueue(third)

        #expect(queue.dequeue() === first)
        #expect(queue.dequeue() === second)
        #expect(queue.dequeue() === third)
    }

    @Test("count tracks enqueue, dequeue and remove")
    func countTracksTransitions() {
        var queue = PendingQueue()
        #expect(queue.count == 0)

        let first = makeLease(priority: .high)
        let second = makeLease(priority: .low)
        queue.enqueue(first)
        #expect(queue.count == 1)
        queue.enqueue(second)
        #expect(queue.count == 2)

        _ = queue.dequeue()
        #expect(queue.count == 1)

        _ = queue.remove(taskId: second.task.id)
        #expect(queue.count == 0)
    }

    @Test("remove returns nil for unknown id and dequeue on empty returns nil")
    func unknownRemoveAndEmptyDequeue() {
        var queue = PendingQueue()
        #expect(queue.dequeue() == nil)
        #expect(queue.remove(taskId: "unknown-id") == nil)

        let lease = makeLease(priority: .normal)
        queue.enqueue(lease)
        #expect(queue.remove(taskId: "unknown-id") == nil)
        #expect(queue.count == 1)
    }

    @Test("dequeued lease is still resolvable by lookup")
    func lookupAfterDequeue() {
        var queue = PendingQueue()
        let lease = makeLease(priority: .high)
        queue.enqueue(lease)

        let dequeued = queue.dequeue()
        #expect(dequeued === lease)
        #expect(queue.lease(taskId: lease.task.id) === lease)
    }

    @Test("requeued lease dequeues again with the same identity")
    func requeueSameIdentity() {
        var queue = PendingQueue()
        let lease = makeLease(priority: .normal)
        queue.enqueue(lease)

        let dequeued = queue.dequeue()
        #expect(dequeued === lease)
        #expect(queue.count == 0)

        queue.requeue(lease)
        #expect(queue.count == 1)
        #expect(queue.lease(taskId: lease.task.id) === lease)
        #expect(queue.dequeue() === lease)
        #expect(queue.count == 0)
    }

    @Test("cancel removes pending lease, clears lookup, preserves order of remainder")
    func cancelClearsLookupAndPreservesOrder() {
        var queue = PendingQueue()
        let first = makeLease(priority: .normal)
        let cancelled = makeLease(priority: .normal)
        let last = makeLease(priority: .normal)
        queue.enqueue(first)
        queue.enqueue(cancelled)
        queue.enqueue(last)

        let removed = queue.remove(taskId: cancelled.task.id)
        #expect(removed === cancelled)
        #expect(queue.lease(taskId: cancelled.task.id) == nil)
        #expect(queue.count == 2)
        #expect(queue.remove(taskId: cancelled.task.id) == nil)

        #expect(queue.dequeue() === first)
        #expect(queue.dequeue() === last)
        #expect(queue.dequeue() == nil)
        #expect(queue.count == 0)
    }

    @Test("cancel of highest priority promotes next priority")
    func cancelPromotesNextPriority() {
        var queue = PendingQueue()
        let critical = makeLease(priority: .critical)
        let high = makeLease(priority: .high)
        queue.enqueue(high)
        queue.enqueue(critical)

        #expect(queue.remove(taskId: critical.task.id) === critical)
        #expect(queue.count == 1)
        #expect(queue.dequeue() === high)
    }
}
