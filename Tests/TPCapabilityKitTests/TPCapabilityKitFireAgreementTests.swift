import Testing
import Foundation
@testable import TPCapabilityKit

/// Pins the two-entry fire contract (see the entry table on
/// `DynamicStore.runIfAvailable`): check-and-run and schedule-and-wait agree
/// without pressure, while under a held slot sync fire runs and the scheduled
/// wait parks. The divergence is the bypass contract, not a bug: immediate
/// fire by definition skips Lease, slot admission, and Deadline.
struct FireAgreementTests {
    @Test func missingCapabilityAgreesNil() async {
        let (store, _) = makeStoreWithCap([], deterministic: true, prefix: "FireMissing")
        let missing = Capability.custom("FireMissing_\(UUID().uuidString)")

        let syncResult: String? = store.runIfAvailable(requiring: missing) { "ShouldNotRun" }
        #expect(syncResult == nil)

        async let waited: String? = store.scheduleTaskAndWait(
            TaskDescriptor(requiredCapabilities: [missing], timeout: 0.2)
        ) { "ShouldNotRun" }
        await store.waitForDeterministicWaiters(count: 1)
        await store.advanceTime(by: 0.2)
        #expect(await waited == nil)
    }

    @Test func availableCapabilityAgreesValue() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], deterministic: true, prefix: "FireAgree")
        defer { store.unregisterCapability(for: pluginId) }

        #expect(store.runIfAvailable(requiring: .heavyTask) { "ok" } == "ok")

        let waited: String? = await store.scheduleTaskAndWait(
            TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0)
        ) { "ok" }
        #expect(waited == "ok")
    }

    @Test func waiterConvenienceAgreesWithScheduleAndWait() async {
        let cap = Capability.custom("fireConvenience_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap([cap], deterministic: true, prefix: "FireConvenience")
        defer { store.unregisterCapability(for: pluginId) }

        let waited: String? = await store.scheduleTaskAndWait(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 5.0)
        ) { "ok" }
        let convenience: String? = await store.runTaskWhenAvailable(
            capability: cap, timeout: 5.0
        ) { "ok" }
        #expect(waited == convenience)
    }

    @Test func slotPressureSyncFireRunsWhileScheduledWaitParks() async {
        let cap = Capability.custom("fireSlot_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap(
            [cap],
            configuration: .init(defaultTimeout: 5.0, maxPerCapability: 5, maxGlobal: 1),
            deterministic: true,
            prefix: "FireSlot"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        let blockerDone = AsyncGate()
        let executions = Probe()

        let blocker = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(blocker, task: {
            started.signal()
            await release.wait()
        }, completion: { _ in blockerDone.signal() })

        await started.wait()
        #expect(store.activeTaskCount == 1)

        let syncResult = store.runIfAvailable(requiring: cap) { "Immediate" }
        #expect(syncResult == "Immediate")

        let gatedTask = Task {
            await store.scheduleTaskAndWait(
                TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
            ) { () -> String in
                await executions.inc()
                return "Gated"
            }
        }
        for _ in 0..<1000 {
            if store.pendingTaskCount == 1 { break }
            await Task.yield()
        }
        #expect(store.pendingTaskCount == 1)
        for _ in 0..<50 { await Task.yield() }
        #expect(await executions.count == 0)

        release.finish()
        await blockerDone.wait()
        let gatedResult: String? = await gatedTask.value
        #expect(gatedResult == "Gated")
        #expect(await executions.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
