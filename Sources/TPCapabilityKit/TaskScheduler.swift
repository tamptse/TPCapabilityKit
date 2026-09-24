import Foundation
import Combine

/// Centralized task scheduler that manages capability-based routing,
/// priority queuing, and lease lifecycle.
///
/// Inspired by Meta's Jupiter (capability matching) and Async (priority dispatching).
/// - Important: `@unchecked Sendable` is intentional — all mutable state
///   (`lifecycleStore`) is protected by `lock`. Parked capability waiters are
///   tracked per row and cancelled on terminal settlement. Do not add
///   unsynchronized mutable state.
public final class TaskScheduler: @unchecked Sendable {
    public struct Configuration: Sendable {
        public let defaultTimeout: TimeInterval
        public let maxPerCapability: Int?
        public let maxGlobal: Int?

        public init(
            defaultTimeout: TimeInterval = 30.0,
            maxPerCapability: Int? = 5,
            maxGlobal: Int? = 20
        ) {
            self.defaultTimeout = defaultTimeout
            self.maxPerCapability = maxPerCapability
            self.maxGlobal = maxGlobal
        }

        public static let `default` = Configuration()
    }

    weak var store: DynamicStore?
    let configuration: Configuration
    let concurrencyController: ConcurrencyController
    let lock = NSLock()

    let clock: ExpiryClock

    var lifecycleStore = LifecycleStore()


    init(store: DynamicStore = .shared, configuration: Configuration = .init(), clock: ExpiryClock = .live, concurrencyController: ConcurrencyController) {
        self.store = store
        self.configuration = configuration
        self.clock = clock
        self.concurrencyController = concurrencyController
    }

    /// Schedules a task for execution with a closure.
    /// - Parameters:
    ///   - task: The task descriptor to schedule.
    ///   - taskExecution: The async closure to execute when capability is available.
    ///   - completion: Optional completion handler called when task reaches a terminal state.
    /// - Returns: The lease for tracking the task.
    @discardableResult
    func schedule(
        _ task: TaskDescriptor,
        taskExecution: @escaping @Sendable () async -> Void,
        completion: ((Lease) -> Void)? = nil
    ) -> Lease {
        let lease = enqueue(task, execution: {
            await taskExecution()
            return ()
        }, completion: completion)
        Task { await self.processPendingTasks() }
        return lease
    }

    @discardableResult
    private func enqueue(
        _ task: TaskDescriptor,
        execution: @escaping @Sendable () async -> Any?,
        completion: ((Lease) -> Void)?
    ) -> Lease {
        let lease = Lease(task: task)

        // Same-id concurrent scheduling is unsupported: a non-terminal row for
        // this id belongs to an in-flight lease, so settle it first (expired —
        // the only outcome the Lease contract accepts from pending — so its
        // waiters are delivered exactly once, its waiter Task cancelled, its
        // slot released) before the new row takes the id. A terminal row needs
        // no settle, so sequential reuse after terminal keeps working.
        let displaced: Lease? = lock.withLock {
            lifecycleStore.nonTerminalLease(for: task.id)
        }
        if let displaced {
            settle(displaced, as: .expired)
        }

        lock.withLock {
            lifecycleStore.insert(
                lease: lease,
                execution: execution,
                waiters: completion.map { [$0] } ?? []
            )
        }

        return lease
    }

    /// Schedules a task and waits for its result.
    /// - Parameters:
    ///   - task: The task descriptor to schedule.
    ///   - taskExecution: The async closure to execute when capability is available.
    /// - Returns: The result of the task, or nil if timeout/error.
    func scheduleAndWait<T: Sendable>(
        _ task: TaskDescriptor,
        taskExecution: @escaping @Sendable () async throws -> T
    ) async -> T? {
        let lease = enqueue(task, execution: {
            return try? await taskExecution()
        }, completion: nil)

        return await withCheckedContinuation { continuation in
            func resume(with settled: Lease) {
                switch settled.state {
                case .completed:
                    continuation.resume(returning: settled.result as? T)
                default:
                    continuation.resume(returning: nil)
                }
            }

            let settledEarly: Lease? = lock.withLock {
                // Invariant: every row replacement settles our lease first
                // (displacement settles the old lease before the new row takes
                // the id; terminalize removes the row), so a mismatched row
                // means our lease is already settled — return it, never append
                // to another lease's waiter list.
                lifecycleStore.appendScheduleWaiter(for: lease, waiter: { resume(with: $0) })
            }
            if let settled = settledEarly {
                resume(with: settled)
                return
            }

            Task { await self.processPendingTasks() }
        }
    }

    /// Cancels a pending task.
    /// - Parameter taskId: The ID of the task to cancel.
    func cancel(taskId: String) {
        let target: Lease? = lock.withLock { lifecycleStore.lease(for: taskId) }
        guard let target else { return }
        settle(target, as: .cancelled)
    }

    /// Returns the number of pending tasks (queued plus parked; parked-in-pending stays).
    var pendingCount: Int {
        lock.withLock { lifecycleStore.counts.pending }
    }

    /// Queued portion of pending, internal-only: Tasks tests read the split,
    /// Store facade exposes pending/active only.
    var queuedCount: Int {
        lock.withLock { lifecycleStore.counts.queued }
    }

    /// Parked portion of pending, internal-only: Tasks tests read the split,
    /// Store facade exposes pending/active only.
    var parkedCount: Int {
        lock.withLock { lifecycleStore.counts.parked }
    }

    /// Returns the number of active tasks.
    var activeCount: Int {
        lock.withLock { lifecycleStore.counts.active }
    }
}
