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

private final class Token: @unchecked Sendable {}

/// Owner tokens must stay alive for the whole test: a bare
/// `ObjectIdentifier(Token())` dangles and later temporaries reuse its address.
private struct Owners: Sendable {
    private let tokens: [Token]
    let ids: [ObjectIdentifier]

    init(_ count: Int) {
        let made = (0..<count).map { _ in Token() }
        self.tokens = made
        self.ids = made.map(ObjectIdentifier.init)
    }
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
        let first = Owners(1)
        let second = Owners(1)

        #expect(controller.park(keys: [.heavyTask], taskId: "a", owner: first.ids[0], resume: log.recorder(for: "a")) == .admitted)
        #expect(log.all.isEmpty)

        controller.release(taskId: "a", owner: first.ids[0])
        #expect(log.all.isEmpty)

        #expect(controller.park(keys: [.heavyTask], taskId: "b", owner: second.ids[0], resume: log.recorder(for: "b")) == .admitted)
    }

    @Test("wakes parked waiters in FIFO order")
    func fifoWakeOrder() {
        let controller = holdController()
        let log = ResumeLog()
        let owners = Owners(3)

        #expect(controller.park(keys: [.heavyTask], taskId: "a", owner: owners.ids[0], resume: log.recorder(for: "a")) == .admitted)
        #expect(controller.park(keys: [.heavyTask], taskId: "b", owner: owners.ids[1], resume: log.recorder(for: "b")) == .parked)
        #expect(controller.park(keys: [.heavyTask], taskId: "c", owner: owners.ids[2], resume: log.recorder(for: "c")) == .parked)

        controller.release(taskId: "a", owner: owners.ids[0])
        #expect(log.all.map { $0.0 } == ["b"])
        #expect(log.all.map { $0.1 } == [true])

        controller.release(taskId: "b", owner: owners.ids[1])
        #expect(log.all.map { $0.0 } == ["b", "c"])
    }

    @Test("cancelled waiter is skipped on wake")
    func cancelSkipsWaiter() {
        let controller = holdController()
        let log = ResumeLog()
        let owners = Owners(3)

        #expect(controller.park(keys: [.heavyTask], taskId: "a", owner: owners.ids[0], resume: log.recorder(for: "a")) == .admitted)
        #expect(controller.park(keys: [.heavyTask], taskId: "b", owner: owners.ids[1], resume: log.recorder(for: "b")) == .parked)
        #expect(controller.park(keys: [.heavyTask], taskId: "c", owner: owners.ids[2], resume: log.recorder(for: "c")) == .parked)

        controller.cancel(taskId: "b", owner: owners.ids[1])
        #expect(log.all.map { $0.0 } == ["b"])
        #expect(log.all.map { $0.1 } == [false])

        controller.release(taskId: "a", owner: owners.ids[0])
        #expect(log.all.map { $0.0 } == ["b", "c"])
        #expect(log.all.last?.1 == true)
    }

    @Test("cancel with unknown id or wrong owner is a no-op")
    func cancelMismatchNoops() {
        let controller = holdController()
        let log = ResumeLog()
        let owners = Owners(3)

        #expect(controller.park(keys: [.heavyTask], taskId: "a", owner: owners.ids[0], resume: log.recorder(for: "a")) == .admitted)
        #expect(controller.park(keys: [.heavyTask], taskId: "b", owner: owners.ids[1], resume: log.recorder(for: "b")) == .parked)

        controller.cancel(taskId: "missing", owner: owners.ids[1])
        controller.cancel(taskId: "b", owner: owners.ids[2])
        #expect(log.all.isEmpty)

        controller.release(taskId: "a", owner: owners.ids[0])
        #expect(log.all.map { $0.0 } == ["b"])
        #expect(log.all.map { $0.1 } == [true])
    }

    @Test("double acquire is rejected instead of absorbed")
    func doubleAcquireRejected() {
        let controller = holdController()
        let log = ResumeLog()
        let owners = Owners(3)

        #expect(controller.park(keys: [.heavyTask], taskId: "a", owner: owners.ids[0], resume: log.recorder(for: "a")) == .admitted)
        #expect(controller.park(keys: [.heavyTask], taskId: "a", owner: owners.ids[0], resume: log.recorder(for: "a2")) == .duplicate)
        #expect(log.all.isEmpty)

        controller.release(taskId: "a", owner: owners.ids[1])
        #expect(log.all.isEmpty)

        controller.release(taskId: "a", owner: owners.ids[0])
        #expect(controller.park(keys: [.heavyTask], taskId: "b", owner: owners.ids[2], resume: log.recorder(for: "b")) == .admitted)
    }

    @Test("double release wakes at most once")
    func doubleReleaseWakesOnce() {
        let controller = holdController()
        let log = ResumeLog()
        let owners = Owners(2)

        #expect(controller.park(keys: [.heavyTask], taskId: "a", owner: owners.ids[0], resume: log.recorder(for: "a")) == .admitted)
        #expect(controller.park(keys: [.heavyTask], taskId: "b", owner: owners.ids[1], resume: log.recorder(for: "b")) == .parked)

        controller.release(taskId: "a", owner: owners.ids[0])
        controller.release(taskId: "a", owner: owners.ids[0])
        #expect(log.all.map { $0.0 } == ["b"])

        controller.release(taskId: "b", owner: owners.ids[1])
        #expect(log.all.map { $0.0 } == ["b"])
    }

    @Test("same-id new owner retires the displaced waiter")
    func sameIdDisplacementRetiresOldWaiter() {
        let controller = holdController()
        let log = ResumeLog()
        let owners = Owners(3)

        #expect(controller.park(keys: [.heavyTask], taskId: "h", owner: owners.ids[0], resume: log.recorder(for: "h")) == .admitted)
        #expect(controller.park(keys: [.heavyTask], taskId: "x", owner: owners.ids[1], resume: log.recorder(for: "old")) == .parked)
        #expect(controller.park(keys: [.heavyTask], taskId: "x", owner: owners.ids[2], resume: log.recorder(for: "new")) == .parked)
        #expect(log.all.map { $0.0 } == ["old"])
        #expect(log.all.map { $0.1 } == [false])

        controller.release(taskId: "h", owner: owners.ids[0])
        #expect(log.all.map { $0.0 } == ["old", "new"])
        #expect(log.all.last?.1 == true)
    }

    @Test("acquire releases on scope exit through the shared release")
    func acquireScopedRelease() async {
        let controller = holdController()
        let owners = Owners(2)

        func scoped() async -> Int {
            guard await controller.acquire(keys: [.heavyTask], taskId: "a", owner: owners.ids[0]) else { return -1 }
            defer { controller.release(taskId: "a", owner: owners.ids[0]) }
            return 42
        }

        let value = await scoped()
        #expect(value == 42)

        let log = ResumeLog()
        #expect(controller.park(keys: [.heavyTask], taskId: "b", owner: owners.ids[1], resume: log.recorder(for: "b")) == .admitted)
    }

    @Test("cancelled acquire never admits")
    func cancelledAcquireNeverAdmits() async {
        let controller = holdController()
        let log = ResumeLog()
        let owners = Owners(2)
        #expect(controller.park(keys: [.heavyTask], taskId: "a", owner: owners.ids[0], resume: log.recorder(for: "a")) == .admitted)

        let waiter = Task {
            await controller.acquire(keys: [.heavyTask], taskId: "b", owner: owners.ids[1])
        }
        waiter.cancel()
        #expect(await waiter.value == false)
        #expect(log.all.isEmpty)

        controller.release(taskId: "a", owner: owners.ids[0])
        #expect(log.all.isEmpty)
    }
}
