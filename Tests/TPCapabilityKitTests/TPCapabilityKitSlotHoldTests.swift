import Testing
import Foundation
@testable import TPCapabilityKit

private func makeHoldLease(id: String) -> Lease {
    Lease(task: TaskDescriptor(id: id, requiredCapabilities: [.heavyTask]))
}

private func holdController() -> ConcurrencyController {
    ConcurrencyController(maxPerCapability: 1, maxGlobal: 1)
}

@Suite("Slot Hold Tests")
struct SlotHoldTests {
    @Test("double acquire is rejected instead of absorbed")
    func doubleAcquireRejected() async {
        let controller = holdController()
        let holder = makeHoldLease(id: "a")
        let impostorA = makeHoldLease(id: "a")
        let leaseB = makeHoldLease(id: "b")
        let release = AsyncGate()
        let entered = AsyncGate()

        let holderTask = Task {
            await controller.withHold(for: holder) { admitted in
                entered.signal()
                await release.wait()
                return admitted
            }
        }
        await entered.wait()

        let duplicateAdmitted = await controller.withHold(for: holder) { $0 }
        #expect(!duplicateAdmitted)

        let impostorAdmitted = await controller.withHold(for: impostorA) { $0 }
        #expect(!impostorAdmitted)

        release.finish()
        #expect(await holderTask.value)

        let bAdmitted = await controller.withHold(for: leaseB) { $0 }
        #expect(bAdmitted)
    }

    @Test("same-id new owner retires the displaced waiter")
    func sameIdDisplacementRetiresOldWaiter() async {
        let controller = holdController()
        let log = Probe()
        let holder = makeHoldLease(id: "h")
        let old = makeHoldLease(id: "x")
        let new = makeHoldLease(id: "x")
        let release = AsyncGate()
        let entered = AsyncGate()
        let willPark = AsyncGate()

        let holderTask = Task {
            await controller.withHold(for: holder) { admitted in
                await log.append("holder")
                entered.signal()
                await release.wait()
            }
        }
        await entered.wait()

        let oldTask = Task {
            willPark.signal()
            return await controller.withHold(for: old) { admitted in
                await log.append("old")
                return admitted
            }
        }
        await willPark.wait()
        for _ in 0..<1000 {
            await Task.yield()
        }
        let newTask = Task {
            return await controller.withHold(for: new) { admitted in
                await log.append("new")
                return admitted
            }
        }
        let oldAdmitted = await oldTask.value
        #expect(!oldAdmitted)

        release.finish()
        let newAdmitted = await newTask.value
        await holderTask.value
        #expect(newAdmitted)

        #expect(await log.values == ["holder", "old", "new"])
    }

}
