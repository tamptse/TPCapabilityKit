import Testing
import Foundation
@testable import TPCapabilityKit
@testable import TPCapabilityKitBridge

/// D1 reap pins: drained generations release automatically on the settle
/// notification with no callable reap entry, proven through the public counts
/// seam (`configureScheduler` + `pendingTaskCount` / `activeTaskCount`).
/// Mid-test reads poll public counts wherever a drained generation may be
/// held, so every pin below also holds as generations release underneath.
@Suite("D1 Generations Reap Purity Pins")
struct TPCapabilityKitD1ReapPurityTests {
    private func pollCounts(
        _ store: DynamicStore,
        until predicate: (Int, Int) -> Bool
    ) async {
        for _ in 0..<1000 {
            if predicate(store.pendingTaskCount, store.activeTaskCount) { break }
            await Task.yield()
        }
    }

    @Test("public count reads change nothing and agree at steady state")
    func pureViewStableAndAgreeing() async {
        let store = DynamicStore()
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
        #expect(store.pendingTaskCount + store.activeTaskCount == 0)

        let cap = Capability.custom("d1Pure_\(UUID().uuidString)")
        let pluginId = "D1Pure_\(UUID().uuidString)"
        let done = AsyncGate()
        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: {},
            completion: { _ in done.signal() }
        )

        let pendingFirst = store.pendingTaskCount
        let activeFirst = store.activeTaskCount
        #expect(pendingFirst == 1)
        #expect(store.pendingTaskCount == pendingFirst)
        #expect(store.activeTaskCount == activeFirst)
        #expect(store.pendingTaskCount + store.activeTaskCount == 1)
        #expect(store.pendingTaskCount == 1)

        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }
        await done.wait()
        await pollCounts(store, until: { $0 == 0 && $1 == 0 })
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("settle hook releases drained non-current generation; repeat reads agree")
    func settleEntryReleasesDrainedNonCurrent() async {
        let store = DynamicStore()
        let cap = Capability.custom("d1Linger_\(UUID().uuidString)")
        let pluginId = "D1Linger_\(UUID().uuidString)"
        let done = AsyncGate()
        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: {},
            completion: { _ in done.signal() }
        )
        #expect(store.pendingTaskCount == 1)

        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 20))
        #expect(store.pendingTaskCount + store.activeTaskCount == 1)

        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }
        await done.wait()
        await pollCounts(store, until: { $0 == 0 && $1 == 0 })

        for _ in 0..<5 {
            #expect(store.pendingTaskCount == 0)
            #expect(store.activeTaskCount == 0)
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
        await pollCounts(store, until: { $0 == 0 && $1 == 0 })
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("current generation never reaped even when drained")
    func currentNeverReaped() async {
        let store = DynamicStore()
        let cap = Capability.custom("d1Current_\(UUID().uuidString)")
        let pluginId = "D1Current_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }

        let firstDone = AsyncGate()
        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: {},
            completion: { _ in firstDone.signal() }
        )
        await firstDone.wait()
        await pollCounts(store, until: { $0 == 0 && $1 == 0 })
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)

        let secondDone = AsyncGate()
        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: {},
            completion: { _ in secondDone.signal() }
        )
        await secondDone.wait()
        await pollCounts(store, until: { $0 == 0 && $1 == 0 })
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("reconfigure preserves in-flight work with aggregated counts")
    func reconfigurePreservesInFlight() async {
        let store = DynamicStore()
        let cap = Capability.custom("d1Inflight_\(UUID().uuidString)")
        let pluginId = "D1Inflight_\(UUID().uuidString)"
        let firstDone = AsyncGate()
        let secondDone = AsyncGate()

        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: {},
            completion: { _ in firstDone.signal() }
        )
        #expect(store.pendingTaskCount == 1)

        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 20))
        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: {},
            completion: { _ in secondDone.signal() }
        )
        #expect(store.pendingTaskCount == 2)

        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }
        await firstDone.wait()
        await secondDone.wait()
        await pollCounts(store, until: { $0 == 0 && $1 == 0 })

        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)

        let followOnDone = AsyncGate()
        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: {},
            completion: { _ in followOnDone.signal() }
        )
        await followOnDone.wait()
        await pollCounts(store, until: { $0 == 0 && $1 == 0 })
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("cancel fans out across generations without disturbing survivors")
    func cancelFansOut() async {
        let store = DynamicStore()
        let cap = Capability.custom("d1Cancel_\(UUID().uuidString)")
        let pluginId = "D1Cancel_\(UUID().uuidString)"
        let survivorDone = AsyncGate()

        let doomed = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: {}
        )
        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 20))
        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: {},
            completion: { _ in survivorDone.signal() }
        )
        #expect(store.pendingTaskCount == 2)

        store.cancelTask(taskId: doomed.task.id)
        await pollCounts(store, until: { pending, _ in pending == 1 })
        #expect(store.pendingTaskCount == 1)

        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }
        await survivorDone.wait()
        await pollCounts(store, until: { $0 == 0 && $1 == 0 })
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)

        let followOnDone = AsyncGate()
        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: {},
            completion: { _ in followOnDone.signal() }
        )
        await followOnDone.wait()
        await pollCounts(store, until: { $0 == 0 && $1 == 0 })
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("precede-first-use gate enables on an empty store through the public path")
    func precedeFirstUseGate() {
        let store = DynamicStore()
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
        store.enableDeterministicTime(owner: store)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("bridge counts agree with store facade")
    func bridgeAgrees() async {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let cap = Capability.custom("d1Bridge_\(UUID().uuidString)")
        let pluginId = "D1Bridge_\(UUID().uuidString)"
        let done = AsyncGate()

        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: {},
            completion: { _ in done.signal() }
        )
        #expect(bridge.taskScheduler.pendingCount == store.pendingTaskCount)
        #expect(bridge.taskScheduler.pendingCount == 1)

        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }
        await done.wait()
        await pollCounts(store, until: { $0 == 0 && $1 == 0 })
        #expect(bridge.taskScheduler.pendingCount == 0)
        #expect(bridge.taskScheduler.activeCount == store.activeTaskCount)
    }

    @Test("slot admission stays on the shared domain across reconfigure")
    func sharedSlotDomain() async {
        let store = DynamicStore(
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1)
        )
        let cap = Capability.custom("d1Slot_\(UUID().uuidString)")
        let pluginId = "D1Slot_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [cap])
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
        #expect(store.activeTaskCount == 1)

        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1))
        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: { await executions.inc() },
            completion: { _ in secondDone.signal() }
        )
        await pollCounts(store, until: { $0 == 1 && $1 == 1 })
        #expect(await executions.count == 0)

        release.finish()
        await blockerDone.wait()
        await secondDone.wait()
        #expect(await executions.count == 1)
        await pollCounts(store, until: { $0 == 0 && $1 == 0 })
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
        #expect(store.pendingTaskCount + store.activeTaskCount == 0)
    }
}
