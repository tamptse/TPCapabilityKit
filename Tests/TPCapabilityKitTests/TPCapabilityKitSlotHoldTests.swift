import Testing
import Foundation
@testable import TPCapabilityKit

private func makeHoldLease(id: String) -> Lease {
    Lease(task: TaskDescriptor(id: id, requiredCapabilities: [.heavyTask]))
}

private func holdController() -> ConcurrencyController {
    ConcurrencyController(maxPerCapability: 1, maxGlobal: 1)
}

private actor OrderLog {
    private var values: [(String, Bool)] = []
    func append(_ id: String, _ admitted: Bool) { values.append((id, admitted)) }
    var all: [(String, Bool)] { values }
    var ids: [String] { values.map { $0.0 } }
}

@Suite("Slot Hold Tests")
struct SlotHoldTests {
    @Test("admits inline when free and frees on scope exit")
    func admitAndRelease() async {
        let controller = holdController()
        let first = makeHoldLease(id: "a")
        let second = makeHoldLease(id: "b")

        let firstAdmitted = await controller.withHold(for: first) { $0 }
        #expect(firstAdmitted)

        let secondAdmitted = await controller.withHold(for: second) { $0 }
        #expect(secondAdmitted)
    }

    @Test("wakes parked waiters in FIFO order")
    func fifoWakeOrder() async {
        let controller = holdController()
        let log = OrderLog()
        let holder = makeHoldLease(id: "a")
        let leaseB = makeHoldLease(id: "b")
        let leaseC = makeHoldLease(id: "c")
        let release = AsyncStream<Void>.makeStream()
        let entered = AsyncStream<Void>.makeStream()

        let holderTask = Task {
            await controller.withHold(for: holder) { admitted in
                await log.append("holder", admitted)
                entered.continuation.yield()
                for await _ in release.stream { break }
            }
        }
        for await _ in entered.stream { break }

        let taskB = Task {
            await controller.withHold(for: leaseB) { admitted in
                await log.append("b", admitted)
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let taskC = Task {
            await controller.withHold(for: leaseC) { admitted in
                await log.append("c", admitted)
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        release.continuation.finish()
        await holderTask.value
        await taskB.value
        await taskC.value

        let ids = await log.ids
        #expect(ids == ["holder", "b", "c"])
        let all = await log.all
        #expect(all.allSatisfy { $0.1 })
    }

    @Test("cancelled waiter is skipped on wake")
    func cancelSkipsWaiter() async {
        let controller = holdController()
        let log = OrderLog()
        let holder = makeHoldLease(id: "a")
        let leaseB = makeHoldLease(id: "b")
        let leaseC = makeHoldLease(id: "c")
        let release = AsyncStream<Void>.makeStream()
        let entered = AsyncStream<Void>.makeStream()

        let holderTask = Task {
            await controller.withHold(for: holder) { admitted in
                await log.append("holder", admitted)
                entered.continuation.yield()
                for await _ in release.stream { break }
            }
        }
        for await _ in entered.stream { break }

        let taskB = Task {
            await controller.withHold(for: leaseB) { admitted in
                await log.append("b", admitted)
                return admitted
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let taskC = Task {
            await controller.withHold(for: leaseC) { admitted in
                await log.append("c", admitted)
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        taskB.cancel()
        let bAdmitted = await taskB.value
        #expect(!bAdmitted)

        release.continuation.finish()
        await holderTask.value
        await taskC.value

        let ids = await log.ids
        #expect(ids == ["holder", "b", "c"])
        let all = await log.all
        #expect(all[1].1 == false)
        #expect(all[2].1 == true)
    }

    @Test("cancel with unknown id or wrong owner is a no-op")
    func cancelMismatchNoops() async {
        let controller = holdController()
        let log = OrderLog()
        let holder = makeHoldLease(id: "a")
        let leaseB = makeHoldLease(id: "b")
        let unrelated = makeHoldLease(id: "unrelated")
        let release = AsyncStream<Void>.makeStream()
        let entered = AsyncStream<Void>.makeStream()

        let holderTask = Task {
            await controller.withHold(for: holder) { admitted in
                await log.append("holder", admitted)
                entered.continuation.yield()
                for await _ in release.stream { break }
            }
        }
        for await _ in entered.stream { break }

        let taskB = Task {
            await controller.withHold(for: leaseB) { admitted in
                await log.append("b", admitted)
                return admitted
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let unrelatedTask = Task {
            await controller.withHold(for: unrelated) { admitted in
                await log.append("unrelated", admitted)
                return admitted
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        unrelatedTask.cancel()
        let unrelatedAdmitted = await unrelatedTask.value
        #expect(!unrelatedAdmitted)

        release.continuation.finish()
        let bAdmitted = await taskB.value
        await holderTask.value
        #expect(bAdmitted)

        let ids = await log.ids
        #expect(ids == ["holder", "unrelated", "b"])
    }

    @Test("double acquire is rejected instead of absorbed")
    func doubleAcquireRejected() async {
        let controller = holdController()
        let holder = makeHoldLease(id: "a")
        let impostorA = makeHoldLease(id: "a")
        let leaseB = makeHoldLease(id: "b")
        let release = AsyncStream<Void>.makeStream()
        let entered = AsyncStream<Void>.makeStream()

        let holderTask = Task {
            await controller.withHold(for: holder) { admitted in
                entered.continuation.yield()
                for await _ in release.stream { break }
                return admitted
            }
        }
        for await _ in entered.stream { break }

        let duplicateAdmitted = await controller.withHold(for: holder) { $0 }
        #expect(!duplicateAdmitted)

        let impostorAdmitted = await controller.withHold(for: impostorA) { $0 }
        #expect(!impostorAdmitted)

        release.continuation.finish()
        #expect(await holderTask.value)

        let bAdmitted = await controller.withHold(for: leaseB) { $0 }
        #expect(bAdmitted)
    }

    @Test("scope exit wakes at most once")
    func doubleReleaseWakesOnce() async {
        let controller = holdController()
        let log = OrderLog()
        let holder = makeHoldLease(id: "a")
        let leaseB = makeHoldLease(id: "b")
        let release = AsyncStream<Void>.makeStream()
        let entered = AsyncStream<Void>.makeStream()

        let holderTask = Task {
            await controller.withHold(for: holder) { admitted in
                await log.append("holder", admitted)
                entered.continuation.yield()
                for await _ in release.stream { break }
            }
        }
        for await _ in entered.stream { break }

        let taskB = Task {
            await controller.withHold(for: leaseB) { admitted in
                await log.append("b", admitted)
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        release.continuation.finish()
        await holderTask.value
        await taskB.value

        let ids = await log.ids
        #expect(ids == ["holder", "b"])

        let leaseC = makeHoldLease(id: "c")
        let cAdmitted = await controller.withHold(for: leaseC) { $0 }
        #expect(cAdmitted)
        let idsAfter = await log.ids
        #expect(idsAfter == ["holder", "b"])
    }

    @Test("same-id new owner retires the displaced waiter")
    func sameIdDisplacementRetiresOldWaiter() async {
        let controller = holdController()
        let log = OrderLog()
        let holder = makeHoldLease(id: "h")
        let old = makeHoldLease(id: "x")
        let new = makeHoldLease(id: "x")
        let release = AsyncStream<Void>.makeStream()
        let entered = AsyncStream<Void>.makeStream()

        let holderTask = Task {
            await controller.withHold(for: holder) { admitted in
                await log.append("holder", admitted)
                entered.continuation.yield()
                for await _ in release.stream { break }
            }
        }
        for await _ in entered.stream { break }

        let oldTask = Task {
            await controller.withHold(for: old) { admitted in
                await log.append("old", admitted)
                return admitted
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let newTask = Task {
            await controller.withHold(for: new) { admitted in
                await log.append("new", admitted)
                return admitted
            }
        }
        let oldAdmitted = await oldTask.value
        #expect(!oldAdmitted)

        release.continuation.finish()
        let newAdmitted = await newTask.value
        await holderTask.value
        #expect(newAdmitted)

        let ids = await log.ids
        #expect(ids == ["holder", "old", "new"])
    }

    @Test("withHold releases on scope exit")
    func acquireScopedRelease() async {
        let controller = holdController()
        let leaseA = makeHoldLease(id: "a")
        let leaseB = makeHoldLease(id: "b")

        func scoped() async -> Int {
            await controller.withHold(for: leaseA) { admitted in
                guard admitted else { return -1 }
                return 42
            }
        }

        let value = await scoped()
        #expect(value == 42)

        let bAdmitted = await controller.withHold(for: leaseB) { $0 }
        #expect(bAdmitted)
    }

    @Test("cancelled acquire never admits")
    func cancelledAcquireNeverAdmits() async {
        let controller = holdController()
        let holder = makeHoldLease(id: "a")
        let leaseB = makeHoldLease(id: "b")
        let release = AsyncStream<Void>.makeStream()
        let entered = AsyncStream<Void>.makeStream()

        let holderTask = Task {
            await controller.withHold(for: holder) { admitted in
                entered.continuation.yield()
                for await _ in release.stream { break }
                return admitted
            }
        }
        for await _ in entered.stream { break }

        let waiter = Task {
            await controller.withHold(for: leaseB) { $0 }
        }
        waiter.cancel()
        #expect(await waiter.value == false)

        release.continuation.finish()
        await holderTask.value

        let bAdmitted = await controller.withHold(for: leaseB) { $0 }
        #expect(bAdmitted)
    }
}
