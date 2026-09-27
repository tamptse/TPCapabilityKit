import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("D3 Slot Wake On Limit Change")
struct TPCapabilityKitD3SlotWakeTests {
    @Test("raise wakes fitting follower past blocked head in order")
    func raiseWakesFittingFollowerPastBlockedHead() async {
        let capA = Capability.custom("d3RaiseA_\(UUID().uuidString)")
        let capB = Capability.custom("d3RaiseB_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap(
            [capA, capB],
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 1, maxGlobal: 1),
            prefix: "D3Raise"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let order = Probe()
        let started = AsyncGate()
        let releaseA = AsyncGate()
        let blockerDone = AsyncGate()
        let followerDone = AsyncGate()
        let headDone = AsyncGate()

        let blocker = TaskDescriptor(requiredCapabilities: [capA], timeout: 30.0)
        store.scheduleTask(blocker, task: {
            started.signal()
            await releaseA.wait()
        }, completion: { _ in blockerDone.signal() })
        await started.wait()

        let head = TaskDescriptor(requiredCapabilities: [capA, capB], timeout: 30.0)
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
        #expect(store.activeTaskCount == 1)

        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 1, maxGlobal: 2))
        await followerDone.wait()
        #expect(await order.values == ["follower"])
        #expect(store.pendingTaskCount == 1)

        releaseA.finish()
        await blockerDone.wait()
        await headDone.wait()
        #expect(await order.values == ["follower", "head"])
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("raise wakes homogeneous queue in FIFO order")
    func raiseWakesHomogeneousQueueInOrder() async {
        let cap = Capability.custom("d3Fifo_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap(
            [cap],
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 1, maxGlobal: 10),
            prefix: "D3Fifo"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let order = Probe()
        let started = AsyncGate()
        let release = AsyncGate()
        let holderDone = AsyncGate()
        let drained = AsyncGate()
        let completions = Probe()

        let holder = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(holder, task: {
            started.signal()
            await release.wait()
        }, completion: { _ in holderDone.signal() })
        await started.wait()

        for name in ["first", "second"] {
            let descriptor = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
            store.scheduleTask(descriptor, task: {
                await order.append(name)
            }, completion: { _ in
                Task {
                    await completions.inc()
                    drained.signal()
                }
            })
            for _ in 0..<2000 {
                await Task.yield()
            }
        }
        #expect(store.pendingTaskCount == 2)

        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 3, maxGlobal: 10))
        await drained.waitUntil { await completions.count == 2 }
        #expect(await order.values == ["first", "second"])
        #expect(store.pendingTaskCount == 0)

        release.finish()
        await holderDone.wait()
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("lower admits nobody and never overshoots the tightened bound")
    func lowerAdmitsNobodyAndNeverOvershoots() async {
        let capA = Capability.custom("d3LowerA_\(UUID().uuidString)")
        let capB = Capability.custom("d3LowerB_\(UUID().uuidString)")
        let capC = Capability.custom("d3LowerC_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap(
            [capA, capB, capC],
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 3),
            prefix: "D3Lower"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let releases = [AsyncGate(), AsyncGate(), AsyncGate()]
        let holderDones = [AsyncGate(), AsyncGate(), AsyncGate()]
        let waiterProbe = Probe()
        let waiterDrained = AsyncGate()
        let waiterCompletions = Probe()

        let holderCaps = [capA, capB, capC]
        for index in 0..<3 {
            let descriptor = TaskDescriptor(requiredCapabilities: [holderCaps[index]], timeout: 30.0)
            store.scheduleTask(descriptor, task: {
                started.signal()
                await releases[index].wait()
            }, completion: { _ in holderDones[index].signal() })
        }
        await started.wait()
        await started.wait()
        await started.wait()

        for waiterCap in [capA, capB] {
            let descriptor = TaskDescriptor(requiredCapabilities: [waiterCap], timeout: 30.0)
            store.scheduleTask(descriptor, task: {
                await waiterProbe.enter()
                await Task.yield()
                await waiterProbe.exit()
            }, completion: { _ in
                Task {
                    await waiterCompletions.inc()
                    waiterDrained.signal()
                }
            })
            for _ in 0..<2000 {
                await Task.yield()
            }
        }
        #expect(store.pendingTaskCount == 2)

        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1))
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(await waiterCompletions.count == 0)
        #expect(store.pendingTaskCount == 2)

        releases[0].finish()
        await holderDones[0].wait()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(await waiterCompletions.count == 0)

        releases[1].finish()
        await holderDones[1].wait()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(await waiterCompletions.count == 0)

        releases[2].finish()
        await holderDones[2].wait()
        await waiterDrained.waitUntil { await waiterCompletions.count == 2 }
        #expect(await waiterProbe.maxSeen <= 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("mixed change admits only the new headroom")
    func mixedChangeAdmitsOnlyNewHeadroom() async {
        let capA = Capability.custom("d3MixedA_\(UUID().uuidString)")
        let capB = Capability.custom("d3MixedB_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap(
            [capA, capB],
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 1, maxGlobal: 3),
            prefix: "D3Mixed"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let order = Probe()
        let started = AsyncGate()
        let release = AsyncGate()
        let blockerDone = AsyncGate()
        let headDone = AsyncGate()
        let followerDone = AsyncGate()

        let blocker = TaskDescriptor(requiredCapabilities: [capA], timeout: 30.0)
        store.scheduleTask(blocker, task: {
            started.signal()
            await release.wait()
        }, completion: { _ in blockerDone.signal() })
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

        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 2, maxGlobal: 2))
        await headDone.wait()
        #expect(await order.values == ["head"])
        #expect(store.pendingTaskCount == 1)

        release.finish()
        await blockerDone.wait()
        await followerDone.wait()
        #expect(await order.values == ["head", "follower"])
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("lower per-capability cap admits nobody")
    func lowerPerCapabilityAdmitsNobody() async {
        let cap = Capability.custom("d3LowerCap_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap(
            [cap],
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 2, maxGlobal: 10),
            prefix: "D3LowerCap"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let releases = [AsyncGate(), AsyncGate()]
        let holderDones = [AsyncGate(), AsyncGate()]
        let executions = Probe()
        let waiterDone = AsyncGate()

        for index in 0..<2 {
            let descriptor = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
            store.scheduleTask(descriptor, task: {
                started.signal()
                await releases[index].wait()
            }, completion: { _ in holderDones[index].signal() })
        }
        await started.wait()
        await started.wait()

        let waiter = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(waiter, task: {
            await executions.inc()
        }, completion: { _ in waiterDone.signal() })
        for _ in 0..<2000 {
            await Task.yield()
        }
        #expect(store.pendingTaskCount == 1)

        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 1, maxGlobal: 10))
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(await executions.count == 0)
        #expect(store.pendingTaskCount == 1)

        releases[0].finish()
        releases[1].finish()
        await holderDones[0].wait()
        await holderDones[1].wait()
        await waiterDone.wait()
        #expect(await executions.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("newcomer still parks behind queued waiters on limit wake")
    func newcomerStillParksBehindQueueOnLimitWake() async {
        let capA = Capability.custom("d3ParkA_\(UUID().uuidString)")
        let capB = Capability.custom("d3ParkB_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap(
            [capA, capB],
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 1, maxGlobal: nil),
            prefix: "D3Park"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let order = Probe()
        let started = AsyncGate()
        let release = AsyncGate()
        let holderDone = AsyncGate()
        let headDone = AsyncGate()
        let newcomerDone = AsyncGate()

        let holder = TaskDescriptor(requiredCapabilities: [capA], timeout: 30.0)
        store.scheduleTask(holder, task: {
            started.signal()
            await release.wait()
        }, completion: { _ in holderDone.signal() })
        await started.wait()

        let head = TaskDescriptor(requiredCapabilities: [capA], timeout: 30.0)
        store.scheduleTask(head, task: {
            await order.append("head")
        }, completion: { _ in headDone.signal() })
        for _ in 0..<2000 {
            await Task.yield()
        }
        let newcomer = TaskDescriptor(requiredCapabilities: [capB], timeout: 30.0)
        store.scheduleTask(newcomer, task: {
            await order.append("newcomer")
        }, completion: { _ in newcomerDone.signal() })
        for _ in 0..<2000 {
            await Task.yield()
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(await order.values == [])
        #expect(store.pendingTaskCount == 2)

        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 2, maxGlobal: nil))
        await headDone.wait()
        await newcomerDone.wait()
        #expect(await order.values == ["head", "newcomer"])

        release.finish()
        await holderDone.wait()
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("wake fires at reconfigure never from count reads")
    func wakeFiresAtReconfigureNeverFromCountReads() async {
        let cap = Capability.custom("d3Explicit_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap(
            [cap],
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 1, maxGlobal: 10),
            prefix: "D3Explicit"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        let holderDone = AsyncGate()
        let executions = Probe()
        let waiterDone = AsyncGate()

        let holder = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(holder, task: {
            started.signal()
            await release.wait()
        }, completion: { _ in holderDone.signal() })
        await started.wait()

        let waiter = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(waiter, task: {
            await executions.inc()
        }, completion: { _ in waiterDone.signal() })
        for _ in 0..<2000 {
            await Task.yield()
        }
        #expect(store.pendingTaskCount == 1)

        for _ in 0..<5 {
            #expect(store.pendingTaskCount == 1)
            #expect(store.activeTaskCount == 1)
            #expect(store.generationCount == 1)
            _ = store.schedulingGenerations.pureSnapshot
        }
        #expect(await executions.count == 0)
        #expect(store.pendingTaskCount == 1)

        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 1, maxGlobal: 10))
        #expect(store.generationCount == 2)
        #expect(await executions.count == 0)
        #expect(store.pendingTaskCount == 1)

        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 2, maxGlobal: 10))
        await waiterDone.wait()
        #expect(await executions.count == 1)

        release.finish()
        await holderDone.wait()
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
