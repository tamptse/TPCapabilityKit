import Foundation

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

        enum Transition {
            case activate
            case retry((@Sendable () async -> Any?)?)
            case terminal(Lease.Terminal)
        }

        enum TransitionResult {
            case activated
            case retried
            case terminal(waiters: [(Lease) -> Void], waiter: Task<Void, Never>?)
        }

        /// Single writer for the Lease lifecycle: the Lease mutation and the
        /// row mutation happen together here under the scheduler lock, entered
        /// through one liveness query.
        mutating func transition(for lease: Lease, to target: Transition) -> TransitionResult? {
            guard !lease.isTerminal, var row = rows[lease.task.id], row.lease === lease else {
                return nil
            }
            switch target {
            case .activate:
                move(from: row.place, to: .active)
                lease.activate()
                row.place = .active
                rows[lease.task.id] = row
                return .activated
            case .retry(let execution):
                lease.beginRetry()
                move(from: row.place, to: .pending)
                row.place = .pending
                if let execution {
                    row.execution = execution
                }
                rows[lease.task.id] = row
                order.enqueue(id: lease.task.id, priority: lease.task.priority)
                return .retried
            case .terminal(let terminal):
                guard let taken = takeRow(for: lease) else { return nil }
                lease.terminalize(terminal)
                return .terminal(waiters: taken.waiters, waiter: taken.waiter)
            }
        }

        private mutating func takeRow(for lease: Lease) -> LifecycleRow? {
            guard let row = rows[lease.task.id], row.lease === lease else { return nil }
            move(from: row.place, to: nil)
            rows.removeValue(forKey: lease.task.id)
            order.remove(taskId: lease.task.id)
            return row
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

        enum FusedParkOutcome: Sendable {
            case parked
            case refusedAlreadyWaiting
            case alreadyTerminal
        }

        // Factory form is the chosen shape so no Task exists before the single
        // row write; the Task form stays as fallback with table-owned cancel.
        // Factory must not suspend; caller holds the scheduler lock across the call.
        // Wake clears here; terminal takes the row in transition(.terminal).
        mutating func park(for lease: Lease, makeWaiter: () -> Task<Void, Never>) -> FusedParkOutcome {
            guard var row = rows[lease.task.id], row.lease === lease else {
                return .alreadyTerminal
            }
            if lease.isTerminal {
                return .alreadyTerminal
            }
            guard !row.waiting else {
                return .refusedAlreadyWaiting
            }
            let waiter = makeWaiter()
            row.waiting = true
            row.waiter = waiter
            rows[lease.task.id] = row
            return .parked
        }

        mutating func park(
            for lease: Lease,
            waiter: Task<Void, Never>
        ) -> (outcome: FusedParkOutcome, waiterToCancel: Task<Void, Never>?) {
            guard var row = rows[lease.task.id], row.lease === lease else {
                return (.alreadyTerminal, waiter)
            }
            if lease.isTerminal {
                return (.alreadyTerminal, waiter)
            }
            guard !row.waiting else {
                return (.refusedAlreadyWaiting, waiter)
            }
            row.waiting = true
            row.waiter = waiter
            rows[lease.task.id] = row
            return (.parked, nil)
        }

        mutating func wakeParked(for lease: Lease) {
            guard var row = rows[lease.task.id], row.lease === lease else { return }
            row.waiting = false
            row.waiter = nil
            rows[lease.task.id] = row
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

        // Priority FIFO order only; place and counts live in rows/snapshot.
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
