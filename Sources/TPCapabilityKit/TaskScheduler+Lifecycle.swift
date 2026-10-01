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
        private var snapshot = Counts(pending: 0, queued: 0, parked: 0, active: 0)

        // Order index plus ledger are private mechanics of the table; only table writers touch them.
        private var orderIndex = OrderIndex()

        // Snapshot refines derive-instead-of-store for hot-path pending reads.
        // Recomputed counts stay debug-only for invariant checks, stripped in release.
        var counts: Counts { snapshot }

        private static func nextCounts(_ base: Counts, from: Place?, to: Place?) -> Counts {
            var queued = base.queued
            var parked = base.parked
            var active = base.active
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
            return Counts(
                pending: queued + parked,
                queued: queued,
                parked: parked,
                active: active
            )
        }

        private mutating func move(from: Place?, to: Place?) {
            snapshot = Self.nextCounts(snapshot, from: from, to: to)
        }

        private func recalculatedCounts() -> Counts {
            var queued = 0
            var parked = 0
            var active = 0
            for row in rows.values {
                switch row.place {
                case .pending: queued += 1
                case .parked: parked += 1
                case .active: active += 1
                }
            }
            return Counts(pending: queued + parked, queued: queued, parked: parked, active: active)
        }

        private func debugInvariant() {
            assert(recalculatedCounts() == snapshot)
            assert(orderIndex.ids == Set(rows.filter { $0.value.place == .pending }.keys))
        }

        // Single locked insert seam: fresh insert plus same-id displace live
        // here so no half-displaced id is observable. Displaced lease
        // terminalizes with its row removal; waiters plus park waiter return
        // for outside-lock delivery and cancel. Slot stale-evict stays after
        // on its own lock, never nested.
        mutating func insert(
            lease: Lease,
            execution: (@Sendable () async -> Any?)?,
            waiters: [(Lease) -> Void]
        ) -> ExchangeResult {
            var result = ExchangeResult(displaced: nil, waiters: [], waiter: nil, evict: nil)
            if let row = rows[lease.task.id], row.lease !== lease, !row.lease.isTerminal,
                let taken = takeRow(for: row.lease)
            {
                taken.lease.terminalize(.expired)
                result = ExchangeResult(
                    displaced: taken.lease,
                    waiters: taken.waiters,
                    waiter: taken.waiter,
                    evict: EvictObligation(taskId: lease.task.id, owner: ObjectIdentifier(lease))
                )
            }
            let old = rows[lease.task.id]?.place
            rows[lease.task.id] = LifecycleRow(
                lease: lease,
                place: .pending,
                execution: execution,
                waiters: waiters,
                waiter: nil,
                waiting: false
            )
            orderIndex.enqueue(id: lease.task.id, priority: lease.task.priority)
            move(from: old, to: .pending)
            debugInvariant()
            return result
        }

        struct EvictObligation: Sendable {
            let taskId: String
            let owner: ObjectIdentifier
        }

        struct ExchangeResult {
            let displaced: Lease?
            let waiters: [(Lease) -> Void]
            let waiter: Task<Void, Never>?
            let evict: EvictObligation?
        }

        func lease(for id: String) -> Lease? {
            rows[id]?.lease
        }

        enum Transition {
            case activate
            case dequeueToParked
            case wake
            case retry((@Sendable () async -> Any?)?)
            case terminal(Lease.Terminal)
        }

        enum TransitionResult {
            case activated
            case parked
            case woken
            case retried
            case terminal(waiters: [(Lease) -> Void], waiter: Task<Void, Never>?)
        }

        /// Single writer for the Lease lifecycle: the Lease mutation and the
        /// row mutation happen together here under the scheduler lock, entered
        /// through one liveness query.
        /// Invariant stated once here: rows place plus order queues plus
        /// snapshot counts agree on every transition. Insert, transition
        /// (including dequeue-to-parked, wake, activate, retry, terminal),
        /// row-take, and dequeue-next are the only writers; Path is the only
        /// flow reader.
        private func liveRow(for lease: Lease) -> LifecycleRow? {
            guard !lease.isTerminal, let row = rows[lease.task.id], row.lease === lease else {
                return nil
            }
            return row
        }

        mutating func transition(for lease: Lease, to target: Transition) -> TransitionResult? {
            defer { debugInvariant() }
            switch target {
            case .dequeueToParked:
                guard var row = rows[lease.task.id], row.lease === lease else {
                    return nil
                }
                move(from: row.place, to: .parked)
                row.place = .parked
                rows[lease.task.id] = row
                return .parked
            case .wake:
                guard var row = rows[lease.task.id], row.lease === lease else {
                    return nil
                }
                row.waiting = false
                row.waiter = nil
                rows[lease.task.id] = row
                return .woken
            case .activate:
                guard var row = liveRow(for: lease) else {
                    return nil
                }
                move(from: row.place, to: .active)
                lease.activate()
                row.place = .active
                rows[lease.task.id] = row
                return .activated
            case .retry(let execution):
                guard var row = liveRow(for: lease) else {
                    return nil
                }
                lease.beginRetry()
                move(from: row.place, to: .pending)
                row.place = .pending
                if let execution {
                    row.execution = execution
                }
                rows[lease.task.id] = row
                orderIndex.enqueue(id: lease.task.id, priority: lease.task.priority)
                return .retried
            case .terminal(let terminal):
                guard liveRow(for: lease) != nil else {
                    return nil
                }
                guard let taken = takeRow(for: lease) else { return nil }
                lease.terminalize(terminal)
                return .terminal(waiters: taken.waiters, waiter: taken.waiter)
            }
        }

        private mutating func takeRow(for lease: Lease) -> LifecycleRow? {
            guard let row = rows[lease.task.id], row.lease === lease else { return nil }
            move(from: row.place, to: nil)
            rows.removeValue(forKey: lease.task.id)
            orderIndex.remove(taskId: lease.task.id)
            debugInvariant()
            return row
        }

        enum ScheduleWaitRendezvousOutcome {
            case parked(ExchangeResult)
            case settledEarly(Lease)
        }

        mutating func scheduleWaitRendezvous(
            lease: Lease,
            execution: (@Sendable () async -> Any?)?,
            waiter: @escaping (Lease) -> Void
        ) -> ScheduleWaitRendezvousOutcome {
            if lease.isTerminal { return .settledEarly(lease) }
            let result = insert(lease: lease, execution: execution, waiters: [waiter])
            guard let fresh = rows[lease.task.id], fresh.lease === lease else {
                return .settledEarly(lease)
            }
            if lease.isTerminal { return .settledEarly(lease) }
            return .parked(result)
        }

        enum FusedParkOutcome: Sendable {
            case parked
            case refusedAlreadyWaiting
            case alreadyTerminal
        }

        // Factory form is the single park seam so no Task exists before the
        // single row write. Factory must not suspend; caller holds the
        // scheduler lock across the call.
        // Wake clears in transition(.wake); terminal takes the row in transition(.terminal).
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

        mutating func dequeueNext() -> Lease? {
            defer { debugInvariant() }
            while let id = orderIndex.dequeue() {
                guard let row = rows[id] else { continue }
                guard transition(for: row.lease, to: .dequeueToParked) != nil else { continue }
                return row.lease
            }
            return nil
        }

        func execution(for lease: Lease) -> (@Sendable () async -> Any?)? {
            guard let row = rows[lease.task.id], row.lease === lease else { return nil }
            return row.execution
        }

        private struct OrderIndex: Sendable {
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
}
