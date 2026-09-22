import Foundation

/// Queue indexes for pending leases, owned by the Tasks module.
///
/// Module with a small Interface behind the Tasks Seam: enqueue/dequeue/
/// requeue/remove/lookup/count. Called under the Tasks lock, so it holds
/// no lock of its own.
struct PendingQueue: Sendable {
    private static let dequeueOrder = TaskPriority.allCases.sorted(by: >)

    private var leasesById: [String: Lease] = [:]
    private var heads: [TaskPriority: String] = [:]
    private var tails: [TaskPriority: String] = [:]
    private var nextById: [String: String] = [:]
    private var prevById: [String: String] = [:]

    init() {}

    var count: Int { leasesById.count }

    mutating func enqueue(_ lease: Lease) {
        insertAtTail(lease)
    }

    mutating func dequeue() -> Lease? {
        for priority in Self.dequeueOrder {
            guard let headId = heads[priority] else { continue }
            guard let lease = leasesById[headId] else {
                repairDanglingHead(headId, priority: priority)
                continue
            }
            unlink(taskId: headId, priority: priority)
            leasesById.removeValue(forKey: headId)
            return lease
        }
        return nil
    }

    mutating func requeue(_ lease: Lease) {
        insertAtTail(lease)
    }

    mutating func remove(taskId: String) -> Lease? {
        guard let lease = leasesById[taskId] else { return nil }
        unlink(taskId: taskId, priority: lease.task.priority)
        leasesById.removeValue(forKey: taskId)
        return lease
    }

    func lease(taskId: String) -> Lease? {
        leasesById[taskId]
    }

    private mutating func insertAtTail(_ lease: Lease) {
        let id = lease.task.id
        if let existing = leasesById[id] {
            unlink(taskId: id, priority: existing.task.priority)
        }
        leasesById[id] = lease
        let priority = lease.task.priority
        if let tailId = tails[priority] {
            nextById[tailId] = id
            prevById[id] = tailId
            tails[priority] = id
            nextById.removeValue(forKey: id)
        } else {
            heads[priority] = id
            tails[priority] = id
            prevById.removeValue(forKey: id)
            nextById.removeValue(forKey: id)
        }
    }

    private mutating func repairDanglingHead(_ headId: String, priority: TaskPriority) {
        if let nextId = nextById[headId] {
            heads[priority] = nextId
            prevById.removeValue(forKey: nextId)
        } else {
            heads.removeValue(forKey: priority)
            tails.removeValue(forKey: priority)
        }
        nextById.removeValue(forKey: headId)
        prevById.removeValue(forKey: headId)
    }

    private mutating func unlink(taskId: String, priority: TaskPriority) {
        let prevId = prevById[taskId]
        let nextId = nextById[taskId]
        if let prevId {
            if let nextId {
                nextById[prevId] = nextId
                prevById[nextId] = prevId
            } else {
                nextById.removeValue(forKey: prevId)
                tails[priority] = prevId
            }
        } else if let nextId {
            heads[priority] = nextId
            prevById.removeValue(forKey: nextId)
        } else {
            heads.removeValue(forKey: priority)
            tails.removeValue(forKey: priority)
        }
        prevById.removeValue(forKey: taskId)
        nextById.removeValue(forKey: taskId)
    }
}
