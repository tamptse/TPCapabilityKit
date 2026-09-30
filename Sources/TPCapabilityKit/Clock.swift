import Foundation

/// Time module: live + virtual behind one sleep seam.
///
/// Prod surface is `sleep` (plus deterministic `advance` drive): the waiter
/// and the executor share `sleep` through the shared race; virtual sleep
/// parks on the deterministic registry until `advance` expires it. Advancing
/// wakes only expired waiters, never loses or duplicates a wakeup.

// MARK: - Clock (prod: sleep seam + advance drive)

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var virtual: VirtualTime?

    init() {
    }

    static var live: Clock {
        Clock()
    }

    func sleep(_ timeout: TimeInterval) async {
        let parked: VirtualTime? = lock.withLock { virtual }
        guard let parked else {
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            return
        }
        await parked.sleep(timeout)
    }

    func advance(by delta: TimeInterval) async {
        precondition(delta >= 0)
        let parked: VirtualTime? = lock.withLock { virtual }
        precondition(parked != nil, "deterministic time not enabled; call enableDeterministicTime() first")
        await parked!.advance(by: delta)
    }
}

// MARK: - VirtualTime park (prod internals)

final class VirtualTime: @unchecked Sendable {
    private let lock = NSLock()
    private var now: TimeInterval = 0
    private var nextID: UInt64 = 0
    private var waiters: [UInt64: (deadline: TimeInterval, continuation: CheckedContinuation<Void, Never>)] = [:]

    var waiterCount: Int {
        lock.withLock { waiters.count }
    }

    func sleep(_ timeout: TimeInterval) async {
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

    func advance(by delta: TimeInterval) async {
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
}

// MARK: - Clock deterministic test facet (test-only rendezvous)

extension Clock {
    func enableDeterministic() {
        lock.withLock {
            precondition(virtual == nil, "deterministic time already enabled")
            virtual = VirtualTime()
        }
    }

    internal var deterministicRegistry: VirtualTime? {
        lock.withLock { virtual }
    }

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

// MARK: - Scheduling / store deterministic test facet

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
