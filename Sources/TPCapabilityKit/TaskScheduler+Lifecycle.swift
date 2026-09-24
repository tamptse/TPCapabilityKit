import Foundation
import Combine

extension TaskScheduler {
    private enum Place: Sendable {
        case pending
        case parked
        case active
    }

    private struct LifecycleRow {
        var lease: Lease
        var place: Place
        var execution: (@Sendable () async -> Any?)?
        var waiters: [(Lease) -> Void]
        var waiter: Task<Void, Never>?
        var waiting: Bool
    }

    struct LifecycleStore {
        // Single owner: rows owns place and counts; order is a derived index
        // mutated only via insert/dequeueNext/takeTerminal/applyRetry, so the
        // two cannot disagree and no dangling-head repair is needed.
        struct Counts: Sendable, Equatable {
            let pending: Int
            let queued: Int
            let parked: Int
            let active: Int
        }

        private var rows: [String: LifecycleRow] = [:]
        private var order = OrderIndex()
        private var snapshot = Counts(pending: 0, queued: 0, parked: 0, active: 0)

        var counts: Counts { snapshot }

        private mutating func adjust(queued: Int = 0, parked: Int = 0, active: Int = 0) {
            snapshot = Counts(
                pending: snapshot.pending + queued + parked,
                queued: snapshot.queued + queued,
                parked: snapshot.parked + parked,
                active: snapshot.active + active
            )
        }

        private mutating func shift(_ place: Place, by sign: Int) {
            switch place {
            case .pending: adjust(queued: sign)
            case .parked: adjust(parked: sign)
            case .active: adjust(active: sign)
            }
        }

        mutating func insert(
            lease: Lease,
            execution: (@Sendable () async -> Any?)?,
            waiters: [(Lease) -> Void]
        ) {
            if let old = rows[lease.task.id]?.place {
                shift(old, by: -1)
            }
            rows[lease.task.id] = LifecycleRow(
                lease: lease,
                place: .pending,
                execution: execution,
                waiters: waiters,
                waiter: nil,
                waiting: false
            )
            order.enqueue(id: lease.task.id, priority: lease.task.priority)
            shift(.pending, by: 1)
        }

        func nonTerminalLease(for id: String) -> Lease? {
            guard let row = rows[id], !row.lease.isTerminal else { return nil }
            return row.lease
        }

        func lease(for id: String) -> Lease? {
            rows[id]?.lease
        }

        func isLive(_ lease: Lease) -> Bool {
            guard let row = rows[lease.task.id] else { return false }
            return row.lease === lease
        }

        mutating func appendScheduleWaiter(
            for lease: Lease,
            waiter: @escaping (Lease) -> Void
        ) -> Lease? {
            if lease.isTerminal { return lease }
            guard var row = rows[lease.task.id] else { return lease }
            if row.lease !== lease { return lease }
            row.waiters.append(waiter)
            rows[lease.task.id] = row
            return nil
        }

        mutating func beginPark(for lease: Lease) -> Bool {
            mutateParkRow(for: lease) { row in
                guard !row.waiting else { return false }
                row.waiting = true
                return true
            } ?? false
        }

        mutating func setParkWaiter(for lease: Lease, waiter: Task<Void, Never>) -> Bool {
            mutateParkRow(for: lease) { $0.waiter = waiter }
            return lease.isTerminal
        }

        mutating func clearParkWait(for lease: Lease) {
            mutateParkRow(for: lease) {
                $0.waiting = false
                $0.waiter = nil
            }
        }

        private mutating func mutateParkRow<T>(for lease: Lease, _ body: (inout LifecycleRow) -> T) -> T? {
            guard var row = rows[lease.task.id], row.lease === lease else { return nil }
            let result = body(&row)
            rows[lease.task.id] = row
            return result
        }

        mutating func dequeueNext() -> Lease? {
            while let id = order.dequeue() {
                if var row = rows[id] {
                    shift(row.place, by: -1)
                    shift(.parked, by: 1)
                    row.place = .parked
                    rows[id] = row
                    return row.lease
                }
            }
            return nil
        }

        func execution(for lease: Lease) -> (@Sendable () async -> Any?)? {
            guard let row = rows[lease.task.id], row.lease === lease else { return nil }
            return row.execution
        }

        mutating func tryActivate(for lease: Lease) -> Bool {
            guard !lease.isTerminal else { return false }
            guard var row = rows[lease.task.id], row.lease === lease else { return false }
            shift(row.place, by: -1)
            shift(.active, by: 1)
            lease.activate()
            row.place = .active
            rows[lease.task.id] = row
            return true
        }

        mutating func applyRetry(
            for lease: Lease,
            execution: (@Sendable () async -> Any?)?
        ) {
            guard var row = rows[lease.task.id], row.lease === lease else { return }
            shift(row.place, by: -1)
            shift(.pending, by: 1)
            row.place = .pending
            if let execution {
                row.execution = execution
            }
            rows[lease.task.id] = row
            order.enqueue(id: lease.task.id, priority: lease.task.priority)
        }

        mutating func takeTerminal(for lease: Lease) -> (waiters: [(Lease) -> Void], waiter: Task<Void, Never>?)? {
            guard let row = rows[lease.task.id], row.lease === lease else { return nil }
            shift(row.place, by: -1)
            rows.removeValue(forKey: lease.task.id)
            order.remove(taskId: lease.task.id)
            return (row.waiters, row.waiter)
        }

        private struct OrderIndex: Sendable {
            private static let dequeueOrder = TaskPriority.allCases.sorted(by: >)

            private var prioritiesById: [String: TaskPriority] = [:]
            private var heads: [TaskPriority: String] = [:]
            private var tails: [TaskPriority: String] = [:]
            private var nextById: [String: String] = [:]
            private var prevById: [String: String] = [:]

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
    }
}
