import Foundation
import Combine

extension TaskScheduler {
    /// Owns the whole expiry story behind one seam: waiter and executor share
    /// one race, so neither computes timeouts nor builds task groups directly.
    struct Deadline: Sendable {
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var now: TimeInterval = 0
            private var nextID: UInt64 = 0
            private var waiters: [UInt64: (deadline: TimeInterval, continuation: CheckedContinuation<Void, Never>)] = [:]
            private var virtualEnabled = false
            private let sleepOverride: (@Sendable (TimeInterval) async -> Void)?

            init() {
                self.sleepOverride = nil
            }

            init(sleep: @Sendable @escaping (TimeInterval) async -> Void) {
                self.sleepOverride = sleep
            }

            static var live: Clock {
                Clock()
            }

            var waiterCount: Int {
                lock.withLock { waiters.count }
            }

            func enableDeterministic() {
                lock.withLock {
                    precondition(!virtualEnabled, "deterministic time already enabled")
                    virtualEnabled = true
                }
            }

            func sleep(_ timeout: TimeInterval) async {
                if let override = sleepOverride {
                    await override(timeout)
                    return
                }
                let virtual: Bool = lock.withLock { virtualEnabled }
                if !virtual {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                    return
                }
                if timeout <= 0 { return }
                if Task.isCancelled { return }
                let id: UInt64 = lock.withLock {
                    nextID &+= 1
                    return nextID
                }
                await withTaskCancellationHandler {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        var immediate: CheckedContinuation<Void, Never>?
                        lock.withLock {
                            let deadline = now + timeout
                            if deadline <= now {
                                immediate = cont
                            } else {
                                waiters[id] = (deadline, cont)
                            }
                        }
                        immediate?.resume()
                    }
                } onCancel: {
                    var cont: CheckedContinuation<Void, Never>?
                    lock.withLock { cont = waiters.removeValue(forKey: id)?.continuation }
                    cont?.resume()
                }
            }

            func waitForWaiters(count expected: Int) async {
                let isVirtual: Bool = lock.withLock { virtualEnabled }
                precondition(isVirtual, "deterministic time not enabled")
                await waitForWaitersNoPrecondition(count: expected)
            }

            func advance(by delta: TimeInterval) async {
                precondition(delta >= 0)
                let isVirtual: Bool = lock.withLock { virtualEnabled }
                precondition(isVirtual, "deterministic time not enabled; call enableDeterministicTime() first")
                await waitForWaitersNoPrecondition(count: 1)
                var expired: [CheckedContinuation<Void, Never>] = []
                lock.withLock {
                    now += delta
                    let current = now
                    var remaining: [UInt64: (deadline: TimeInterval, continuation: CheckedContinuation<Void, Never>)] = [:]
                    remaining.reserveCapacity(waiters.count)
                    for (id, waiter) in waiters {
                        if waiter.deadline <= current {
                            expired.append(waiter.continuation)
                        } else {
                            remaining[id] = waiter
                        }
                    }
                    waiters = remaining
                }
                for cont in expired {
                    cont.resume()
                }
                await Task.yield()
                await Task.yield()
            }

            private func waitForWaitersNoPrecondition(count expected: Int) async {
                let deadline = Date().addingTimeInterval(5.0)
                while Date() < deadline {
                    if lock.withLock({ waiters.count }) >= expected { return }
                    await Task.yield()
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                preconditionFailure("Deadline.Clock: no waiter registered within 5s (expected \(expected))")
            }
        }

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
