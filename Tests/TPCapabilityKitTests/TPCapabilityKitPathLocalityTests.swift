import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Path Locality Proof Tests")
struct PathLocalityTests {
    @Test("park withdraw cancel retry share one path with single delivery and freed slot")
    func parkWithdrawCancelRetryLocality() async {
        let store = DynamicStore(configuration: .init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1))
        let cap = Capability.custom("PathLocality_\(UUID().uuidString)")
        let pluginId = "PathLocality_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }

        actor Executions {
            var count = 0
            func increment() { count += 1 }
        }
        let executions = Executions()
        actor Deliveries {
            var calls = 0
            var states: [Lease.State] = []
            func record(_ lease: Lease) {
                calls += 1
                states.append(lease.state)
            }
        }
        let deliveries = Deliveries()

        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let blockerDone = AsyncStream<Void>.makeStream()
        let blocker = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(blocker, task: {
            started.continuation.yield()
            for await _ in release.stream { break }
        }, completion: { _ in blockerDone.continuation.yield() })
        for await _ in started.stream { break }

        let targetDone = AsyncStream<Void>.makeStream()
        let target = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        let targetLease = store.scheduleTask(target, task: {
            await executions.increment()
        }, completion: { finished in
            Task {
                await deliveries.record(finished)
                targetDone.continuation.yield()
            }
        })

        try? await Task.sleep(nanoseconds: 300_000_000)
        store.unregisterCapability(for: pluginId)
        release.continuation.finish()
        for await _ in blockerDone.stream { break }
        for await _ in targetDone.stream { break }

        #expect(targetLease.state == .expired)
        #expect(await executions.count == 0)
        #expect(await deliveries.calls == 1)
        #expect(await deliveries.states == [.expired])

        store.registerCapability(for: pluginId, capabilities: [cap])

        let missing = Capability.custom("PathLocalityParked_\(UUID().uuidString)")
        let parkedDone = AsyncStream<Void>.makeStream()
        actor ParkedDeliveries {
            var calls = 0
            func record() { calls += 1 }
        }
        let parkedDeliveries = ParkedDeliveries()
        let parked = TaskDescriptor(requiredCapabilities: [missing], timeout: 30.0)
        let parkedLease = store.scheduleTask(parked, task: {
            await executions.increment()
        }, completion: { _ in
            Task {
                await parkedDeliveries.record()
                parkedDone.continuation.yield()
            }
        })

        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(!parkedLease.isTerminal)
        #expect(store.pendingTaskCount == 1)
        store.cancelTask(taskId: parked.id)
        for await _ in parkedDone.stream { break }

        #expect(parkedLease.state == .expired)
        #expect(await parkedDeliveries.calls == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)

        actor Attempts {
            var count = 0
            func next() -> Int {
                count += 1
                return count
            }
        }
        let attempts = Attempts()
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
