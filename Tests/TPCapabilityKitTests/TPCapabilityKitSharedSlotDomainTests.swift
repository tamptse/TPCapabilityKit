import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Shared Slot Domain Across Generations (Store seam)")
struct TPCapabilityKitSharedSlotDomainTests {
    @Test("reconfigure under slot pressure keeps total admission within limit")
    func reconfigureKeepsTotalAdmissionWithinLimit() async {
        let store = DynamicStore(configuration: .init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1))
        let cap = Capability.custom("sharedSlot_\(UUID().uuidString)")
        let pluginId = "SharedSlot_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let blockerDone = AsyncStream<Void>.makeStream()
        let secondDone = AsyncStream<Void>.makeStream()
        actor Executions {
            var count = 0
            func increment() { count += 1 }
        }
        let executions = Executions()

        let blocker = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(blocker, task: {
            started.continuation.yield()
            for await _ in release.stream { break }
        }, completion: { _ in blockerDone.continuation.yield() })

        for await _ in started.stream { break }
        #expect(store.activeTaskCount == 1)

        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1))
        #expect(store.generationCount == 2)

        let second = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(second, task: {
            await executions.increment()
        }, completion: { _ in secondDone.continuation.yield() })

        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(await executions.count == 0)
        #expect(store.activeTaskCount == 1)
        #expect(store.pendingTaskCount == 1)

        release.continuation.finish()
        for await _ in blockerDone.stream { break }
        for await _ in secondDone.stream { break }
        #expect(await executions.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
