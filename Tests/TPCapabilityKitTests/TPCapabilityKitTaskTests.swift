@preconcurrency import Foundation
import Combine
import Testing
@testable import TPCapabilityKit

struct TPCapabilityKitTaskTests {

    // MARK: - Task Execution Tests

    @Test func runIfAvailableWhenCapabilityAvailable() async {
        let store = DynamicStore()
        let pluginId = "RunTaskPlugin_\(UUID().uuidString)"

        store.registerCapability(for: pluginId, capabilities: [.heavyTask])

        let result = store.runIfAvailable(requiring: .heavyTask) {
            return "HeavyTaskResult"
        }
        #expect(result == "HeavyTaskResult")
    }

    @Test func runIfAvailableWhenCapabilityNotAvailable() async {
        let store = DynamicStore()

        // No capability registered
        let result = store.runIfAvailable(requiring: .custom("NonExistent_\(UUID().uuidString)")) {
            return "ShouldNotRun"
        }
        #expect(result == nil)
    }

    @Test func runIfAvailablePassesArgumentsAndReturnsValue() async {
        let store = DynamicStore()
        let pluginId = "RunTaskArgCap_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.networkAccess])

        let sum = store.runIfAvailable(requiring: .networkAccess) {
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
        store.enableDeterministicTime()
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

        await store.waitForDeterministicWaiters(count: 1)

        // Now register the capability
        store.registerCapability(for: pluginId, capabilities: [uniqueCap])

        let result = await waitingTask.value
        #expect(result == "WaitedResult")
        #expect(await flag.value)
    }

    @Test func runTaskWhenAvailableTimesOut() async {
        let store = DynamicStore()
        store.enableDeterministicTime()
        let uniqueCap = Capability.custom("timeoutCap_\(UUID().uuidString)")

        async let result = store.runTaskWhenAvailable(capability: uniqueCap, timeout: 0.1) {
            return "ShouldNotRun"
        }
        await store.waitForDeterministicWaiters(count: 1)
        await store.advanceTime(by: 0.1)

        #expect(await result == nil)
        #expect(store.pendingTaskCount == 0)
    }

    @Test func runIfAvailableCapabilityRevokedAfterRegister() async {
        let store = DynamicStore()
        let pluginId = "RevokeCap_\(UUID().uuidString)"
        let uniqueCap = Capability.custom("revokeCap_\(UUID().uuidString)")

        store.registerCapability(for: pluginId, capabilities: [uniqueCap])
        #expect(store.queryCapability(uniqueCap) == true)

        let result1 = store.runIfAvailable(requiring: uniqueCap) { "First" }
        #expect(result1 == "First")

        // Revoke capability by unregistering
        store.unregisterCapability(for: pluginId)
        #expect(store.queryCapability(uniqueCap) == false)

        let result2 = store.runIfAvailable(requiring: uniqueCap) { "Second" }
        #expect(result2 == nil)
    }

    @Test func runIfAvailableMultipleCapabilities() async {
        let store = DynamicStore()

        store.registerCapability(for: "BG", capabilities: [.heavyTask, .backgroundExecution])
        store.registerCapability(for: "Net", capabilities: [.networkAccess])

        let r1 = store.runIfAvailable(requiring: .heavyTask) { "BG" }
        let r2 = store.runIfAvailable(requiring: .networkAccess) { "Net" }
        let r3 = store.runIfAvailable(requiring: .lightTask) { "Missing" }

        #expect(r1 == "BG")
        #expect(r2 == "Net")
        #expect(r3 == nil)
    }

    @Test func runIfAvailableConcurrentAccess() async {
        let store = DynamicStore()
        let pluginId = "ConcurrentRunTask_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let result = store.runIfAvailable(requiring: .heavyTask) {
                        return i
                    }
                    #expect(result != nil)
                }
            }
        }
    }
}
