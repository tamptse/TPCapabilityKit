import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Scoped Slot Tests")
struct ScopedSlotTests {
    @Test("completed tasks drain slots synchronously via public counts")
    func completedDrainsSynchronously() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "SlotDrain")
        defer { store.unregisterCapability(for: pluginId) }

        let total = 10
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<total {
                group.addTask {
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0)
                        store.scheduleTask(task, task: {}, completion: { _ in done.resume() })
                    }
                }
            }
        }

        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("cancel active drains slot exactly once via public counts")
    func cancelActiveDrainsExactlyOnce() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "SlotCancel")
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        let done = AsyncGate()
        let counter = Probe()

        let descriptor = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 10.0)
        store.scheduleTask(descriptor, task: {
            started.signal()
            await release.wait()
        }, completion: { _ in
            Task {
                await counter.inc()
                done.signal()
            }
        })

        await started.wait()
        store.cancelTask(taskId: descriptor.id)
        await done.wait()
        release.finish()

        #expect(await counter.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("late unregister during slot contention never executes")
    func lateUnregisterNeverExecutes() async {
        let cap = Capability.custom("slotGate_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap(
            [cap],
            configuration: .init(defaultTimeout: 5.0, maxPerCapability: 5, maxGlobal: 1),
            deterministic: true,
            prefix: "SlotGate"
        )

        let started = AsyncGate()
        let release = AsyncGate()
        let blockerDone = AsyncGate()
        let gatedDone = AsyncGate()
        let executions = Probe()

        let blocker = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(blocker, task: {
            started.signal()
            await release.wait()
        }, completion: { _ in blockerDone.signal() })

        await started.wait()

        let gated = TaskDescriptor(requiredCapabilities: [cap], timeout: 5.0, maxRetries: 0)
        let gatedLease = store.scheduleTask(gated, task: {
            Task {
                await executions.inc()
            }
        }, completion: { _ in gatedDone.signal() })

        store.unregisterCapability(for: pluginId)
        release.finish()

        await blockerDone.wait()
        await store.waitForDeterministicWaiters(count: 1)
        await store.advanceTime(by: 5.0)
        await gatedDone.wait()

        #expect(await executions.count == 0)
        #expect(gatedLease.state == .expired)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("cancel during slot-acquire suspension never executes")
    func cancelDuringAcquireNeverExecutes() async {
        let cap = Capability.custom("slotCancelFlight_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap(
            [cap],
            configuration: .init(defaultTimeout: 5.0, maxPerCapability: 5, maxGlobal: 1),
            deterministic: true,
            prefix: "SlotCancelFlight"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        let blockerDone = AsyncGate()

        let blocker = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(blocker, task: {
            started.signal()
            await release.wait()
        }, completion: { _ in blockerDone.signal() })

        await started.wait()
        #expect(store.activeTaskCount == 1)

        let gated = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0, maxRetries: 0)
        let gatedDone = AsyncGate()
        let gatedState = Probe()
        let gatedLease = store.scheduleTask(gated, task: {
            Task {
                await gatedState.inc()
            }
        }, completion: { finished in
            Task {
                await gatedState.record(finished)
                gatedDone.signal()
            }
        })

        #expect(store.pendingTaskCount == 1)
        store.cancelTask(taskId: gated.id)
        release.finish()

        await gatedDone.wait()
        #expect(await gatedState.count == 1)
        #expect(await gatedState.lastState == .expired)
        #expect(gatedLease.state == .expired)
        await blockerDone.wait()
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("shared domain enforces limits through the Store facade")
    func injectedDomainLimitsEnforced() async {
        let (store, pluginId) = makeStoreWithCap(
            [.heavyTask],
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1),
            prefix: "SlotInjected"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        let blockerDone = AsyncGate()
        let secondDone = AsyncGate()
        let blockerLease = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0),
            task: {
                started.signal()
                await release.wait()
            },
            completion: { _ in blockerDone.signal() }
        )
        await started.wait()

        let secondLease = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0),
            task: {},
            completion: { _ in secondDone.signal() }
        )

        for _ in 0..<1000 {
            if store.pendingTaskCount == 1 && store.activeTaskCount == 1 { break }
            await Task.yield()
        }
        #expect(store.pendingTaskCount == 1)
        #expect(store.activeTaskCount == 1)

        release.finish()
        await blockerDone.wait()
        await secondDone.wait()
        #expect(blockerLease.state == .completed)
        #expect(secondLease.state == .completed)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
