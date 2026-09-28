import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Reap Guarantees (Store facade)")
struct TPCapabilityKitReapGuaranteeTests {
    @Test("two live generations sum counts while sharing one admission domain")
    func sumsAcrossTwoLiveGenerationsWhileSharingAdmission() async {
        let cap = Capability.custom("reapSum_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap(
            [cap],
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1),
            deterministic: true,
            prefix: "ReapSum"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        let blockerDone = AsyncGate()
        let secondDone = AsyncGate()
        let executions = Probe()

        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: {
                started.signal()
                await release.wait()
            },
            completion: { _ in blockerDone.signal() }
        )
        await started.wait()

        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1))

        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: { await executions.inc() },
            completion: { _ in secondDone.signal() }
        )

        for _ in 0..<1000 {
            if store.pendingTaskCount == 1 && store.activeTaskCount == 1 { break }
            await Task.yield()
        }
        #expect(store.pendingTaskCount == 1)
        #expect(store.activeTaskCount == 1)
        #expect(store.pendingTaskCount + store.activeTaskCount == 2)
        #expect(await executions.count == 0)

        release.finish()
        await blockerDone.wait()
        await secondDone.wait()
        #expect(await executions.count == 1)
        for _ in 0..<1000 {
            if store.pendingTaskCount == 0 && store.activeTaskCount == 0 { break }
            await Task.yield()
        }
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)

        let followOnDone = AsyncGate()
        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: {},
            completion: { _ in followOnDone.signal() }
        )
        await followOnDone.wait()
        for _ in 0..<1000 {
            if store.pendingTaskCount == 0 && store.activeTaskCount == 0 { break }
            await Task.yield()
        }
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("drained generations release so counts return to zero automatically")
    func drainedReleaseReturnsToZeroCountsViaAutomaticReap() async {
        let (store, _) = makeStoreWithCap([], prefix: "ReapDrain")
        let missing = Capability.custom("reapDrain_\(UUID().uuidString)")

        let first = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [missing], timeout: 30.0),
            task: {}
        )
        #expect(store.pendingTaskCount == 1)

        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 20))
        #expect(store.pendingTaskCount == 1)

        let second = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [missing], timeout: 30.0),
            task: {}
        )
        #expect(store.pendingTaskCount == 2)
        #expect(store.activeTaskCount == 0)

        store.cancelTask(taskId: first.task.id)
        store.cancelTask(taskId: second.task.id)

        for _ in 0..<1000 {
            if store.pendingTaskCount == 0 && store.activeTaskCount == 0 { break }
            await Task.yield()
        }
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
        #expect(first.isTerminal)
        #expect(second.isTerminal)

        let followOnDone = AsyncGate()
        let followOn = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [missing], timeout: 30.0),
            task: {},
            completion: { _ in followOnDone.signal() }
        )
        #expect(store.pendingTaskCount == 1)
        store.cancelTask(taskId: followOn.task.id)
        await followOnDone.wait()
        for _ in 0..<1000 {
            if store.pendingTaskCount == 0 && store.activeTaskCount == 0 { break }
            await Task.yield()
        }
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("repeated count reads agree exactly")
    func reapIdempotentRepeatedReadsAgree() async {
        let (store, _) = makeStoreWithCap([], prefix: "ReapIdempotent")
        let missing = Capability.custom("reapIdem_\(UUID().uuidString)")

        let first = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [missing], timeout: 30.0),
            task: {}
        )
        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 20))
        let second = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [missing], timeout: 30.0),
            task: {}
        )

        #expect(store.pendingTaskCount == 2)
        #expect(store.pendingTaskCount + store.activeTaskCount == 2)

        let pendingFirst = store.pendingTaskCount
        let activeFirst = store.activeTaskCount
        for _ in 0..<5 {
            #expect(store.pendingTaskCount == pendingFirst)
            #expect(store.activeTaskCount == activeFirst)
        }
        #expect(pendingFirst == 2)
        #expect(activeFirst == 0)

        store.cancelTask(taskId: first.task.id)
        store.cancelTask(taskId: second.task.id)
        for _ in 0..<1000 {
            if store.pendingTaskCount == 0 && store.activeTaskCount == 0 { break }
            await Task.yield()
        }
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)

        let followOn = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [missing], timeout: 30.0),
            task: {}
        )
        #expect(store.pendingTaskCount == 1)
        store.cancelTask(taskId: followOn.task.id)
        for _ in 0..<1000 {
            if store.pendingTaskCount == 0 && store.activeTaskCount == 0 { break }
            await Task.yield()
        }
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("reconfiguring over drained store keeps single live generation")
    func currentNeverReapedKeepsSingleGeneration() async {
        let cap = Capability.custom("reapCurrent_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap([cap], prefix: "ReapCurrent")
        defer { store.unregisterCapability(for: pluginId) }

        let done = AsyncGate()
        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: {},
            completion: { _ in done.signal() }
        )
        await done.wait()

        for _ in 0..<1000 {
            if store.pendingTaskCount == 0 && store.activeTaskCount == 0 { break }
            await Task.yield()
        }
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
        #expect(store.pendingTaskCount + store.activeTaskCount == 0)

        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 20))
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
        #expect(store.pendingTaskCount + store.activeTaskCount == 0)

        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 20))
        #expect(store.pendingTaskCount + store.activeTaskCount == 0)

        let followOnDone = AsyncGate()
        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: {},
            completion: { _ in followOnDone.signal() }
        )
        await followOnDone.wait()
        for _ in 0..<1000 {
            if store.pendingTaskCount == 0 && store.activeTaskCount == 0 { break }
            await Task.yield()
        }
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
