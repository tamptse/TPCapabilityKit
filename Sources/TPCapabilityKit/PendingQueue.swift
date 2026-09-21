import Foundation

/// Queue indexes for pending leases, owned by the Tasks module.
///
/// Holds no lock of its own: every call must happen while holding the Tasks
/// lock, exactly as the fields were guarded before extraction.
struct PendingQueue: Sendable {
    private var queues: [TaskPriority: [Lease]]
    private var queuedCount: Int = 0
    private var prioritiesById: [String: TaskPriority] = [:]
    private var leasesById: [String: Lease] = [:]

    init() {
        queues = Dictionary(uniqueKeysWithValues: TaskPriority.allCases.map { ($0, []) })
    }

    var count: Int { queuedCount }

    mutating func enqueue(_ lease: Lease) {
        queues[lease.task.priority]?.append(lease)
        queuedCount += 1
        prioritiesById[lease.task.id] = lease.task.priority
        leasesById[lease.task.id] = lease
    }

    mutating func dequeue() -> Lease? {
        for priority in TaskPriority.allCases.sorted(by: { $0.rawValue > $1.rawValue }) {
            if var queue = queues[priority], !queue.isEmpty {
                let lease = queue.removeFirst()
                queues[priority] = queue
                queuedCount -= 1
                prioritiesById.removeValue(forKey: lease.task.id)
                return lease
            }
        }
        return nil
    }

    mutating func requeue(_ lease: Lease) {
        queues[lease.task.priority]?.append(lease)
        queuedCount += 1
        prioritiesById[lease.task.id] = lease.task.priority
    }

    mutating func remove(taskId: String) -> Lease? {
        if let priority = prioritiesById.removeValue(forKey: taskId),
           let index = queues[priority]?.firstIndex(where: { $0.task.id == taskId }) {
            queues[priority]?.remove(at: index)
            queuedCount -= 1
        }
        return leasesById.removeValue(forKey: taskId)
    }

    func lease(taskId: String) -> Lease? {
        leasesById[taskId]
    }
}
