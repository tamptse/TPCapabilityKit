import Foundation
import Testing
@testable import TPCapabilityKit

struct DynamicStoreSchedulerIntegrationTests {
    @Test func scheduleTaskWithCapability() async {
        let store = DynamicStore()
        let pluginId = "IntegPlugin_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])

        let result = await store.scheduleTaskAndWait(
            TaskDescriptor(requiredCapabilities: [.heavyTask])
        ) {
            return "IntegrationResult"
        }

        #expect(result == "IntegrationResult")
    }

    @Test func scheduleTaskWithoutCapability() async {
        let store = DynamicStore()
        store.schedulingGenerations.enableDeterministicTime(owner: store)

        async let result = store.scheduleTaskAndWait(
            TaskDescriptor(
                requiredCapabilities: [.custom("Missing_\(UUID().uuidString)")],
                timeout: 0.5
            )
        ) {
            return "ShouldNotRun"
        }

        await store.schedulingGenerations.advanceTime(by: 0.5)

        #expect(await result == nil)
        #expect(store.pendingTaskCount == 0)
    }

    @Test func immediateAndQueuedShareOneWaiterForLateCapability() async {
        let store = DynamicStore()
        let pluginId = "SharedWaiter_\(UUID().uuidString)"
        let cap = Capability.custom("sharedWaiter_\(UUID().uuidString)")

        async let immediate = store.runTaskWhenAvailable(capability: cap, timeout: 5.0) {
            "immediate"
        }
        async let queued: String? = store.scheduleTaskAndWait(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 5.0)
        ) {
            "queued"
        }

        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }

        let (immediateResult, queuedResult) = await (immediate, queued)
        #expect(immediateResult == "immediate")
        #expect(queuedResult == "queued")
    }

    @Test func manyWaitersWakeOnSingleLateRegistration() async {
        let store = DynamicStore()
        let pluginId = "SharedStorm_\(UUID().uuidString)"
        let cap = Capability.custom("sharedStorm_\(UUID().uuidString)")
        let total = 20

        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<total {
                if i % 2 == 0 {
                    group.addTask {
                        await store.runTaskWhenAvailable(capability: cap, timeout: 5.0) {
                            "immediate"
                        } == "immediate"
                    }
                } else {
                    group.addTask {
                        await store.scheduleTaskAndWait(
                            TaskDescriptor(requiredCapabilities: [cap], timeout: 5.0)
                        ) {
                            "queued"
                        } == "queued"
                    }
                }
            }

            store.registerCapability(for: pluginId, capabilities: [cap])
            defer { store.unregisterCapability(for: pluginId) }

            var delivered = 0
            for await ok in group {
                #expect(ok)
                delivered += 1
            }
            #expect(delivered == total)
        }

        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
