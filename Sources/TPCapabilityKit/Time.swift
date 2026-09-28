import Foundation

internal struct Deadline: Sendable {
    let timeout: TimeInterval
    private let clock: Clock

    init(task: TaskDescriptor, default defaultTimeout: TimeInterval, clock: Clock) {
        self.timeout = Self.resolve(task.timeout, default: defaultTimeout)
        self.clock = clock
    }

    static func resolve(_ taskTimeout: TimeInterval?, default defaultTimeout: TimeInterval) -> TimeInterval {
        taskTimeout ?? defaultTimeout
    }

    func race(operation: @Sendable @escaping () async -> Bool) async -> Bool {
        await raceValue(operation: { await operation() }).map { ($0 as? Bool) ?? false } ?? false
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
