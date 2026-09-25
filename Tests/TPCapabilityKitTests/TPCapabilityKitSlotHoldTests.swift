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

        release.finish()
        #expect(await holderTask.value)

        let bAdmitted = await controller.withHold(for: leaseB) { $0 }
        #expect(bAdmitted)
    }

    @Test("retire evicts stale waiter, self-retire no-ops")
    func retireEvictsStaleWaiter() async {
        let controller = holdController()
        let log = Probe()
        let holder = makeHoldLease(id: "h")
        let old = makeHoldLease(id: "x")
        let other = makeHoldLease(id: "y")
        let new = makeHoldLease(id: "x")
        let release = AsyncGate()
        let entered = AsyncGate()
        let oldParked = AsyncGate()
        let otherParked = AsyncGate()
        let newParked = AsyncGate()

        let holderTask = Task {
            await controller.withHold(for: holder) { _ in
                await log.append("holder")
                entered.signal()
                await release.wait()
            }
        }
        await entered.wait()

        let oldTask = Task {
            oldParked.signal()
            return await controller.withHold(for: old) { admitted in
                await log.append("old")
                return admitted
            }
        }
        let otherTask = Task {
            otherParked.signal()
            return await controller.withHold(for: other) { admitted in
                await log.append("other")
                return admitted
            }
        }
        await oldParked.wait()
        await otherParked.wait()
        for _ in 0..<1000 {
            await Task.yield()
        }

        controller.retire(taskId: "x", owner: ObjectIdentifier(new))
        let oldAdmitted = await oldTask.value
        #expect(!oldAdmitted)

        let newTask = Task {
            newParked.signal()
            return await controller.withHold(for: new) { admitted in
                await log.append("new")
                return admitted
            }
        }
        await newParked.wait()
        for _ in 0..<1000 {
            await Task.yield()
        }
        controller.retire(taskId: "x", owner: ObjectIdentifier(new))
        let stranger = makeHoldLease(id: "h")
        controller.retire(taskId: "h", owner: ObjectIdentifier(stranger))

        release.finish()
        let otherAdmitted = await otherTask.value
        let newAdmitted = await newTask.value
        await holderTask.value
        #expect(otherAdmitted)
        #expect(newAdmitted)

        #expect(await log.values == ["holder", "old", "other", "new"])
    }

}
