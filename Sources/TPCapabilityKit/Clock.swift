import Foundation

/// Time module: live + virtual behind one sleep seam.
///
/// Prod surface is `sleep` (plus deterministic `advance` drive): the waiter
/// and the executor share `sleep` through the shared race; virtual sleep
/// parks on the deterministic registry until `advance` expires it. Advancing
/// wakes only expired waiters, never loses or duplicates a wakeup.
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var virtual: VirtualTime?

    init() {
    }

    static var live: Clock {
        Clock()
    }

    func enableDeterministic() {
        lock.withLock {
            precondition(virtual == nil, "deterministic time already enabled")
            virtual = VirtualTime()
        }
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

    fileprivate var deterministicRegistry: VirtualTime? {
        lock.withLock { virtual }
    }
}

struct DeterministicClockProbe: Sendable {
    private let clock: Clock

    init(_ clock: Clock) {
        self.clock = clock
    }

    var waiterCount: Int {
        clock.deterministicRegistry?.waiterCount ?? 0
    }

    func waitForWaiters(count expected: Int) async {
        guard let registry = clock.deterministicRegistry else {
            preconditionFailure("deterministic time not enabled")
        }
        await registry.awaitWaiterRegistered(count: expected)
    }
}

/// Deterministic waiter registry behind the virtual adapter. Waiters park
/// with absolute deadlines; `advance` moves the clock once, collects exactly
/// the expired continuations under lock, and resumes them after unlock.
private final class VirtualTime: @unchecked Sendable {
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

    func awaitWaiterRegistered(count expected: Int) async {
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if lock.withLock({ waiters.count }) >= expected { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        preconditionFailure("Clock: no waiter registered within 5s (expected \(expected))")
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
