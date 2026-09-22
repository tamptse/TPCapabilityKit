import Foundation

/// Order index for pending task ids, owned by the Tasks module.
///
/// Order only: stores (id, priority) for dequeue ordering, no Lease objects,
/// no cancel lookup. Cancel lookup and waiter state live in the Tasks
/// lifecycle table; this queue answers dequeue order and removal only.
/// Called under the Tasks lock, so it holds no lock of its own.
struct PendingQueue: Sendable {
    private static let dequeueOrder = TaskPriority.allCases.sorted(by: >)

    private var prioritiesById: [String: TaskPriority] = [:]
    private var heads: [TaskPriority: String] = [:]
    private var tails: [TaskPriority: String] = [:]
    private var nextById: [String: String] = [:]
    private var prevById: [String: String] = [:]

    init() {}

    mutating func enqueue(id: String, priority: TaskPriority) {
        if let existing = prioritiesById[id] {
            unlink(taskId: id, priority: existing)
        }
        prioritiesById[id] = priority
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

    mutating func dequeue() -> String? {
        for priority in Self.dequeueOrder {
            guard let headId = heads[priority] else { continue }
            guard prioritiesById[headId] != nil else {
                repairDanglingHead(headId, priority: priority)
                continue
            }
            unlink(taskId: headId, priority: priority)
            prioritiesById.removeValue(forKey: headId)
            return headId
        }
        return nil
    }

    @discardableResult
    mutating func remove(taskId: String) -> Bool {
        guard let priority = prioritiesById[taskId] else { return false }
        unlink(taskId: taskId, priority: priority)
        prioritiesById.removeValue(forKey: taskId)
        return true
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
