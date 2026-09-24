import Foundation

extension TaskScheduler {
    enum Decision {
        case retry
        case complete(Any?)
        case fail
        case expire
    }
}

/// Single terminal decision per ADR-0001/0004; Settlement owns retry budget,
/// void policy, and waiter preservation while `terminalize` stays a safety no-op.
func decide(lease: Lease, outcome: TaskScheduler.Settlement) -> TaskScheduler.Decision {
    switch outcome {
    case .completed(let result):
        if result == nil, lease.canRetry { return .retry }
        if result != nil { return .complete(result) }
        return lease.isActive ? .fail : .expire
    case .failed:
        return lease.isActive ? .fail : .expire
    case .expired, .cancelled:
        return .expire
    }
}

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

        private mutating func move(from: Place?, to: Place?) {
            var queued = snapshot.queued
            var parked = snapshot.parked
            var active = snapshot.active
            switch from {
            case .pending: queued -= 1
            case .parked: parked -= 1
            case .active: active -= 1
            case nil: break
            }
            switch to {
            case .pending: queued += 1
            case .parked: parked += 1
            case .active: active += 1
            case nil: break
            }
            snapshot = Counts(
                pending: queued + parked,
                queued: queued,
                parked: parked,
                active: active
            )
        }

        mutating func insert(
            lease: Lease,
            execution: (@Sendable () async -> Any?)?,
            waiters: [(Lease) -> Void]
        ) {
            let old = rows[lease.task.id]?.place
            rows[lease.task.id] = LifecycleRow(
                lease: lease,
                place: .pending,
                execution: execution,
                waiters: waiters,
                waiter: nil,
                waiting: false
            )
            order.enqueue(id: lease.task.id, priority: lease.task.priority)
            move(from: old, to: .pending)
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
                    move(from: row.place, to: .parked)
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
            move(from: row.place, to: .active)
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
            move(from: row.place, to: .pending)
            row.place = .pending
            if let execution {
                row.execution = execution
            }
            rows[lease.task.id] = row
            order.enqueue(id: lease.task.id, priority: lease.task.priority)
        }

        mutating func takeTerminal(for lease: Lease) -> (waiters: [(Lease) -> Void], waiter: Task<Void, Never>?)? {
            guard let row = rows[lease.task.id], row.lease === lease else { return nil }
            move(from: row.place, to: nil)
            rows.removeValue(forKey: lease.task.id)
            order.remove(taskId: lease.task.id)
            return (row.waiters, row.waiter)
        }

        private struct OrderIndex: Sendable {
            private static let dequeueOrder = TaskPriority.allCases.sorted(by: >)

            private var queues: [TaskPriority: [String]] = [:]
            private var prioritiesById: [String: TaskPriority] = [:]

            mutating func enqueue(id: String, priority: TaskPriority) {
                if let existing = prioritiesById[id] {
                    queues[existing]?.removeAll { $0 == id }
                }
                prioritiesById[id] = priority
                queues[priority, default: []].append(id)
            }

            mutating func dequeue() -> String? {
                for priority in Self.dequeueOrder {
                    guard var queue = queues[priority], !queue.isEmpty else { continue }
                    let id = queue.removeFirst()
                    queues[priority] = queue
                    prioritiesById.removeValue(forKey: id)
                    return id
                }
                return nil
            }

            @discardableResult
            mutating func remove(taskId: String) -> Bool {
                guard let priority = prioritiesById[taskId] else { return false }
                queues[priority]?.removeAll { $0 == taskId }
                prioritiesById.removeValue(forKey: taskId)
                return true
            }
        }
    }
}
