import Foundation

/// Time module: whole expiry flow behind one sleep seam plus one race seam.
///
/// Live sleep plus virtual park plus advance scan plus timeout-once resolution
/// plus the single shared race read as one module with prod shapes unchanged.
/// The waiter and the executor share one expiry with no wait-vs-execution kind
/// distinction through the shared race; virtual sleep parks on the registry
/// until `advance` expires it, waking only expired waiters with no loss or
/// duplication. Sharing across live generations is fixed beside Generations
/// construction (see `StoreSchedulingGenerations`); this module only threads
/// the shared instance.

// MARK: - Deadline (single timeout resolver contract plus shared race)

/// Single timeout resolver and single-expiry owner: `Deadline` construction is the
/// sole resolver of unspecified timeouts; waiter and executor share one race.
///
/// ### Timeout Resolver Contract
/// `Deadline` construction owns timeout resolution once for every scheduled task.
/// All callers across Swift and Objective-C funnel through this single resolver:
///
/// 1. **Swift nil**: Unspecified timeout (`TaskDescriptor.timeout == nil`). Resolves
///    at construction to the scheduler configuration's `defaultTimeout` (`task.timeout ?? defaultTimeout`).
/// 2. **ObjC wire-negative (< 0)**: Unspecified timeout translated by `ObjcTimeout.resolve(wire:)`
///    into `.unspecified` (`TaskDescriptor.timeout == nil`). Resolves at construction
///    to the scheduler configuration's `defaultTimeout` identically to Swift nil.
/// 3. **ObjC omitted**: Carried as explicit pinned compat literal (`ObjcTimeout.pinnedDefault == 30.0`,
///    per ADR-0020) via `ObjcTimeout.resolve` default parameter (`TaskDescriptor.timeout == 30.0`).
///    Travels unchanged through construction and does *not* follow a reconfigured scheduler default.
/// 4. **Explicit non-negative**: Non-negative timeouts from either Swift or Objective-C
///    arrive as `task.timeout != nil` and travel unchanged through construction.
///
/// Downstream translators (`ObjcTimeout` in `ObjcMapper.swift`, `ObjcTaskDescriptor`,
/// and `ObjcBridgeDoor`) are thin translators of wire formats and do not resolve defaults.
///
/// ### Single Expiry
/// Once resolved at init, the same `Deadline` instance is shared across both capability
/// waiting (`waitForCapabilitiesAndProcess`) and task execution (`runActivatedLease`)
/// through the shared race seam (`raceValue` / `race`), ensuring wait-vs-execution
/// has no kind distinction.
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

    /// Race-value core with one Bool adapter: `raceValue` owns the shared task-group race;
    /// `race` is the narrow Bool grain applying cast-plus-default over it.
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

    func race(operation: @Sendable @escaping () async -> Bool) async -> Bool {
        await raceValue(operation: { await operation() }).map { ($0 as? Bool) ?? false } ?? false
    }
}

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
