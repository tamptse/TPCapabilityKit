import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Generations Snapshot Postcondition (sum-vs-share)")
struct TPCapabilityKitSnapshotPostconditionTests {
    @Test("drain sums counts under one shared limit with unforked virtual time")
    func drainSumsCountsSharesLimitUnforkedClock() async {
        let cap = Capability.custom("snapshotPost_\(UUID().uuidString)")
        let store = DynamicStore(
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1)
        )
        store.enableDeterministicTime()
        let pluginId = "SnapshotPost_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        let blockerDone = AsyncGate()
        let secondDone = AsyncGate()
        let executions = Probe()

        let blocker = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: {
                started.signal()
                await release.wait()
            },
            completion: { _ in blockerDone.signal() }
        )
        await started.wait()
        #expect(store.activeTaskCount == 1)

        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1))
        #expect(store.pendingTaskCount + store.activeTaskCount == 1)

        let second = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: { await executions.inc() },
            completion: { _ in secondDone.signal() }
        )

        for _ in 0..<1000 {
            if store.pendingTaskCount == 1 && store.activeTaskCount == 1 { break }
            await Task.yield()
        }
        #expect(store.pendingTaskCount == 1)
        #expect(store.activeTaskCount == 1)
        #expect(store.pendingTaskCount + store.activeTaskCount == 2)
        #expect(await executions.count == 0)
        #expect(!second.isTerminal)

        release.finish()
        await blockerDone.wait()
        await secondDone.wait()
        #expect(await executions.count == 1)
        #expect(blocker.isTerminal)
        #expect(second.isTerminal)
        for _ in 0..<1000 {
            if store.pendingTaskCount == 0 && store.activeTaskCount == 0 { break }
            await Task.yield()
        }
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)

        let missing = Capability.custom("snapshotPostMissing_\(UUID().uuidString)")
        let firstDone = AsyncGate()
        let firstCompletions = Probe()
        let first = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [missing], timeout: 5.0),
            task: {},
            completion: { _ in
                Task {
                    await firstCompletions.inc()
                    firstDone.signal()
                }
            }
        )

        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1))

        let secondGenDone = AsyncGate()
        let secondGenCompletions = Probe()
        let secondGen = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [missing], timeout: 5.0),
            task: {},
            completion: { _ in
                Task {
                    await secondGenCompletions.inc()
                    secondGenDone.signal()
                }
            }
        )
        #expect(store.pendingTaskCount == 2)
        #expect(store.pendingTaskCount + store.activeTaskCount == 2)

        await store.waitForDeterministicWaiters(count: 2)
        await store.advanceTime(by: 5.0)
        for await _ in firstDone.stream {
            if await firstCompletions.count == 1 { break }
        }
        for await _ in secondGenDone.stream {
            if await secondGenCompletions.count == 1 { break }
        }

        #expect(first.state == .expired)
        #expect(secondGen.state == .expired)
        for _ in 0..<1000 {
            if store.pendingTaskCount == 0 && store.activeTaskCount == 0 { break }
            await Task.yield()
        }
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)

        let followOn = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [missing], timeout: 5.0),
            task: {}
        )
        #expect(store.pendingTaskCount == 1)
        store.cancelTask(taskId: followOn.task.id)
        for _ in 0..<1000 {
            if store.pendingTaskCount == 0 && store.activeTaskCount == 0 { break }
            await Task.yield()
        }
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
