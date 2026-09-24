import Foundation

/// Shared expiry clock behind the Deadline seam: live sleep by
/// default, virtual sleep plus advance policy once deterministic time
/// is enabled, custom sleep only for pinned timeout tests.
final class ExpiryClock: @unchecked Sendable {
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

    static var live: ExpiryClock {
        ExpiryClock()
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
        preconditionFailure("ExpiryClock: no waiter registered within 5s (expected \(expected))")
    }
}
