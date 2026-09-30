import Foundation

extension TaskScheduler.LifecycleStore {
    struct OrderIndex: Sendable {
        private static let dequeueOrder = TaskPriority.allCases.sorted(by: >)
        private struct Ledger: Sendable {
            static let compactionHeadBound = 64
            var storage: [String] = []
            var head: Int = 0

            var isEmpty: Bool { head >= storage.count }

            mutating func append(_ id: String) {
                storage.append(id)
            }

            mutating func popFirst() -> String? {
                guard head < storage.count else {
                    storage.removeAll(keepingCapacity: false)
                    head = 0
                    return nil
                }
                let id = storage[head]
                head += 1
                if head >= storage.count {
                    storage.removeAll(keepingCapacity: false)
                    head = 0
                } else if head > Self.compactionHeadBound && head > storage.count / 2 {
                    storage.removeFirst(head)
                    head = 0
                }
                return id
            }

            mutating func removeLive(id: String) {
                guard head < storage.count else {
                    storage.removeAll(keepingCapacity: false)
                    head = 0
                    return
                }
                var found = false
                for i in head..<storage.count where storage[i] == id {
                    found = true
                    break
                }
                guard found else { return }
                var kept: [String] = []
                kept.reserveCapacity(storage.count - head - 1)
                for i in head..<storage.count where storage[i] != id {
                    kept.append(storage[i])
                }
                storage = kept
                head = 0
            }
        }
        private var orderQueues: [TaskPriority: Ledger] = [:]
        private var orderPrioritiesById: [String: TaskPriority] = [:]

        mutating func enqueue(id: String, priority: TaskPriority) {
            if let existing = orderPrioritiesById[id] {
                if var ledger = orderQueues[existing] {
                    ledger.removeLive(id: id)
                    if ledger.isEmpty {
                        orderQueues.removeValue(forKey: existing)
                    } else {
                        orderQueues[existing] = ledger
                    }
                }
            }
            orderPrioritiesById[id] = priority
            orderQueues[priority, default: Ledger()].append(id)
        }

        mutating func dequeue() -> String? {
            for priority in Self.dequeueOrder {
                guard var ledger = orderQueues[priority], !ledger.isEmpty else { continue }
                guard let id = ledger.popFirst() else { continue }
                if ledger.isEmpty {
                    orderQueues.removeValue(forKey: priority)
                } else {
                    orderQueues[priority] = ledger
                }
                orderPrioritiesById.removeValue(forKey: id)
                return id
            }
            return nil
        }

        @discardableResult
        mutating func remove(taskId: String) -> Bool {
            guard let priority = orderPrioritiesById[taskId] else { return false }
            if var ledger = orderQueues[priority] {
                ledger.removeLive(id: taskId)
                if ledger.isEmpty {
                    orderQueues.removeValue(forKey: priority)
                } else {
                    orderQueues[priority] = ledger
                }
            }
            orderPrioritiesById.removeValue(forKey: taskId)
            return true
        }

        var ids: Set<String> { Set(orderPrioritiesById.keys) }
    }
}
