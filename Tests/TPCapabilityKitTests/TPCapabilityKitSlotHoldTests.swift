import Testing
import Foundation
@testable import TPCapabilityKit

private final class ResumeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(String, Bool)] = []

    func recorder(for id: String) -> @Sendable (Bool) -> Void {
        { admitted in
            self.lock.withLock { self.values.append((id, admitted)) }
        }
    }

    var all: [(String, Bool)] {
        lock.withLock { values }
    }
}

private func makeHoldLease(id: String) -> Lease {
    Lease(task: TaskDescriptor(id: id, requiredCapabilities: [.heavyTask]))
}

private func holdController() -> ConcurrencyController {
    ConcurrencyController(maxPerCapability: 1, maxGlobal: 1)
}

@Suite("Slot Hold Tests")
struct SlotHoldTests {
    @Test("admits inline when free and frees on release")
    func admitAndRelease() {
        let controller = holdController()
        let log = ResumeLog()
        let first = makeHoldLease(id: "a")
        let second = makeHoldLease(id: "b")

        #expect(controller.park(first, resume: log.recorder(for: "a")) == .admitted)
        #expect(log.all.isEmpty)

        controller.release(first)
        #expect(log.all.isEmpty)

        #expect(controller.park(second, resume: log.recorder(for: "b")) == .admitted)
    }

    @Test("wakes parked waiters in FIFO order")
    func fifoWakeOrder() {
        let controller = holdController()
        let log = ResumeLog()
        let leaseA = makeHoldLease(id: "a")
        let leaseB = makeHoldLease(id: "b")
        let leaseC = makeHoldLease(id: "c")

        #expect(controller.park(leaseA, resume: log.recorder(for: "a")) == .admitted)
        #expect(controller.park(leaseB, resume: log.recorder(for: "b")) == .parked)
        #expect(controller.park(leaseC, resume: log.recorder(for: "c")) == .parked)

        controller.release(leaseA)
        #expect(log.all.map { $0.0 } == ["b"])
        #expect(log.all.map { $0.1 } == [true])

        controller.release(leaseB)
        #expect(log.all.map { $0.0 } == ["b", "c"])
    }

    @Test("cancelled waiter is skipped on wake")
    func cancelSkipsWaiter() {
        let controller = holdController()
        let log = ResumeLog()
        let leaseA = makeHoldLease(id: "a")
        let leaseB = makeHoldLease(id: "b")
        let leaseC = makeHoldLease(id: "c")

        #expect(controller.park(leaseA, resume: log.recorder(for: "a")) == .admitted)
        #expect(controller.park(leaseB, resume: log.recorder(for: "b")) == .parked)
        #expect(controller.park(leaseC, resume: log.recorder(for: "c")) == .parked)

        controller.cancel(leaseB)
        #expect(log.all.map { $0.0 } == ["b"])
        #expect(log.all.map { $0.1 } == [false])

        controller.release(leaseA)
        #expect(log.all.map { $0.0 } == ["b", "c"])
        #expect(log.all.last?.1 == true)
    }

    @Test("cancel with unknown id or wrong owner is a no-op")
    func cancelMismatchNoops() {
        let controller = holdController()
        let log = ResumeLog()
        let leaseA = makeHoldLease(id: "a")
        let leaseB = makeHoldLease(id: "b")
        let missing = makeHoldLease(id: "missing")
        let impostorB = makeHoldLease(id: "b")

        #expect(controller.park(leaseA, resume: log.recorder(for: "a")) == .admitted)
        #expect(controller.park(leaseB, resume: log.recorder(for: "b")) == .parked)

        controller.cancel(missing)
        controller.cancel(impostorB)
        #expect(log.all.isEmpty)

        controller.release(leaseA)
        #expect(log.all.map { $0.0 } == ["b"])
        #expect(log.all.map { $0.1 } == [true])
    }

    @Test("double acquire is rejected instead of absorbed")
    func doubleAcquireRejected() {
        let controller = holdController()
        let log = ResumeLog()
        let leaseA = makeHoldLease(id: "a")
        let impostorA = makeHoldLease(id: "a")
        let leaseB = makeHoldLease(id: "b")

        #expect(controller.park(leaseA, resume: log.recorder(for: "a")) == .admitted)
        #expect(controller.park(leaseA, resume: log.recorder(for: "a2")) == .duplicate)
        #expect(log.all.isEmpty)

        controller.release(impostorA)
        #expect(log.all.isEmpty)

        controller.release(leaseA)
        #expect(controller.park(leaseB, resume: log.recorder(for: "b")) == .admitted)
    }

    @Test("double release wakes at most once")
    func doubleReleaseWakesOnce() {
        let controller = holdController()
        let log = ResumeLog()
        let leaseA = makeHoldLease(id: "a")
        let leaseB = makeHoldLease(id: "b")

        #expect(controller.park(leaseA, resume: log.recorder(for: "a")) == .admitted)
        #expect(controller.park(leaseB, resume: log.recorder(for: "b")) == .parked)

        controller.release(leaseA)
        controller.release(leaseA)
        #expect(log.all.map { $0.0 } == ["b"])

        controller.release(leaseB)
        #expect(log.all.map { $0.0 } == ["b"])
    }

    @Test("same-id new owner retires the displaced waiter")
    func sameIdDisplacementRetiresOldWaiter() {
        let controller = holdController()
        let log = ResumeLog()
        let holder = makeHoldLease(id: "h")
        let old = makeHoldLease(id: "x")
        let new = makeHoldLease(id: "x")

        #expect(controller.park(holder, resume: log.recorder(for: "h")) == .admitted)
        #expect(controller.park(old, resume: log.recorder(for: "old")) == .parked)
        #expect(controller.park(new, resume: log.recorder(for: "new")) == .parked)
        #expect(log.all.map { $0.0 } == ["old"])
        #expect(log.all.map { $0.1 } == [false])

        controller.release(holder)
        #expect(log.all.map { $0.0 } == ["old", "new"])
        #expect(log.all.last?.1 == true)
    }

    @Test("acquire releases on scope exit through the shared release")
    func acquireScopedRelease() async {
        let controller = holdController()
        let leaseA = makeHoldLease(id: "a")
        let leaseB = makeHoldLease(id: "b")

        func scoped() async -> Int {
            guard await controller.acquire(leaseA) else { return -1 }
            defer { controller.release(leaseA) }
            return 42
        }

        let value = await scoped()
        #expect(value == 42)

        let log = ResumeLog()
        #expect(controller.park(leaseB, resume: log.recorder(for: "b")) == .admitted)
    }

    @Test("cancelled acquire never admits")
    func cancelledAcquireNeverAdmits() async {
        let controller = holdController()
        let log = ResumeLog()
        let leaseA = makeHoldLease(id: "a")
        let leaseB = makeHoldLease(id: "b")
        #expect(controller.park(leaseA, resume: log.recorder(for: "a")) == .admitted)

        let waiter = Task {
            await controller.acquire(leaseB)
        }
        waiter.cancel()
        #expect(await waiter.value == false)
        #expect(log.all.isEmpty)

        controller.release(leaseA)
        #expect(log.all.isEmpty)
    }
}
