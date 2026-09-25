import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("R4 Race Carries Value Proofs")
struct RaceValueProofsTests {
    @Test("operation wins with value delivers completed with that value")
    func operationWinsWithValueDeliversCompleted() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "R4ValueWin")
        defer { store.unregisterCapability(for: pluginId) }

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0)
        let result = await store.scheduleTaskAndWait(task) { "r4-value" }

        #expect(result == "r4-value")
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("stored-nil with budget retries then recovers with value")
    func storedNilWithBudgetRetriesThenRecovers() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "R4StoredNilRetry")
        defer { store.unregisterCapability(for: pluginId) }

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 1)
        let attempts = Probe()
        struct Flaky: Error {}
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

    @Test("stored-nil without budget delivers nil once without retry")
    func storedNilWithoutBudgetDeliversNilOnce() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "R4StoredNilNoRetry")
        defer { store.unregisterCapability(for: pluginId) }

        struct Boom: Error {}
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 0)
        let attempts = Probe()
        let result: String? = await store.scheduleTaskAndWait(task) { () async throws -> String in
            await attempts.next()
            throw Boom()
        }

        #expect(result == nil)
        #expect(await attempts.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("timeout wins delivers expired with empty result")
    func timeoutWinsDeliversExpiredEmpty() async {
        let (store, pluginId) = makeStoreWithCap(
            [.heavyTask],
            deterministic: true,
            prefix: "R4TimeoutEmpty"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 0.2, maxRetries: 0)
        async let result: String? = store.scheduleTaskAndWait(task) {
            started.signal()
            await release.wait()
            return "should-expire"
        }
        await started.wait()
        await store.schedulingGenerations.waitForDeterministicWaiters(count: 1)
        await store.schedulingGenerations.advanceTime(by: 0.2)

        #expect(await result == nil)
        release.finish()
        for _ in 0..<20 { await Task.yield() }
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("late loser value discarded after timeout keeps single expired delivery")
    func lateLoserDiscardedAfterTimeout() async {
        let cap = Capability.custom("R4LateLoser_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap([cap], deterministic: true, prefix: "R4LateLoser")
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        let done = AsyncGate()
        let deliveries = Probe()
        let task = TaskDescriptor(requiredCapabilities: [cap], timeout: 0.2, maxRetries: 0)
        let lease = store.scheduleTask(task, task: {
            started.signal()
            await release.wait()
        }, completion: { finished in
            Task {
                await deliveries.record(finished)
                done.signal()
            }
        })
        await started.wait()
        await store.schedulingGenerations.waitForDeterministicWaiters(count: 1)
        await store.schedulingGenerations.advanceTime(by: 0.2)
        await done.wait()

        #expect(lease.state == .expired)
        #expect(await deliveries.count == 1)
        #expect(await deliveries.lastState == .expired)

        release.finish()
        for _ in 0..<50 { await Task.yield() }

        #expect(lease.state == .expired)
        #expect(await deliveries.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)

        let started2 = AsyncGate()
        let release2 = AsyncGate()
        let task2 = TaskDescriptor(requiredCapabilities: [cap], timeout: 0.2, maxRetries: 0)
        async let waited: String? = store.scheduleTaskAndWait(task2) {
            started2.signal()
            await release2.wait()
            return "late-value"
        }
        await started2.wait()
        await store.schedulingGenerations.waitForDeterministicWaiters(count: 1)
        await store.schedulingGenerations.advanceTime(by: 0.2)

        #expect(await waited == nil)
        release2.finish()
        for _ in 0..<20 { await Task.yield() }
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("parked waiter expires once on single expiry")
    func parkedWaiterExpiresOnce() async {
        let store = DynamicStore()
        store.schedulingGenerations.enableDeterministicTime(owner: store)
        let missing = Capability.custom("R4ParkedOnce_\(UUID().uuidString)")
        let task = TaskDescriptor(requiredCapabilities: [missing], timeout: 0.5)
        let done = AsyncGate()
        let deliveries = Probe()
        let lease = store.scheduleTask(task, task: {}, completion: { finished in
            Task {
                await deliveries.record(finished)
                done.signal()
            }
        })
        await store.schedulingGenerations.waitForDeterministicWaiters(count: 1)
        #expect(!lease.isTerminal)
        await store.schedulingGenerations.advanceTime(by: 0.5)
        await done.wait()

        #expect(lease.state == .expired)
        #expect(await deliveries.count == 1)
        #expect(await deliveries.lastState == .expired)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("waiter wins on mid-wait capability flip with shared resolved timeout")
    func waiterWinsOnMidWaitFlip() async {
        let store = DynamicStore()
        store.schedulingGenerations.enableDeterministicTime(owner: store)
        let cap = Capability.custom("R4FlipWin_\(UUID().uuidString)")
        let task = TaskDescriptor(requiredCapabilities: [cap], timeout: 4.0)
        async let result = store.scheduleTaskAndWait(task) { "flipped-ok" }
        await store.schedulingGenerations.waitForDeterministicWaiters(count: 1)
        let pluginId = "R4FlipWin_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }

        #expect(await result == "flipped-ok")
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("already-satisfied waiter completes without expiry")
    func alreadySatisfiedCompletesWithoutExpiry() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "R4FastPath")
        defer { store.unregisterCapability(for: pluginId) }

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0)
        let result = await store.scheduleTaskAndWait(task) { "fast" }

        #expect(result == "fast")
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
