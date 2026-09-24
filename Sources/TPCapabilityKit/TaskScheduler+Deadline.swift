import Foundation
import Combine

extension TaskScheduler {
    /// Owns the whole expiry story behind one seam: waiter and executor share
    /// one race, so neither computes timeouts nor builds task groups directly.
    struct Deadline: Sendable {
        typealias Clock = ExpiryClock

        /// Result write for the execution race; the loser is ignored by the race outcome.
        private final class OneShot<T>: @unchecked Sendable {
            private let lock = NSLock()
            private var value: T?

            func store(_ newValue: T?) {
                lock.withLock { value = newValue }
            }

            func load() -> T? {
                lock.withLock { value }
            }
        }

        let timeout: TimeInterval
        private let clock: Clock

        init(task: TaskDescriptor, default defaultTimeout: TimeInterval, clock: Clock) {
            self.timeout = task.timeout ?? defaultTimeout
            self.clock = clock
        }

        func race(operation: @Sendable @escaping () async -> Bool) async -> Bool {
            let timeout = self.timeout
            let clock = self.clock
            return await withTaskGroup(of: Bool.self) { group in
                group.addTask(operation: operation)
                group.addTask {
                    await clock.sleep(timeout)
                    return false
                }
                guard let first = await group.next() else {
                    group.cancelAll()
                    return false
                }
                group.cancelAll()
                return first
            }
        }

        func runExecution(
            _ operation: @Sendable @escaping () async -> Any?
        ) async -> (won: Bool, value: Any?) {
            let box = OneShot<Any?>()
            let won = await race {
                let value = await operation()
                box.store(value)
                return true
            }
            return (won, won ? (box.load() ?? nil) : nil)
        }
    }
}
