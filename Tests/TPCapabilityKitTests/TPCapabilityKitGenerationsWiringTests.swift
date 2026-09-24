import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Generations Wiring (Store facade)")
struct TPCapabilityKitGenerationsWiringTests {
    @Test("reconfigure-during-drain triple sums pending while sharing admission")
    func drainTripleSumsPendingSharesAdmission() async {
        let store = DynamicStore(configuration: .init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1))
        let cap = Capability.custom("wiringTriple_\(UUID().uuidString)")
        let pluginId = "WiringTriple_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let blockerDone = AsyncStream<Void>.makeStream()
        let secondDone = AsyncStream<Void>.makeStream()

        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: {
                started.continuation.yield()
                for await _ in release.stream { break }
            },
            completion: { _ in blockerDone.continuation.yield() }
        )
        for await _ in started.stream { break }

        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1))

        store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: {},
            completion: { _ in secondDone.continuation.yield() }
        )

        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(store.pendingTaskCount == 1)
        #expect(store.activeTaskCount == 1)
        #expect(store.pendingTaskCount + store.activeTaskCount == 2)
        #expect(store.generationCount == 2)

        release.continuation.finish()
        for await _ in blockerDone.stream { break }
        for await _ in secondDone.stream { break }
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
        #expect(store.generationCount == 1)
    }

    @Test("pending sums across generations without admission in play")
    func pendingSumsAcrossGenerations() async {
        let store = DynamicStore()
        let cap = Capability.custom("wiringSum_\(UUID().uuidString)")

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
