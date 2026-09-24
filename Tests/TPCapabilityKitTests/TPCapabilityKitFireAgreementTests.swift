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
        let store = DynamicStore()
        let missing = Capability.custom("FireMissing_\(UUID().uuidString)")

        let syncResult: String? = store.runIfAvailable(requiring: missing) { "ShouldNotRun" }
        #expect(syncResult == nil)

        let waited: String? = await store.scheduleTaskAndWait(
            TaskDescriptor(requiredCapabilities: [missing], timeout: 0.2)
        ) { "ShouldNotRun" }
        #expect(waited == nil)
    }

    @Test func availableCapabilityAgreesValue() async {
        let store = DynamicStore()
        let pluginId = "FireAgree_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }

        #expect(store.runIfAvailable(requiring: .heavyTask) { "ok" } == "ok")

        let waited: String? = await store.scheduleTaskAndWait(
            TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0)
        ) { "ok" }
        #expect(waited == "ok")
    }

    @Test func waiterConvenienceAgreesWithScheduleAndWait() async {
        let store = DynamicStore()
        let pluginId = "FireConvenience_\(UUID().uuidString)"
        let cap = Capability.custom("fireConvenience_\(UUID().uuidString)")
        store.registerCapability(for: pluginId, capabilities: [cap])
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
        let store = DynamicStore(configuration: .init(defaultTimeout: 5.0, maxPerCapability: 5, maxGlobal: 1))
        let pluginId = "FireSlot_\(UUID().uuidString)"
        let cap = Capability.custom("fireSlot_\(UUID().uuidString)")
        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let blockerDone = AsyncStream<Void>.makeStream()
        actor Executions {
            var count = 0
            func inc() { count += 1 }
        }
        let executions = Executions()

        let blocker = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(blocker, task: {
            started.continuation.yield()
            for await _ in release.stream { break }
        }, completion: { _ in blockerDone.continuation.yield() })

        for await _ in started.stream { break }
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
        let gate = Date().addingTimeInterval(5.0)
        while store.pendingTaskCount != 1 && Date() < gate {
            await Task.yield()
        }
        #expect(store.pendingTaskCount == 1)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(await executions.count == 0)

        release.continuation.finish()
        for await _ in blockerDone.stream { break }
        let gatedResult: String? = await gatedTask.value
        #expect(gatedResult == "Gated")
        #expect(await executions.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
