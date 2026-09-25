@preconcurrency import Foundation
import Combine
import Testing
@testable import TPCapabilityKit

struct TPCapabilityKitTaskTests {

    // MARK: - Task Execution Tests

    @Test func runTaskWhenCapabilityAvailable() async {
        let store = DynamicStore()
        let pluginId = "RunTaskPlugin_\(UUID().uuidString)"

        store.registerCapability(for: pluginId, capabilities: [.heavyTask])

        let result = await store.runTask(requiring: .heavyTask) {
            return "HeavyTaskResult"
        }
        #expect(result == "HeavyTaskResult")
    }

    @Test func runTaskWhenCapabilityNotAvailable() async {
        let store = DynamicStore()

        // No capability registered
        let result = await store.runTask(requiring: .custom("NonExistent_\(UUID().uuidString)")) {
            return "ShouldNotRun"
        }
        #expect(result == nil)
    }

    @Test func runTaskPassesArgumentsAndReturnsValue() async {
        let store = DynamicStore()
        let pluginId = "RunTaskArgCap_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.networkAccess])

        let sum = await store.runTask(requiring: .networkAccess) {
            return 40 + 2
        }
        #expect(sum == 42)
    }

    @Test func runTaskWhenAvailableAlreadyAvailable() async {
        let store = DynamicStore()
        let pluginId = "RunTaskWaitCap_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.lightTask])

        let result = await store.runTaskWhenAvailable(capability: .lightTask, timeout: 1.0) {
            return "ImmediateResult"
        }
        #expect(result == "ImmediateResult")
    }

    @Test func runTaskWhenAvailableWaitsForCapability() async {
        let store = DynamicStore()
        store.schedulingGenerations.enableDeterministicTime(owner: store)
        let pluginId = "WaitCapPlugin_\(UUID().uuidString)"
        let uniqueCap = Capability.custom("waitCap_\(UUID().uuidString)")

        actor BoolFlag { var value = false; func set() { value = true } }
        let flag = BoolFlag()

        // Start waiting in background
        let waitingTask = Task {
            let result = await store.runTaskWhenAvailable(capability: uniqueCap, timeout: 30.0) {
                await flag.set()
                return "WaitedResult"
            }
            return result
        }

        await store.schedulingGenerations.waitForDeterministicWaiters(count: 1)

        // Now register the capability
        store.registerCapability(for: pluginId, capabilities: [uniqueCap])

        let result = await waitingTask.value
        #expect(result == "WaitedResult")
        #expect(await flag.value)
    }

    @Test func runTaskWhenAvailableTimesOut() async {
        let store = DynamicStore()
        store.schedulingGenerations.enableDeterministicTime(owner: store)
        let uniqueCap = Capability.custom("timeoutCap_\(UUID().uuidString)")

        async let result = store.runTaskWhenAvailable(capability: uniqueCap, timeout: 0.1) {
            return "ShouldNotRun"
        }
        await store.schedulingGenerations.advanceTime(by: 0.1)

        #expect(await result == nil)
        #expect(store.pendingTaskCount == 0)
    }

    @Test func runTaskCapabilityRevokedAfterRegister() async {
        let store = DynamicStore()
        let pluginId = "RevokeCap_\(UUID().uuidString)"
        let uniqueCap = Capability.custom("revokeCap_\(UUID().uuidString)")

        store.registerCapability(for: pluginId, capabilities: [uniqueCap])
        #expect(store.queryCapability(uniqueCap) == true)

        let result1 = await store.runTask(requiring: uniqueCap) { "First" }
        #expect(result1 == "First")

        // Revoke capability by unregistering
        store.unregisterCapability(for: pluginId)
        #expect(store.queryCapability(uniqueCap) == false)

        let result2 = await store.runTask(requiring: uniqueCap) { "Second" }
        #expect(result2 == nil)
    }

    @Test func runTaskMultipleCapabilities() async {
        let store = DynamicStore()

        store.registerCapability(for: "BG", capabilities: [.heavyTask, .backgroundExecution])
        store.registerCapability(for: "Net", capabilities: [.networkAccess])

        let r1 = await store.runTask(requiring: .heavyTask) { "BG" }
        let r2 = await store.runTask(requiring: .networkAccess) { "Net" }
        let r3 = await store.runTask(requiring: .lightTask) { "Missing" }

        #expect(r1 == "BG")
        #expect(r2 == "Net")
        #expect(r3 == nil)
    }

    @Test func runTaskConcurrentAccess() async {
        let store = DynamicStore()
        let pluginId = "ConcurrentRunTask_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let result = await store.runTask(requiring: .heavyTask) {
                        return i
                    }
                    #expect(result != nil)
                }
            }
        }
    }
}
