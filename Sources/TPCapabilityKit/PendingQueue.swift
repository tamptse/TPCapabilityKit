import Foundation

/// Queue indexes for pending leases, owned by the Tasks module.
///
/// Holds no lock of its own: every call must happen while holding the Tasks
/// lock, since queue transitions apply atomically with active leases and
/// executions.
struct PendingQueue: Sendable {
    private static let priorityOrder: [TaskPriority] = [.critical, .high, .normal, .low, .background]

    private var queues: [TaskPriority: [Lease]]
    private var queuedCount: Int = 0
    private var leasesById: [String: Lease] = [:]

    init() {
        queues = Dictionary(uniqueKeysWithValues: TaskPriority.allCases.map { ($0, []) })
    }

    var count: Int { queuedCount }

    mutating func enqueue(_ lease: Lease) {
        queues[lease.task.priority]?.append(lease)
        queuedCount += 1
        leasesById[lease.task.id] = lease
    }

    mutating func dequeue() -> Lease? {
        for priority in Self.priorityOrder {
            if var queue = queues[priority], !queue.isEmpty {
                let lease = queue.removeFirst()
                queues[priority] = queue
                queuedCount -= 1
                return lease
            }
        }
        return nil
    }

    mutating func requeue(_ lease: Lease) {
        queues[lease.task.priority]?.append(lease)
        queuedCount += 1
        leasesById[lease.task.id] = lease
    }

    mutating func remove(taskId: String) -> Lease? {
        guard let lease = leasesById.removeValue(forKey: taskId) else { return nil }
        let priority = lease.task.priority
        if let index = queues[priority]?.firstIndex(where: { $0.task.id == taskId }) {
            queues[priority]?.remove(at: index)
            queuedCount -= 1
        }
        return lease
    }

    func lease(taskId: String) -> Lease? {
        leasesById[taskId]
    }
}
