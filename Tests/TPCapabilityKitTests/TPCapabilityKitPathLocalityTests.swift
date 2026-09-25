import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Path Locality Proof Tests")
struct PathLocalityTests {
    @Test("park withdraw cancel retry share one path with single delivery and freed slot")
    func parkWithdrawCancelRetryLocality() async {
        let cap = Capability.custom("PathLocality_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap(
            [cap],
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1),
            deterministic: true,
            prefix: "PathLocality"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let executions = Probe()
        let deliveries = Probe()

        let started = AsyncGate()
        let release = AsyncGate()
        let blockerDone = AsyncGate()
        let blocker = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(blocker, task: {
            started.signal()
            await release.wait()
        }, completion: { _ in blockerDone.signal() })
        await started.wait()

        let targetDone = AsyncGate()
        let target = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        let targetLease = store.scheduleTask(target, task: {
            await executions.inc()
        }, completion: { finished in
            Task {
                await deliveries.record(finished)
                targetDone.signal()
            }
        })

        for _ in 0..<50 { await Task.yield() }
        store.unregisterCapability(for: pluginId)
        release.finish()
        await blockerDone.wait()
        await targetDone.wait()

        #expect(targetLease.state == .expired)
        #expect(await executions.count == 0)
        #expect(await deliveries.count == 1)
        #expect(await deliveries.states == [.expired])

        store.registerCapability(for: pluginId, capabilities: [cap])

        let missing = Capability.custom("PathLocalityParked_\(UUID().uuidString)")
        let parkedDone = AsyncGate()
        let parkedDeliveries = Probe()
        let parked = TaskDescriptor(requiredCapabilities: [missing], timeout: 30.0)
        let parkedLease = store.scheduleTask(parked, task: {
            await executions.inc()
        }, completion: { _ in
            Task {
                await parkedDeliveries.inc()
                parkedDone.signal()
            }
        })

        await store.schedulingGenerations.waitForDeterministicWaiters(count: 1)
        #expect(!parkedLease.isTerminal)
        #expect(store.pendingTaskCount == 1)
        store.cancelTask(taskId: parked.id)
        await parkedDone.wait()

        #expect(parkedLease.state == .expired)
        #expect(await parkedDeliveries.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)

        let attempts = Probe()
        struct Flaky: Error {}
        let retryTask = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0, maxRetries: 1)
        let result = await store.scheduleTaskAndWait(retryTask) { () async throws -> String in
            let n = await attempts.next()
            if n == 1 { throw Flaky() }
            return "recovered"
        }

        #expect(result == "recovered")
        #expect(await attempts.count == 2)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
