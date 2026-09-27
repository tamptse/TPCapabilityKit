import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("D4 Drain Owner Pins")
struct D4DrainOwnerPinTests {
    @Test("single kick entry and single handover rule remain the only drain spelling")
    func singleOwnerSpelling() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let root = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let schedulerURL = root.appendingPathComponent("Sources/TPCapabilityKit/TaskScheduler.swift")
        let pathURL = root.appendingPathComponent("Sources/TPCapabilityKit/TaskScheduler+Path.swift")
        let scheduler = try String(contentsOf: schedulerURL, encoding: .utf8)
        let path = try String(contentsOf: pathURL, encoding: .utf8)
        for source in [scheduler, path] {
            #expect(!source.contains("processPendingTasks"))
            #expect(!source.contains("drainInFlight"))
        }
        #expect(scheduler.components(separatedBy: "func kickPump()").count - 1 == 1)
        #expect(scheduler.contains("struct DrainOwner"))
        #expect(path.components(separatedBy: "counts.queued").count - 1 == 1)
        #expect(scheduler.contains("func setDrainSettledHook"))
        #expect(scheduler.contains("func notifyDrainSettled()"))
        #expect(path.contains("notifyDrainSettled()"))
    }

    @Test("burst drains to zero with every completion delivered exactly once")
    func burstDrainsToZeroExactlyOnce() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "D4Burst")
        defer { store.unregisterCapability(for: pluginId) }

        let total = 50
        let completions = Probe()
        let drained = AsyncGate()
        for _ in 0..<total {
            store.scheduleTask(
                TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0),
                task: {},
                completion: { _ in
                    Task {
                        await completions.inc()
                        drained.signal()
                    }
                }
            )
        }

        for await _ in drained.stream {
            if await completions.count == total { break }
        }
        drained.finish()

        #expect(await completions.count == total)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("cancel during burst still delivers every completion exactly once")
    func cancelDuringBurstDeliversOnce() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "D4CancelBurst")
        defer { store.unregisterCapability(for: pluginId) }

        let total = 30
        let completions = Probe()
        let drained = AsyncGate()
        var ids: [String] = []
        for i in 0..<total {
            let descriptor = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0)
            ids.append(descriptor.id)
            store.scheduleTask(
                descriptor,
                task: {},
                completion: { _ in
                    Task {
                        await completions.inc()
                        drained.signal()
                    }
                }
            )
            if i % 2 == 0 { store.cancelTask(taskId: descriptor.id) }
        }
        for id in ids { store.cancelTask(taskId: id) }

        for await _ in drained.stream {
            if await completions.count == total { break }
        }
        drained.finish()

        #expect(await completions.count == total)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("retry re-queue rejoins the single drain")
    func retryRejoinsSingleDrain() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "D4Retry")
        defer { store.unregisterCapability(for: pluginId) }

        let attempts = Probe()
        struct Boom: Error {}
        let result: String? = await store.scheduleTaskAndWait(
            TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0, maxRetries: 1)
        ) { () async throws -> String in
            let n = await attempts.next()
            if n == 1 { throw Boom() }
            return "recovered"
        }

        #expect(result == "recovered")
        #expect(await attempts.count == 2)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("settle-drain notification fires exactly once per transition")
    func notificationFiresOncePerTransition() async {
        let cap = Capability.custom("D4Notify_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap([cap], prefix: "D4Notify")
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = makeScheduler(store: store)
        let fires = Probe()
        scheduler.setDrainSettledHook {
            _ = scheduler.countsSnapshot
            Task { await fires.inc() }
        }

        let done = AsyncGate()
        scheduler.schedule(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            taskExecution: {},
            completion: { _ in done.signal() }
        )
        await done.wait()
        await d4WaitUntilDrained(scheduler)
        scheduler.notifyDrainSettled()
        await d4WaitForProbeCount(fires, 1)
        scheduler.notifyDrainSettled()
        await d4FlushTasks()
        #expect(await fires.count == 1)

        let started = AsyncGate()
        let release = AsyncGate()
        let done2 = AsyncGate()
        scheduler.schedule(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            taskExecution: {
                started.signal()
                await release.wait()
            },
            completion: { _ in done2.signal() }
        )
        await started.wait()
        scheduler.notifyDrainSettled()
        await d4FlushTasks()
        #expect(await fires.count == 1)
        release.finish()
        await done2.wait()
        await d4WaitUntilDrained(scheduler)
        scheduler.notifyDrainSettled()
        await d4WaitForProbeCount(fires, 2)
        scheduler.notifyDrainSettled()
        await d4FlushTasks()
        #expect(await fires.count == 2)
        #expect(scheduler.countsSnapshot.isDrained)
    }

    @Test("non-current generations drain monotonically under burst")
    func nonCurrentGenerationsDrainMonotonically() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "D4Mono")
        defer { store.unregisterCapability(for: pluginId) }

        let total = 30
        let completions = Probe()
        let drained = AsyncGate()
        for _ in 0..<total {
            store.scheduleTask(
                TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0),
                task: {},
                completion: { _ in
                    Task {
                        await completions.inc()
                        drained.signal()
                    }
                }
            )
        }
        store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 20))

        var maxGenerations = 0
        for await _ in drained.stream {
            maxGenerations = max(maxGenerations, store.generationCount)
            if await completions.count == total { break }
        }
        drained.finish()

        for _ in 0..<10000 {
            if store.pendingTaskCount == 0 && store.activeTaskCount == 0 { break }
            await Task.yield()
        }
        store.schedulingGenerations.reapAtSettle()

        #expect(await completions.count == total)
        #expect(maxGenerations <= 2)
        #expect(store.generationCount == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}

private func d4WaitUntilDrained(_ scheduler: TaskScheduler) async {
    for _ in 0..<10000 {
        if scheduler.countsSnapshot.isDrained { return }
        await Task.yield()
    }
}

private func d4WaitForProbeCount(_ probe: Probe, _ expected: Int) async {
    for _ in 0..<10000 {
        if await probe.count == expected { return }
        await Task.yield()
    }
}

private func d4FlushTasks(_ count: Int = 200) async {
    for _ in 0..<count { await Task.yield() }
}
