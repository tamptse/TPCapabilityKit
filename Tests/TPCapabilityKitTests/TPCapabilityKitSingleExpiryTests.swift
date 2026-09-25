import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Single Expiry Tests")
struct SingleExpiryTests {
    @Test("waiter and execution timeouts agree through schedule-and-wait with virtual clock")
    func waiterAndExecutionShareSingleExpiry() async {
        let waiterStore = DynamicStore()
        waiterStore.schedulingGenerations.enableDeterministicTime(owner: waiterStore)
        let missing = Capability.custom("singleExpiryWaiter_\(UUID().uuidString)")
        async let waiterResult: String? = waiterStore.scheduleTaskAndWait(
            TaskDescriptor(requiredCapabilities: [missing], timeout: 5.0)
        ) {
            return "should-not-run"
        }
        await waiterStore.schedulingGenerations.advanceTime(by: 5.0)
        #expect(await waiterResult == nil)
        #expect(waiterStore.pendingTaskCount == 0)
        #expect(waiterStore.activeTaskCount == 0)

        let (execStore, pluginId) = makeStoreWithCap(
            [.heavyTask],
            deterministic: true,
            prefix: "SingleExpiryExec"
        )
        defer { execStore.unregisterCapability(for: pluginId) }
        let started = AsyncGate()
        let release = AsyncGate()
        async let execResult: String? = execStore.scheduleTaskAndWait(
            TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 0)
        ) {
            started.signal()
            await release.wait()
            return "should-expire"
        }
        await started.wait()
        await execStore.schedulingGenerations.advanceTime(by: 5.0)
        release.finish()
        #expect(await execResult == nil)
        #expect(execStore.pendingTaskCount == 0)
        #expect(execStore.activeTaskCount == 0)
    }
}
