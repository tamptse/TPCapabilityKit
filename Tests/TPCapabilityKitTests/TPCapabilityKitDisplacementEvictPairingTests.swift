import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Displacement Evict Pairing Pins")
struct DisplacementEvictPairingTests {
    @Test("displacement drains stale slot waiter and newcomer admits and completes")
    func displacementDrainsStaleWaiter() async {
        let (store, pluginId) = makeStoreWithCap(
            [.heavyTask],
            configuration: .init(defaultTimeout: 10.0, maxPerCapability: 10, maxGlobal: 1),
            prefix: "s5evict"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        let holderDone = AsyncGate()
        let holder = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 10.0)
        store.scheduleTask(holder, task: {
            started.signal()
            await release.wait()
        }, completion: { _ in holderDone.signal() })
        await started.wait()
        #expect(store.activeTaskCount == 1)

        let id = "s5-evict_\(UUID().uuidString)"
        let executions = Probe()
        actor Completions {
            var oldCalls = 0
            var oldState: Lease.State?
            var newCalls = 0
            var newState: Lease.State?
            func recordOld(_ lease: Lease) {
                oldCalls += 1
                oldState = lease.state
            }
            func recordNew(_ lease: Lease) {
                newCalls += 1
                newState = lease.state
            }
        }
        let completions = Completions()
        let oldDone = AsyncGate()
        let newDone = AsyncGate()

        store.scheduleTask(
            TaskDescriptor(id: id, requiredCapabilities: [.heavyTask], timeout: 10.0),
            task: { await executions.append("old") },
            completion: { finished in
                Task {
                    await completions.recordOld(finished)
                    oldDone.signal()
                }
            }
        )
        for _ in 0..<100 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)

        let newLease = store.scheduleTask(
            TaskDescriptor(id: id, requiredCapabilities: [.heavyTask], timeout: 10.0),
            task: { await executions.append("new") },
            completion: { finished in
                Task {
                    await completions.recordNew(finished)
                    newDone.signal()
                }
            }
        )

        await oldDone.wait()
        #expect(await completions.oldCalls == 1)
        #expect(await completions.oldState == .expired)
        #expect(!newLease.isTerminal)
        #expect(store.pendingTaskCount == 1)

        release.finish()
        await newDone.wait()
        await holderDone.wait()

        #expect(await completions.newCalls == 1)
        #expect(await completions.newState == .completed)
        #expect(await executions.values.filter { $0 == "old" }.isEmpty)
        #expect(await executions.values.filter { $0 == "new" }.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("displaced parked waiter cancelled once and never runs")
    func displacedParkWaiterCancelledOnce() async {
        let store = DynamicStore()
        store.schedulingGenerations.enableDeterministicTime(owner: store)
        let missing = Capability.custom("s5-park_\(UUID().uuidString)")
        let id = "s5-park_\(UUID().uuidString)"
        let pluginId = "s5-park_\(UUID().uuidString)"

        let executions = Probe()
        let oldProbe = Probe()
        let oldDone = AsyncGate()
        let old = TaskDescriptor(id: id, requiredCapabilities: [missing], timeout: 30.0)
        let oldLease = store.scheduleTask(old, task: {
            await executions.append("old")
        }, completion: { finished in
            Task {
                await oldProbe.record(finished)
                oldDone.signal()
            }
        })

        await store.schedulingGenerations.waitForDeterministicWaiters(count: 1)
        #expect(!oldLease.isTerminal)
        #expect(store.pendingTaskCount == 1)

        let newProbe = Probe()
        let newDone = AsyncGate()
        let new = TaskDescriptor(id: id, requiredCapabilities: [missing], timeout: 30.0)
        let newLease = store.scheduleTask(new, task: {
            await executions.append("new")
        }, completion: { finished in
            Task {
                await newProbe.record(finished)
                newDone.signal()
            }
        })

        await oldDone.wait()
        #expect(oldLease.state == .expired)
        #expect(await oldProbe.count == 1)
        #expect(!newLease.isTerminal)
        #expect(store.pendingTaskCount == 1)

        store.registerCapability(for: pluginId, capabilities: [missing])
        defer { store.unregisterCapability(for: pluginId) }
        await newDone.wait()

        #expect(newLease.state == .completed)
        #expect(await newProbe.count == 1)
        #expect(await oldProbe.count == 1)
        #expect(await executions.values.filter { $0 == "old" }.isEmpty)
        #expect(await executions.values.filter { $0 == "new" }.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("enqueue without displacement evicts nothing and preserves FIFO with counts")
    func noDisplacementEvictsNothing() async {
        let (store, pluginId) = makeStoreWithCap(
            [.heavyTask],
            configuration: .init(defaultTimeout: 10.0, maxPerCapability: 10, maxGlobal: 1),
            prefix: "s5nostray"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        let order = Probe()
        let holder = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 10.0)
        let holderDone = AsyncGate()
        store.scheduleTask(holder, task: {
            started.signal()
            await release.wait()
            await order.append("holder")
        }, completion: { _ in holderDone.signal() })
        await started.wait()
        #expect(store.activeTaskCount == 1)

        let doneA = AsyncGate()
        let doneB = AsyncGate()
        let doneC = AsyncGate()
        store.scheduleTask(
            TaskDescriptor(id: "s5-fresh-a_\(UUID().uuidString)", requiredCapabilities: [.heavyTask], timeout: 10.0),
            task: { await order.append("a") },
            completion: { _ in doneA.signal() }
        )
        for _ in 0..<100 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 30_000_000)
        store.scheduleTask(
            TaskDescriptor(id: "s5-fresh-b_\(UUID().uuidString)", requiredCapabilities: [.heavyTask], timeout: 10.0),
            task: { await order.append("b") },
            completion: { _ in doneB.signal() }
        )
        for _ in 0..<100 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 30_000_000)
        store.scheduleTask(
            TaskDescriptor(id: "s5-fresh-c_\(UUID().uuidString)", requiredCapabilities: [.heavyTask], timeout: 10.0),
            task: { await order.append("c") },
            completion: { _ in doneC.signal() }
        )
        for _ in 0..<100 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 30_000_000)

        #expect(store.pendingTaskCount == 3)
        #expect(store.activeTaskCount == 1)

        release.finish()
        await doneA.wait()
        await doneB.wait()
        await doneC.wait()
        await holderDone.wait()

        #expect(await order.values == ["holder", "a", "b", "c"])
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)

        let seqStore = DynamicStore()
        seqStore.schedulingGenerations.enableDeterministicTime(owner: seqStore)
        let missing = Capability.custom("s5-seq_\(UUID().uuidString)")
        let seqId = "s5-seq_\(UUID().uuidString)"
        let firstProbe = Probe()
        let firstDone = AsyncGate()
        let firstLease = seqStore.scheduleTask(
            TaskDescriptor(id: seqId, requiredCapabilities: [missing], timeout: 30.0),
            task: {},
            completion: { finished in
                Task {
                    await firstProbe.record(finished)
                    firstDone.signal()
                }
            }
        )
        await seqStore.schedulingGenerations.waitForDeterministicWaiters(count: 1)
        seqStore.cancelTask(taskId: seqId)
        await firstDone.wait()
        #expect(firstLease.state == .expired)
        #expect(await firstProbe.count == 1)
        #expect(seqStore.pendingTaskCount == 0)

        let secondProbe = Probe()
        let secondDone = AsyncGate()
        let secondLease = seqStore.scheduleTask(
            TaskDescriptor(id: seqId, requiredCapabilities: [missing], timeout: 30.0),
            task: {},
            completion: { finished in
                Task {
                    await secondProbe.record(finished)
                    secondDone.signal()
                }
            }
        )
        await seqStore.schedulingGenerations.waitForDeterministicWaiters(count: 1)
        #expect(!secondLease.isTerminal)
        #expect(seqStore.pendingTaskCount == 1)

        seqStore.cancelTask(taskId: seqId)
        await secondDone.wait()
        #expect(secondLease.state == .expired)
        #expect(await secondProbe.count == 1)
        #expect(seqStore.pendingTaskCount == 0)
        #expect(seqStore.activeTaskCount == 0)
    }
}
