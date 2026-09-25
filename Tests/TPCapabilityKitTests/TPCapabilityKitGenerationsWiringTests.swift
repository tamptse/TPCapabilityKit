import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Generations Wiring (Store facade)")
struct TPCapabilityKitGenerationsWiringTests {
    @Test("reconfigure-during-drain triple sums pending while sharing admission")
    func drainTripleSumsPendingSharesAdmission() async {
        let cap = Capability.custom("wiringTriple_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap(
            [cap],
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1),
            deterministic: true,
            prefix: "WiringTriple"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        let blockerDone = AsyncGate()
        let secondDone = AsyncGate()

        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: {
                started.signal()
                await release.wait()
            },
            completion: { _ in blockerDone.signal() }
        )
        await started.wait()

        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1))

        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: {},
            completion: { _ in secondDone.signal() }
        )

        for _ in 0..<1000 {
            if store.pendingTaskCount == 1 && store.activeTaskCount == 1 { break }
            await Task.yield()
        }
        #expect(store.pendingTaskCount == 1)
        #expect(store.activeTaskCount == 1)
        #expect(store.pendingTaskCount + store.activeTaskCount == 2)
        #expect(store.generationCount == 2)

        release.finish()
        await blockerDone.wait()
        await secondDone.wait()
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
        #expect(store.generationCount == 1)
    }

    @Test("pending sums across generations without admission in play")
    func pendingSumsAcrossGenerations() async {
        let cap = Capability.custom("wiringSum_\(UUID().uuidString)")
        let (store, _) = makeStoreWithCap([], prefix: "WiringSum")

        store.scheduleTask(TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0), task: {})
        #expect(store.pendingTaskCount == 1)

        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 20))
        #expect(store.pendingTaskCount == 1)

        store.scheduleTask(TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0), task: {})
        #expect(store.pendingTaskCount == 2)
        #expect(store.activeTaskCount == 0)
        #expect(store.generationCount == 2)
    }
}
