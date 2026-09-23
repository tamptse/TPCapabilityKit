import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Single Expiry Tests")
struct SingleExpiryTests {
    @Test("waiter and execution timeouts agree through schedule-and-wait with virtual clock")
    func waiterAndExecutionShareSingleExpiry() async {
        let waiterStore = DynamicStore()
        waiterStore.enableDeterministicTime()
        let missing = Capability.custom("singleExpiryWaiter_\(UUID().uuidString)")
        async let waiterResult: String? = waiterStore.scheduleTaskAndWait(
            TaskDescriptor(requiredCapabilities: [missing], timeout: 5.0)
        ) {
            return "should-not-run"
        }
        await waiterStore.advanceTime(by: 5.0)
        #expect(await waiterResult == nil)
        #expect(waiterStore.pendingTaskCount == 0)
        #expect(waiterStore.activeTaskCount == 0)

        let execStore = DynamicStore()
        execStore.enableDeterministicTime()
        let pluginId = "SingleExpiryExec_\(UUID().uuidString)"
        execStore.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { execStore.unregisterCapability(for: pluginId) }
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        async let execResult: String? = execStore.scheduleTaskAndWait(
            TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 0)
        ) {
            started.continuation.yield()
            for await _ in release.stream { break }
            return "should-expire"
        }
        for await _ in started.stream { break }
        await execStore.advanceTime(by: 5.0)
        release.continuation.finish()
        #expect(await execResult == nil)
        #expect(execStore.pendingTaskCount == 0)
        #expect(execStore.activeTaskCount == 0)
    }
}
