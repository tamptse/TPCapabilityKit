import Foundation

/// Time module: live + virtual behind one sleep seam.
///
/// The adapter starts live — `sleep` suspends on real time — with one allowed pre-use promotion:
/// `enableDeterministic` swaps live for virtual exactly once before first
/// use, after which the adapter never changes and is never threaded per call.
/// `sleep` is the single seam the waiter and the executor share through
/// the shared race: virtual sleep parks on the deterministic registry until
/// `advance` expires it. Advancing wakes only expired waiters, never loses or
/// duplicates a wakeup, and `waitForWaiters` preserves the adapter gate the
/// advance/wait rendezvous tests synchronize on.
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var virtual: VirtualTime?

    init() {
    }

    static var live: Clock {
        Clock()
    }

    var waiterCount: Int {
        lock.withLock { virtual?.waiterCount ?? 0 }
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

    func waitForWaiters(count expected: Int) async {
        let parked: VirtualTime? = lock.withLock { virtual }
        precondition(parked != nil, "deterministic time not enabled")
        await parked!.awaitWaiterRegistered(count: expected)
    }

    func advance(by delta: TimeInterval) async {
        precondition(delta >= 0)
        let parked: VirtualTime? = lock.withLock { virtual }
        precondition(parked != nil, "deterministic time not enabled; call enableDeterministicTime() first")
        await parked!.advance(by: delta)
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
        await awaitWaiterRegistered(count: 1)
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
