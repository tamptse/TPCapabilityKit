import Testing
import Foundation
@testable import TPCapabilityKit
@testable import TPCapabilityKitBridge

/// D1 explicit-point reaping pins (ticket-02): the pure view and the
/// settle-triggered entry are proven reviewable while getters still reap.
/// Mid-test reads use the pure view wherever a drained generation may be
/// held, so every pin below also holds after the flip to pure getters.
@Suite("D1 Generations Reap Purity Pins")
struct TPCapabilityKitD1ReapPurityTests {
    private func pollPure(
        _ store: DynamicStore,
        until predicate: (Int, Int) -> Bool
    ) async {
        for _ in 0..<1000 {
            let pure = store.schedulingGenerations.pureSnapshot
            if predicate(pure.pending, pure.active) { break }
            await Task.yield()
        }
    }

    @Test("pure view reads change nothing and agree at steady state")
    func pureViewStableAndAgreeing() async {
        let store = DynamicStore()
        let gens = store.schedulingGenerations
        #expect(gens.pureSnapshot.pending == 0)
        #expect(gens.pureSnapshot.active == 0)
        #expect(gens.pureSnapshot.generationCount == 0)

        let cap = Capability.custom("d1Pure_\(UUID().uuidString)")
        let pluginId = "D1Pure_\(UUID().uuidString)"
        let done = AsyncGate()
        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: {},
            completion: { _ in done.signal() }
        )

        let first = gens.pureSnapshot
        let second = gens.pureSnapshot
        #expect(first.pending == 1)
        #expect(second.pending == first.pending)
        #expect(second.active == first.active)
        #expect(second.generationCount == first.generationCount)
        #expect(store.pendingTaskCount == 1)

        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }
        await done.wait()
        gens.reapAtSettle()
        #expect(gens.pureSnapshot.pending == 0)
        #expect(gens.pureSnapshot.active == 0)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("settle entry releases drained non-current generation; repeat is idempotent")
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
        #expect(store.generationCount == 2)

        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }
        await done.wait()
        await pollPure(store, until: { $0 == 0 && $1 == 0 })

        store.schedulingGenerations.reapAtSettle()
        #expect(store.schedulingGenerations.pureSnapshot.generationCount == 1)
        store.schedulingGenerations.reapAtSettle()
        #expect(store.schedulingGenerations.pureSnapshot.generationCount == 1)
        #expect(store.generationCount == 1)
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
        await pollPure(store, until: { $0 == 0 && $1 == 0 })
        store.schedulingGenerations.reapAtSettle()
        #expect(store.schedulingGenerations.pureSnapshot.generationCount == 1)

        let secondDone = AsyncGate()
        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: {},
            completion: { _ in secondDone.signal() }
        )
        await secondDone.wait()
        await pollPure(store, until: { $0 == 0 && $1 == 0 })
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
        #expect(store.schedulingGenerations.pureSnapshot.pending == 2)

        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }
        await firstDone.wait()
        await secondDone.wait()
        await pollPure(store, until: { $0 == 0 && $1 == 0 })

        store.schedulingGenerations.reapAtSettle()
        #expect(store.generationCount == 1)
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
        #expect(store.schedulingGenerations.pureSnapshot.pending == 2)

        store.cancelTask(taskId: doomed.task.id)
        await pollPure(store, until: { pending, _ in pending == 1 })
        #expect(store.schedulingGenerations.pureSnapshot.pending == 1)

        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }
        await survivorDone.wait()
        await pollPure(store, until: { $0 == 0 && $1 == 0 })
        store.schedulingGenerations.reapAtSettle()
        #expect(store.generationCount == 1)
    }

    @Test("precede-first-use gate reads the same numbers through the pure view")
    func precedeFirstUseGate() {
        let store = DynamicStore()
        #expect(store.schedulingGenerations.pureSnapshot.generationCount == 0)
        store.schedulingGenerations.enableDeterministicTime(owner: store)
        #expect(store.schedulingGenerations.pureSnapshot.generationCount == 0)
        #expect(store.generationCount == 0)
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
        await pollPure(store, until: { $0 == 0 && $1 == 0 })
        store.schedulingGenerations.reapAtSettle()
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
        await pollPure(store, until: { $0 == 1 && $1 == 1 })
        #expect(await executions.count == 0)

        release.finish()
        await blockerDone.wait()
        await secondDone.wait()
        #expect(await executions.count == 1)
        store.schedulingGenerations.reapAtSettle()
        let final = store.schedulingGenerations.pureSnapshot
        #expect(final.pending == 0)
        #expect(final.active == 0)
        #expect(final.generationCount == 1)
    }
}
