import Foundation

extension Clock {
    var deterministicWaiterCount: Int {
        deterministicRegistry?.waiterCount ?? 0
    }

    func waitForWaiters(count expected: Int) async {
        guard let registry = deterministicRegistry else {
            preconditionFailure("deterministic time not enabled")
        }
        let bound = 10_000
        for _ in 0..<bound {
            if registry.waiterCount >= expected { return }
            await Task.yield()
        }
        if registry.waiterCount >= expected { return }
        preconditionFailure("Clock: no waiter registered (expected \(expected), got \(registry.waiterCount))")
    }
}

extension StoreSchedulingGenerations {
    func enableDeterministicTime() {
        clock.enableDeterministic()
    }

    func advanceTime(by delta: TimeInterval) async {
        await clock.advance(by: delta)
    }

    func waitForDeterministicWaiters(count expected: Int) async {
        await clock.waitForWaiters(count: expected)
    }
}

extension DynamicStore {
    func enableDeterministicTime() {
        precondition(self !== DynamicStore.shared, "deterministic time only on fresh instances")
        precondition(scheduling.isEmpty, "enableDeterministicTime must precede first schedule")
        scheduling.enableDeterministicTime()
    }

    func advanceTime(by delta: TimeInterval) async {
        await scheduling.advanceTime(by: delta)
    }

    func waitForDeterministicWaiters(count expected: Int) async {
        await scheduling.waitForDeterministicWaiters(count: expected)
    }
}
