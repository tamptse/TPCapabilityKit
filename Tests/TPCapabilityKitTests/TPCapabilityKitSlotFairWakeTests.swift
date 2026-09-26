import Testing
import Foundation
@testable import TPCapabilityKit

private func fairWakeLease(id: String, caps: Set<Capability>) -> Lease {
    Lease(task: TaskDescriptor(id: id, requiredCapabilities: caps))
}

@Suite("Slot Fair Wake Tests")
struct SlotFairWakeTests {
    @Test("release admits first satisfiable waiter skipping blocked head")
    func releaseAdmitsFirstSatisfiable() async {
        let capA = Capability.custom("fairA_\(UUID().uuidString)")
        let capB = Capability.custom("fairB_\(UUID().uuidString)")
        let controller = ConcurrencyController(maxPerCapability: 1, maxGlobal: nil)
        let holderA = fairWakeLease(id: "holderA", caps: [capA])
        let holderB = fairWakeLease(id: "holderB", caps: [capB])
        let head = fairWakeLease(id: "head", caps: [capA])
        let follower = fairWakeLease(id: "follower", caps: [capB])
        let enteredA = AsyncGate()
        let enteredB = AsyncGate()
        let releaseA = AsyncGate()
        let releaseB = AsyncGate()
        let headParked = AsyncGate()
        let followerParked = AsyncGate()

        let holderTaskA = Task {
            await controller.withHold(for: holderA) { admitted in
                enteredA.signal()
                await releaseA.wait()
                return admitted
            }
        }
        await enteredA.wait()
        let holderTaskB = Task {
            await controller.withHold(for: holderB) { admitted in
                enteredB.signal()
                await releaseB.wait()
                return admitted
            }
        }
        await enteredB.wait()

        let headTask = Task {
            headParked.signal()
            return await controller.withHold(for: head) { $0 }
        }
        await headParked.wait()
        for _ in 0..<2000 {
            await Task.yield()
        }
        let followerTask = Task {
            followerParked.signal()
            return await controller.withHold(for: follower) { $0 }
        }
        await followerParked.wait()
        for _ in 0..<2000 {
            await Task.yield()
        }

        releaseB.finish()
        let followerAdmitted = await followerTask.value
        #expect(followerAdmitted)

        releaseA.finish()
        let headAdmitted = await headTask.value
        #expect(headAdmitted)
        #expect(await holderTaskA.value)
        #expect(await holderTaskB.value)
    }

    @Test("facade overtakes blocked head then head follows when demand frees")
    func facadeOvertakesBlockedHead() async {
        let capA = Capability.custom("holA_\(UUID().uuidString)")
        let capB = Capability.custom("holB_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap(
            [capA, capB],
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 1, maxGlobal: 10),
            prefix: "FairWakeHOL"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let order = Probe()
        let started = AsyncGate()
        let releaseA = AsyncGate()
        let releaseB = AsyncGate()
        let blockerDone = AsyncGate()
        let holderDone = AsyncGate()
        let followerDone = AsyncGate()
        let headDone = AsyncGate()

        let blockerA = TaskDescriptor(requiredCapabilities: [capA], timeout: 30.0)
        store.scheduleTask(blockerA, task: {
            started.signal()
            await releaseA.wait()
        }, completion: { _ in blockerDone.signal() })
        let holderB = TaskDescriptor(requiredCapabilities: [capB], timeout: 30.0)
        store.scheduleTask(holderB, task: {
            started.signal()
            await releaseB.wait()
        }, completion: { _ in holderDone.signal() })
        await started.wait()
        await started.wait()

        let head = TaskDescriptor(requiredCapabilities: [capA], timeout: 30.0)
        store.scheduleTask(head, task: {
            await order.append("head")
        }, completion: { _ in headDone.signal() })
        for _ in 0..<2000 {
            await Task.yield()
        }
        let follower = TaskDescriptor(requiredCapabilities: [capB], timeout: 30.0)
        store.scheduleTask(follower, task: {
            await order.append("follower")
        }, completion: { _ in followerDone.signal() })
        for _ in 0..<2000 {
            await Task.yield()
        }
        #expect(store.pendingTaskCount == 2)
        #expect(store.activeTaskCount == 2)

        releaseB.finish()
        await holderDone.wait()
        await followerDone.wait()
        #expect(await order.values == ["follower"])

        releaseA.finish()
        await blockerDone.wait()
        await headDone.wait()
        #expect(await order.values == ["follower", "head"])
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("homogeneous queue keeps FIFO order through the facade")
    func homogeneousFifoPreserved() async {
        let cap = Capability.custom("fifoSame_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap(
            [cap],
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 1, maxGlobal: 10),
            prefix: "FairWakeFIFO"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let order = Probe()
        let started = AsyncGate()
        let release = AsyncGate()
        let drained = AsyncGate()
        let completions = Probe()

        let holder = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(holder, task: {
            started.signal()
            await release.wait()
        }, completion: { _ in
            Task {
                await completions.inc()
                drained.signal()
            }
        })
        await started.wait()

        let first = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(first, task: {
            await order.append("first")
        }, completion: { _ in
            Task {
                await completions.inc()
                drained.signal()
            }
        })
        for _ in 0..<2000 {
            await Task.yield()
        }
        let second = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(second, task: {
            await order.append("second")
        }, completion: { _ in
            Task {
                await completions.inc()
                drained.signal()
            }
        })
        for _ in 0..<2000 {
            await Task.yield()
        }

        release.finish()
        await drained.waitUntil { await completions.count == 3 }

        #expect(await order.values == ["first", "second"])
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
