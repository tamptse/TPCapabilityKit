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

        let result = await store.scheduleTaskAndWait(
            TaskDescriptor(
                requiredCapabilities: [.custom("Missing_\(UUID().uuidString)")],
                timeout: 0.5
            )
        ) {
            return "ShouldNotRun"
        }

        #expect(result == nil)
    }
}
