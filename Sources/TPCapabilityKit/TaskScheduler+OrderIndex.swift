import Foundation

extension TaskScheduler.LifecycleStore {
    struct OrderIndex: Sendable {
        private static let dequeueOrder = TaskPriority.allCases.sorted(by: >)
        private var orderQueues: [TaskPriority: [String]] = [:]
        private var orderPrioritiesById: [String: TaskPriority] = [:]

        mutating func enqueue(id: String, priority: TaskPriority) {
            if let existing = orderPrioritiesById[id] {
                orderQueues[existing]?.removeAll { $0 == id }
            }
            orderPrioritiesById[id] = priority
            orderQueues[priority, default: []].append(id)
        }

        mutating func dequeue() -> String? {
            for priority in Self.dequeueOrder {
                guard var queue = orderQueues[priority], !queue.isEmpty else { continue }
                let id = queue.removeFirst()
                orderQueues[priority] = queue
                orderPrioritiesById.removeValue(forKey: id)
                return id
            }
            return nil
        }

        @discardableResult
        mutating func remove(taskId: String) -> Bool {
            guard let priority = orderPrioritiesById[taskId] else { return false }
            orderQueues[priority]?.removeAll { $0 == taskId }
            orderPrioritiesById.removeValue(forKey: taskId)
            return true
        }

        var ids: Set<String> { Set(orderPrioritiesById.keys) }
    }
}
