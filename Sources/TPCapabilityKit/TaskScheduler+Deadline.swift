import Foundation
import Combine

extension TaskScheduler {
    /// Race-only expiry: timeout resolved once at construction, one race
    /// shared by the waiter and the executor. Both draw expiry from the
    /// injected time instance, so neither computes timeouts nor builds races
    /// directly. See the time module (`Time.swift`) for the sleep seam.
    ///
    /// Stays a named type: the timeout-contract suite constructs it directly
    /// for resolve-once verification, Path is its sole flow reader, and the
    /// registry receives the race as a value without naming this type.
    struct Deadline: Sendable {

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

        func raceValue(operation: @Sendable @escaping () async -> Any?) async -> Any?? {
            let timeout = self.timeout
            let clock = self.clock
            struct Box: @unchecked Sendable {
                let value: Any?
            }
            return await withTaskGroup(of: Box?.self) { group in
                group.addTask {
                    let value = await operation()
                    return Box(value: value)
                }
                group.addTask {
                    await clock.sleep(timeout)
                    return nil
                }
                guard let first = await group.next() else {
                    group.cancelAll()
                    return nil
                }
                group.cancelAll()
                guard let box = first else {
                    return nil
                }
                return .some(box.value)
            }
        }
    }
}
