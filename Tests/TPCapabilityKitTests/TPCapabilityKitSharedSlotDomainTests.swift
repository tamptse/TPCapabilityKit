import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Shared Slot Domain Across Generations (Store seam)")
struct TPCapabilityKitSharedSlotDomainTests {
    @Test("reconfigure under slot pressure keeps total admission within limit")
    func reconfigureKeepsTotalAdmissionWithinLimit() async {
        let cap = Capability.custom("sharedSlot_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap(
            [cap],
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1),
            deterministic: true,
            prefix: "SharedSlot"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        let blockerDone = AsyncGate()
        let secondDone = AsyncGate()
        let executions = Probe()

        let blocker = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(blocker, task: {
            started.signal()
            await release.wait()
        }, completion: { _ in blockerDone.signal() })

        await started.wait()
        #expect(store.activeTaskCount == 1)

        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1))
        #expect(store.generationCount == 2)

        let second = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(second, task: {
            await executions.inc()
        }, completion: { _ in secondDone.signal() })

        for _ in 0..<1000 {
            if store.pendingTaskCount == 1 && store.activeTaskCount == 1 { break }
            await Task.yield()
        }
        #expect(await executions.count == 0)
        #expect(store.activeTaskCount == 1)
        #expect(store.pendingTaskCount == 1)

        release.finish()
        await blockerDone.wait()
        await secondDone.wait()
        #expect(await executions.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
