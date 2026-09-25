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

    let clock: Clock

    var lifecycleStore = LifecycleStore()


    /// Prod generations are built only by the Store threading its one shared
    /// slots + clock across live generations; direct construction with a fresh
    /// controller is a test-only seam that bypasses the shared domain.
    init(store: DynamicStore = .shared, configuration: Configuration = .init(), clock: Clock = .live, concurrencyController: ConcurrencyController) {
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

        let exchanged = lock.withLock {
            lifecycleStore.exchange(
                lease: lease,
                execution: execution,
                waiters: completion.map { [$0] } ?? []
            )
        }
        if let displaced = exchanged.displaced {
            exchanged.waiter?.cancel()
            for waiter in exchanged.waiters {
                waiter(displaced)
            }
        }
        concurrencyController.removeWaiter(taskId: task.id, owner: ObjectIdentifier(lease), match: .stale)

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
        let lease = Lease(task: task)
        let execution: @Sendable () async -> Any? = {
            return try? await taskExecution()
        }

        return await withCheckedContinuation { continuation in
            func resume(with settled: Lease) {
                switch settled.state {
                case .completed:
                    continuation.resume(returning: settled.result as? T)
                default:
                    continuation.resume(returning: nil)
                }
            }

            let outcome = lock.withLock {
                lifecycleStore.scheduleWaitRendezvous(
                    lease: lease,
                    execution: execution,
                    waiter: { resume(with: $0) }
                )
            }
            switch outcome {
            case .parked(let displaced, let waiters, let waiter):
                if let displaced {
                    waiter?.cancel()
                    for waiter in waiters {
                        waiter(displaced)
                    }
                }
                concurrencyController.removeWaiter(taskId: task.id, owner: ObjectIdentifier(lease), match: .stale)
                Task { await self.processPendingTasks() }
            case .settledEarly(let settled):
                concurrencyController.removeWaiter(taskId: task.id, owner: ObjectIdentifier(lease), match: .stale)
                resume(with: settled)
            }
        }
    }

    /// Cancels a pending task.
    /// - Parameter taskId: The ID of the task to cancel.
    func cancel(taskId: String) {
        let target: Lease? = lock.withLock { lifecycleStore.lease(for: taskId) }
        guard let target else { return }
        settle(target, as: .cancelled)
    }

    /// One acquisition so adjacent pending/active/drain reads never disagree.
    var countsSnapshot: (pending: Int, active: Int, isDrained: Bool) {
        lock.withLock {
            let counts = lifecycleStore.counts
            return (counts.pending, counts.active, counts.pending == 0 && counts.active == 0)
        }
    }

    /// Returns the number of pending tasks (queued plus parked; parked-in-pending stays).
    var pendingCount: Int {
        countsSnapshot.pending
    }

    /// Returns the number of active tasks.
    var activeCount: Int {
        countsSnapshot.active
    }

    var isDrained: Bool {
        countsSnapshot.isDrained
    }
}
