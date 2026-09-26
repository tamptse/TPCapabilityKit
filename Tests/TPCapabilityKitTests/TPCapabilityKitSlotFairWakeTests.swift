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

@Suite("Slot Drain Tests")
struct SlotDrainTests {
    @Test("one release admits all disjoint waiters concurrently")
    func drainAdmitsDisjointBatch() async {
        let capA = Capability.custom("drainA_\(UUID().uuidString)")
        let capB = Capability.custom("drainB_\(UUID().uuidString)")
        let controller = ConcurrencyController(maxPerCapability: 1, maxGlobal: nil)
        let holder = fairWakeLease(id: "holder", caps: [capA, capB])
        let waiterA = fairWakeLease(id: "waiterA", caps: [capA])
        let waiterB = fairWakeLease(id: "waiterB", caps: [capB])
        let enteredHolder = AsyncGate()
        let enteredA = AsyncGate()
        let enteredB = AsyncGate()
        let releaseHolder = AsyncGate()
        let releaseBatch = AsyncGate()
        let parkedA = AsyncGate()
        let parkedB = AsyncGate()
        let probe = Probe()

        let holderTask = Task {
            await controller.withHold(for: holder) { admitted in
                enteredHolder.signal()
                await releaseHolder.wait()
                return admitted
            }
        }
        await enteredHolder.wait()

        let taskA = Task {
            parkedA.signal()
            return await controller.withHold(for: waiterA) { admitted in
                await probe.enter()
                enteredA.signal()
                await releaseBatch.wait()
                await probe.exit()
                return admitted
            }
        }
        await parkedA.wait()
        for _ in 0..<2000 {
            await Task.yield()
        }
        let taskB = Task {
            parkedB.signal()
            return await controller.withHold(for: waiterB) { admitted in
                await probe.enter()
                enteredB.signal()
                await releaseBatch.wait()
                await probe.exit()
                return admitted
            }
        }
        await parkedB.wait()
        for _ in 0..<2000 {
            await Task.yield()
        }

        releaseHolder.finish()
        await enteredA.wait()
        await enteredB.wait()
        #expect(await probe.maxSeen == 2)

        releaseBatch.finish()
        #expect(await taskA.value)
        #expect(await taskB.value)
        #expect(await holderTask.value)
    }

    @Test("facade drains disjoint demands in one release")
    func facadeDrainsDisjointDemands() async {
        let capA = Capability.custom("facDrainA_\(UUID().uuidString)")
        let capB = Capability.custom("facDrainB_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap(
            [capA, capB],
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 1, maxGlobal: nil),
            prefix: "FairWakeDrain"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let probe = Probe()
        let started = AsyncGate()
        let enteredA = AsyncGate()
        let enteredB = AsyncGate()
        let releaseBlocker = AsyncGate()
        let releaseBatch = AsyncGate()
        let blockerDone = AsyncGate()
        let drained = AsyncGate()
        let completions = Probe()

        let blocker = TaskDescriptor(requiredCapabilities: [capA, capB], timeout: 30.0)
        store.scheduleTask(blocker, task: {
            started.signal()
            await releaseBlocker.wait()
        }, completion: { _ in blockerDone.signal() })
        await started.wait()

        let waiterA = TaskDescriptor(requiredCapabilities: [capA], timeout: 30.0)
        store.scheduleTask(waiterA, task: {
            await probe.enter()
            enteredA.signal()
            await releaseBatch.wait()
            await probe.exit()
        }, completion: { _ in
            Task {
                await completions.inc()
                drained.signal()
            }
        })
        for _ in 0..<2000 {
            await Task.yield()
        }
        let waiterB = TaskDescriptor(requiredCapabilities: [capB], timeout: 30.0)
        store.scheduleTask(waiterB, task: {
            await probe.enter()
            enteredB.signal()
            await releaseBatch.wait()
            await probe.exit()
        }, completion: { _ in
            Task {
                await completions.inc()
                drained.signal()
            }
        })
        for _ in 0..<2000 {
            await Task.yield()
        }
        #expect(store.pendingTaskCount == 2)
        #expect(store.activeTaskCount == 1)

        releaseBlocker.finish()
        await blockerDone.wait()
        await enteredA.wait()
        await enteredB.wait()
        #expect(await probe.maxSeen == 2)

        releaseBatch.finish()
        await drained.waitUntil { await completions.count == 2 }
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("global budget admits at most the freed capacity")
    func globalBudgetBoundsBatch() async {
        let capA = Capability.custom("budgetA_\(UUID().uuidString)")
        let capB = Capability.custom("budgetB_\(UUID().uuidString)")
        let capC = Capability.custom("budgetC_\(UUID().uuidString)")
        let controller = ConcurrencyController(maxPerCapability: 10, maxGlobal: 1)
        let holder = fairWakeLease(id: "holder", caps: [capA])
        let first = fairWakeLease(id: "first", caps: [capB])
        let second = fairWakeLease(id: "second", caps: [capC])
        let enteredHolder = AsyncGate()
        let enteredFirst = AsyncGate()
        let releaseHolder = AsyncGate()
        let releaseFirst = AsyncGate()
        let parkedFirst = AsyncGate()
        let parkedSecond = AsyncGate()
        let probe = Probe()

        let holderTask = Task {
            await controller.withHold(for: holder) { admitted in
                enteredHolder.signal()
                await releaseHolder.wait()
                return admitted
            }
        }
        await enteredHolder.wait()

        let firstTask = Task {
            parkedFirst.signal()
            return await controller.withHold(for: first) { admitted in
                enteredFirst.signal()
                await releaseFirst.wait()
                return admitted
            }
        }
        await parkedFirst.wait()
        for _ in 0..<2000 {
            await Task.yield()
        }
        let secondTask = Task {
            parkedSecond.signal()
            return await controller.withHold(for: second) { admitted in
                await probe.inc()
                return admitted
            }
        }
        await parkedSecond.wait()
        for _ in 0..<2000 {
            await Task.yield()
        }

        releaseHolder.finish()
        await enteredFirst.wait()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(await probe.count == 0)

        releaseFirst.finish()
        #expect(await firstTask.value)
        #expect(await secondTask.value)
        #expect(await holderTask.value)
        #expect(await probe.count == 1)
    }

    @Test("cancelled head cascades to the fitting follower")
    func cancelledHeadCascades() async {
        let capA = Capability.custom("cascA_\(UUID().uuidString)")
        let capB = Capability.custom("cascB_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap(
            [capA, capB],
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 1, maxGlobal: 10),
            prefix: "FairWakeCascade"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let order = Probe()
        let started = AsyncGate()
        let releaseA = AsyncGate()
        let blockerDone = AsyncGate()
        let followerDone = AsyncGate()

        let blockerA = TaskDescriptor(requiredCapabilities: [capA], timeout: 30.0)
        store.scheduleTask(blockerA, task: {
            started.signal()
            await releaseA.wait()
        }, completion: { _ in blockerDone.signal() })
        await started.wait()

        let head = TaskDescriptor(requiredCapabilities: [capA], timeout: 30.0)
        let headLease = store.scheduleTask(head, task: {
            await order.append("head")
        }, completion: { _ in })
        for _ in 0..<2000 {
            await Task.yield()
        }
        store.cancelTask(taskId: head.id)
        let follower = TaskDescriptor(requiredCapabilities: [capB], timeout: 30.0)
        store.scheduleTask(follower, task: {
            await order.append("follower")
        }, completion: { _ in followerDone.signal() })
        for _ in 0..<2000 {
            await Task.yield()
        }

        releaseA.finish()
        await blockerDone.wait()
        await followerDone.wait()
        #expect(await order.values == ["follower"])
        #expect(headLease.state == .expired)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("newcomer with free demand still parks behind queued waiters")
    func newcomerParksBehindQueue() async {
        let capA = Capability.custom("parkA_\(UUID().uuidString)")
        let capB = Capability.custom("parkB_\(UUID().uuidString)")
        let controller = ConcurrencyController(maxPerCapability: 1, maxGlobal: nil)
        let holder = fairWakeLease(id: "holder", caps: [capA])
        let head = fairWakeLease(id: "head", caps: [capA])
        let newcomer = fairWakeLease(id: "newcomer", caps: [capB])
        let enteredHolder = AsyncGate()
        let releaseHolder = AsyncGate()
        let parkedHead = AsyncGate()
        let parkedNewcomer = AsyncGate()
        let probe = Probe()

        let holderTask = Task {
            await controller.withHold(for: holder) { admitted in
                enteredHolder.signal()
                await releaseHolder.wait()
                return admitted
            }
        }
        await enteredHolder.wait()

        let headTask = Task {
            parkedHead.signal()
            return await controller.withHold(for: head) { $0 }
        }
        await parkedHead.wait()
        for _ in 0..<2000 {
            await Task.yield()
        }
        let newcomerTask = Task {
            parkedNewcomer.signal()
            return await controller.withHold(for: newcomer) { admitted in
                await probe.inc()
                return admitted
            }
        }
        await parkedNewcomer.wait()
        for _ in 0..<2000 {
            await Task.yield()
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(await probe.count == 0)

        releaseHolder.finish()
        #expect(await headTask.value)
        #expect(await newcomerTask.value)
        #expect(await holderTask.value)
        #expect(await probe.count == 1)
    }
}
