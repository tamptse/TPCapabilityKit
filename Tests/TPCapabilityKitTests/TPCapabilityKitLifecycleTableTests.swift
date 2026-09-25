import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Lifecycle Table Single Owner Tests (path internal mechanics + Tasks seam)")
struct LifecycleTableTests {
    @Test("parked reachable through public seam with counts agreeing and no execution")
    func parkedReachable() async {
        let store = DynamicStore()
        store.schedulingGenerations.enableDeterministicTime(owner: store)
        let missing = Capability.custom("parkReachable_\(UUID().uuidString)")
        let executions = Probe()
        let deliveries = Probe()
        let done = AsyncGate()
        let descriptor = TaskDescriptor(requiredCapabilities: [missing], timeout: 10.0)
        let lease = store.scheduleTask(descriptor, task: {
            await executions.inc()
        }, completion: { _ in
            Task {
                await deliveries.inc()
                done.signal()
            }
        })

        await store.schedulingGenerations.waitForDeterministicWaiters(count: 1)
        #expect(!lease.isTerminal)
        #expect(store.pendingTaskCount == 1)
        #expect(store.activeTaskCount == 0)
        #expect(await executions.count == 0)
        #expect(await deliveries.count == 0)

        store.cancelTask(taskId: descriptor.id)
        await done.wait()

        #expect(lease.state == .expired)
        #expect(lease.isTerminal)
        #expect(await deliveries.count == 1)
        #expect(await executions.count == 0)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("double schedule same id keeps single row with displaced delivery and no duplicate waiter")
    func doubleScheduleKeepsSingleRow() async {
        let store = DynamicStore()
        store.schedulingGenerations.enableDeterministicTime(owner: store)
        let missing = Capability.custom("doublePark_\(UUID().uuidString)")
        let id = "double-park_\(UUID().uuidString)"
        let executions = Probe()
        let firstDeliveries = Probe()
        let firstDone = AsyncGate()
        let first = TaskDescriptor(id: id, requiredCapabilities: [missing], timeout: 10.0)
        let firstLease = store.scheduleTask(first, task: {
            await executions.inc()
        }, completion: { finished in
            Task {
                await firstDeliveries.record(finished)
                firstDone.signal()
            }
        })

        await store.schedulingGenerations.waitForDeterministicWaiters(count: 1)
        #expect(store.pendingTaskCount == 1)
        #expect(!firstLease.isTerminal)

        let secondDeliveries = Probe()
        let secondDone = AsyncGate()
        let second = TaskDescriptor(id: id, requiredCapabilities: [missing], timeout: 10.0)
        let secondLease = store.scheduleTask(second, task: {
            await executions.inc()
        }, completion: { finished in
            Task {
                await secondDeliveries.record(finished)
                secondDone.signal()
            }
        })

        await firstDone.wait()
        #expect(firstLease.isTerminal)
        #expect(firstLease.state == .expired)
        #expect(await firstDeliveries.count == 1)
        #expect(!secondLease.isTerminal)
        #expect(store.pendingTaskCount == 1)
        #expect(store.activeTaskCount == 0)
        for _ in 0..<50 { await Task.yield() }
        #expect(store.pendingTaskCount == 1)
        #expect(!secondLease.isTerminal)

        store.cancelTask(taskId: id)
        await secondDone.wait()

        #expect(secondLease.state == .expired)
        #expect(await secondDeliveries.count == 1)
        #expect(await executions.count == 0)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("cancel-while-parked lands expired once with waiter cancelled and reschedule works")
    func cancelWhileParkedPin() async {
        let store = DynamicStore()
        store.schedulingGenerations.enableDeterministicTime(owner: store)
        let missing = Capability.custom("cancelParked_\(UUID().uuidString)")
        let id = "cancel-parked_\(UUID().uuidString)"
        let executions = Probe()
        let deliveries = Probe()
        let done = AsyncGate()
        let descriptor = TaskDescriptor(id: id, requiredCapabilities: [missing], timeout: 10.0)
        let lease = store.scheduleTask(descriptor, task: {
            await executions.inc()
        }, completion: { finished in
            Task {
                await deliveries.record(finished)
                done.signal()
            }
        })

        await store.schedulingGenerations.waitForDeterministicWaiters(count: 1)
        #expect(!lease.isTerminal)
        #expect(store.pendingTaskCount == 1)

        store.cancelTask(taskId: id)
        await done.wait()

        #expect(lease.state == .expired)
        #expect(await deliveries.count == 1)
        #expect(await deliveries.states == [.expired])
        #expect(await executions.count == 0)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)

        let secondDone = AsyncGate()
        let secondDeliveries = Probe()
        let second = TaskDescriptor(id: id, requiredCapabilities: [missing], timeout: 10.0)
        let secondLease = store.scheduleTask(second, task: {
            await executions.inc()
        }, completion: { finished in
            Task {
                await secondDeliveries.record(finished)
                secondDone.signal()
            }
        })

        await store.schedulingGenerations.waitForDeterministicWaiters(count: 1)
        #expect(!secondLease.isTerminal)
        #expect(store.pendingTaskCount == 1)

        store.cancelTask(taskId: id)
        await secondDone.wait()

        #expect(secondLease.state == .expired)
        #expect(await secondDeliveries.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("wake clears to activation and re-park behaves with no residual waiter")
    func wakeClearsPin() async {
        let (store, pluginId) = makeStoreWithCap([], deterministic: true, prefix: "wakeClear")
        defer { store.unregisterCapability(for: pluginId) }
        let missing = Capability.custom("wakeClear_\(UUID().uuidString)")
        let id = "wake-clear_\(UUID().uuidString)"
        let executions = Probe()
        let deliveries = Probe()
        let done = AsyncGate()
        let descriptor = TaskDescriptor(id: id, requiredCapabilities: [missing], timeout: 30.0)
        let lease = store.scheduleTask(descriptor, task: {
            await executions.inc()
        }, completion: { finished in
            Task {
                await deliveries.record(finished)
                done.signal()
            }
        })

        await store.schedulingGenerations.waitForDeterministicWaiters(count: 1)
        #expect(!lease.isTerminal)
        #expect(store.pendingTaskCount == 1)

        store.registerCapability(for: pluginId, capabilities: [missing])
        await done.wait()

        #expect(lease.state == .completed)
        #expect(await executions.count == 1)
        #expect(await deliveries.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)

        store.unregisterCapability(for: pluginId)
        let reparkDone = AsyncGate()
        let reparkDeliveries = Probe()
        let repark = TaskDescriptor(id: id, requiredCapabilities: [missing], timeout: 30.0)
        let reparkLease = store.scheduleTask(repark, task: {
            await executions.inc()
        }, completion: { finished in
            Task {
                await reparkDeliveries.record(finished)
                reparkDone.signal()
            }
        })

        await store.schedulingGenerations.waitForDeterministicWaiters(count: 1)
        #expect(!reparkLease.isTerminal)
        #expect(store.pendingTaskCount == 1)
        #expect(store.activeTaskCount == 0)

        store.cancelTask(taskId: id)
        await reparkDone.wait()

        #expect(reparkLease.state == .expired)
        #expect(await reparkDeliveries.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("terminal removal cleans order, same id reschedules through Tasks seam")
    func cancelThenRescheduleSameId() async {
        let store = DynamicStore()
        let scheduler = makeScheduler(store: store)
        let missing = Capability.custom("lifecycleTable_\(UUID().uuidString)")
        let id = "lifecycle-reuse_\(UUID().uuidString)"

        let firstDone = AsyncGate()
        let first = TaskDescriptor(id: id, requiredCapabilities: [missing], timeout: 10.0)
        let firstLease = scheduler.schedule(first, taskExecution: {}, completion: { _ in
            firstDone.signal()
        })

        #expect(scheduler.pendingCount == 1)
        #expect(scheduler.activeCount == 0)
        #expect(!firstLease.isTerminal)

        scheduler.cancel(taskId: id)
        await firstDone.wait()

        #expect(firstLease.isTerminal)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)

        let secondDone = AsyncGate()
        let second = TaskDescriptor(id: id, requiredCapabilities: [missing], timeout: 10.0)
        let secondLease = scheduler.schedule(second, taskExecution: {}, completion: { _ in
            secondDone.signal()
        })

        #expect(scheduler.pendingCount == 1)
        #expect(scheduler.activeCount == 0)
        #expect(!secondLease.isTerminal)

        scheduler.cancel(taskId: id)
        await secondDone.wait()

        #expect(secondLease.isTerminal)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("retry re-queue restores pending through Store facade")
    func retryRestoresPending() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "lifecycleRetry")
        defer { store.unregisterCapability(for: pluginId) }

        let attempts = Probe()
        struct Flaky: Error {}
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 1)
        let result = await store.scheduleTaskAndWait(task) { () async throws -> String in
            let n = await attempts.next()
            if n == 1 { throw Flaky() }
            return "recovered"
        }

        #expect(result == "recovered")
        #expect(await attempts.count == 2)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
