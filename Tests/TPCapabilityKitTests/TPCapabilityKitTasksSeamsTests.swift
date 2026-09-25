import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Tasks Internal Seams Tests")
struct TasksSeamsTests {
    @Test("parked-vs-queued observable while counting policy unchanged")
    func parkedVsQueuedObservable() async {
        let store = DynamicStore()
        let scheduler = makeScheduler(store: store)
        let missing = Capability.custom("parkedVsQueued_\(UUID().uuidString)")
        let task = TaskDescriptor(requiredCapabilities: [missing], timeout: 10.0)
        let done = AsyncGate()
        let lease = scheduler.schedule(task, taskExecution: {}, completion: { _ in
            done.signal()
        })

        #expect(scheduler.pendingCount == 1)
        #expect(scheduler.activeCount == 0)
        #expect(lease.state == .pending)
        #expect(!lease.isTerminal)

        scheduler.cancel(taskId: task.id)
        await done.wait()

        #expect(lease.state == .expired)
        #expect(lease.isTerminal)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("mixed-key contention illustrates FIFO fairness through Tasks seam")
    func mixedKeyContentionFifo() async {
        let capA = Capability.custom("fifoA_\(UUID().uuidString)")
        let capB = Capability.custom("fifoB_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap([capA, capB], prefix: "fifo")
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = makeScheduler(
            store: store,
            configuration: .init(defaultTimeout: 10.0, maxPerCapability: 10, maxGlobal: 1)
        )

        let order = Probe()
        let completions = Probe()
        let started = AsyncGate()
        let release = AsyncGate()
        let drained = AsyncGate()

        let holder = TaskDescriptor(requiredCapabilities: [capA], timeout: 10.0)
        scheduler.schedule(holder, taskExecution: {
            started.signal()
            await release.wait()
        }, completion: { _ in
            Task {
                await completions.inc()
                drained.signal()
            }
        })
        await started.wait()

        let first = TaskDescriptor(requiredCapabilities: [capB], timeout: 10.0)
        let second = TaskDescriptor(requiredCapabilities: [capA, capB], timeout: 10.0)
        scheduler.schedule(first, taskExecution: {
            await order.append("first")
        }, completion: { _ in
            Task {
                await completions.inc()
                drained.signal()
            }
        })
        scheduler.schedule(second, taskExecution: {
            await order.append("second")
        }, completion: { _ in
            Task {
                await completions.inc()
                drained.signal()
            }
        })

        #expect(scheduler.pendingCount == 2)

        release.finish()
        await drained.waitUntil { await completions.count == 3 }

        #expect(await order.values == ["first", "second"])
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("settlement vs ordering vs admission pinned through Tasks seam")
    func settlementOrderingAdmission() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "soa")
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = makeScheduler(
            store: store,
            configuration: .init(defaultTimeout: 10.0, maxPerCapability: 10, maxGlobal: 1)
        )

        let order = Probe()
        let probe = Probe()
        let completions = Probe()
        let started = AsyncGate()
        let release = AsyncGate()
        let drained = AsyncGate()

        let blocker = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 10.0)
        scheduler.schedule(blocker, taskExecution: {
            await probe.enter()
            started.signal()
            await release.wait()
            await probe.exit()
        }, completion: { _ in
            Task {
                await completions.inc()
                drained.signal()
            }
        })
        await started.wait()

        let low = TaskDescriptor(
            id: "soa-low_\(UUID().uuidString)",
            requiredCapabilities: [.heavyTask],
            priority: .low,
            timeout: 10.0
        )
        let high = TaskDescriptor(
            id: "soa-high_\(UUID().uuidString)",
            requiredCapabilities: [.heavyTask],
            priority: .high,
            timeout: 10.0
        )
        scheduler.schedule(low, taskExecution: {
            await probe.enter()
            await order.append("low")
            await probe.exit()
        }, completion: { _ in
            Task {
                await completions.inc()
                drained.signal()
            }
        })
        scheduler.schedule(high, taskExecution: {
            await probe.enter()
            await order.append("high")
            await probe.exit()
        }, completion: { _ in
            Task {
                await completions.inc()
                drained.signal()
            }
        })

        #expect(scheduler.pendingCount == 2)

        release.finish()
        await drained.waitUntil { await completions.count == 3 }

        #expect(await order.values == ["high", "low"])
        #expect(await probe.maxSeen <= 1)
        #expect(await completions.count == 3)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }
}

@Suite("Waiter Through Interface Tests")
struct WaiterThroughInterfaceTests {
    @Test("partial set stays parked until the whole set registers")
    func partialSetStaysParked() async {
        let store = DynamicStore()
        store.enableDeterministicTime()
        let capA = Capability.custom("waiterIfaceA_\(UUID().uuidString)")
        let capB = Capability.custom("waiterIfaceB_\(UUID().uuidString)")
        let pluginA = "WaiterIfaceA_\(UUID().uuidString)"
        let pluginB = "WaiterIfaceB_\(UUID().uuidString)"
        defer {
            store.unregisterCapability(for: pluginA)
            store.unregisterCapability(for: pluginB)
        }

        async let result: String? = store.scheduleTaskAndWait(
            TaskDescriptor(requiredCapabilities: [capA, capB], timeout: 10.0)
        ) {
            return "ready"
        }

        await store.waitForDeterministicWaiters(count: 1)
        #expect(store.pendingTaskCount == 1)

        store.registerCapability(for: pluginA, capabilities: [capA])
        #expect(store.pendingTaskCount == 1)

        store.registerCapability(for: pluginB, capabilities: [capB])
        #expect(await result == "ready")
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("unregister before completion keeps the waiter parked")
    func unregisterKeepsWaiterParked() async {
        let store = DynamicStore()
        store.enableDeterministicTime()
        let cap = Capability.custom("waiterIfaceUnreg_\(UUID().uuidString)")
        let pluginId = "WaiterIfaceUnreg_\(UUID().uuidString)"
        defer { store.unregisterCapability(for: pluginId) }

        async let result: String? = store.scheduleTaskAndWait(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 10.0)
        ) {
            return "ready"
        }

        await store.waitForDeterministicWaiters(count: 1)
        store.registerCapability(for: pluginId, capabilities: [cap])
        store.unregisterCapability(for: pluginId)
        #expect(store.pendingTaskCount == 1)

        store.registerCapability(for: pluginId, capabilities: [cap])
        #expect(await result == "ready")
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("empty set runs without waiting")
    func emptySetRunsImmediately() async {
        let store = DynamicStore()
        let result: String? = await store.scheduleTaskAndWait(
            TaskDescriptor(requiredCapabilities: [], timeout: 5.0)
        ) {
            return "immediate"
        }
        #expect(result == "immediate")
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("missing set expires on the single Deadline")
    func missingSetExpires() async {
        let store = DynamicStore()
        store.enableDeterministicTime()
        let missing = Capability.custom("waiterIfaceMissing_\(UUID().uuidString)")
        async let result: String? = store.scheduleTaskAndWait(
            TaskDescriptor(requiredCapabilities: [missing], timeout: 5.0)
        ) {
            return "should-not-run"
        }
        await store.advanceTime(by: 5.0)
        #expect(await result == nil)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}

@Suite("Queue Alias Tests")
struct QueueAliasTests {
    @Test("parked task stays in pendingCount")
    func parkedStaysInPendingCount() async {
        let store = DynamicStore()
        store.enableDeterministicTime()
        let task = TaskDescriptor(
            requiredCapabilities: [.custom("ParkCount_\(UUID().uuidString)")],
            timeout: 5.0
        )
        let done = AsyncStream<Void>.makeStream()
        let lease = store.scheduleTask(task, task: {}, completion: { _ in
            done.continuation.yield()
        })
        #expect(store.pendingTaskCount == 1)
        #expect(store.activeTaskCount == 0)
        store.cancelTask(taskId: task.id)
        for await _ in done.stream { break }
        #expect(lease.state == .expired)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
