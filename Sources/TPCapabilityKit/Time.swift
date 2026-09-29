import Foundation

/// Single-expiry owner: timeout resolves once at init; waiter + executor share one race.
internal struct Deadline: Sendable {
    let timeout: TimeInterval
    private let clock: Clock

    private struct Box: @unchecked Sendable {
        let value: Any?
    }

    init(task: TaskDescriptor, default defaultTimeout: TimeInterval, clock: Clock) {
        self.timeout = task.timeout ?? defaultTimeout
        self.clock = clock
    }

    func race(operation: @Sendable @escaping () async -> Bool) async -> Bool {
        await raceValue(operation: { await operation() }).map { ($0 as? Bool) ?? false } ?? false
    }

    func raceValue(operation: @Sendable @escaping () async -> Any?) async -> Any?? {
        let timeout = self.timeout
        let clock = self.clock
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
