import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("D7 Single Expiry Race and Timeout Truth")
struct D7ExpiryRaceTests {
    @Test("operation win delivers the carried value with waiter-executor agreement")
    func operationWinDeliversCarriedValue() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "D7ValueWin")
        defer { store.unregisterCapability(for: pluginId) }

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0)
        let result = await store.scheduleTaskAndWait(task) { "d7-value" }

        #expect(result == "d7-value")
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("timeout wins with retry budget still expires once without consulting the value")
    func timeoutWinsExpiresOnceDespiteBudget() async {
        let cap = Capability.custom("D7TimeoutBudget_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap([cap], deterministic: true, prefix: "D7TimeoutBudget")
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        let done = AsyncGate()
        let deliveries = Probe()
        let attempts = Probe()
        let task = TaskDescriptor(requiredCapabilities: [cap], timeout: 0.2, maxRetries: 1)
        let lease = store.scheduleTask(task, task: {
            await attempts.inc()
            started.signal()
            await release.wait()
        }, completion: { finished in
            Task {
                await deliveries.record(finished)
                done.signal()
            }
        })
        await started.wait()
        await store.schedulingGenerations.waitForDeterministicWaiters(count: 1)
        await store.schedulingGenerations.advanceTime(by: 0.2)
        await done.wait()

        #expect(lease.state == .expired)
        #expect(await attempts.count == 1)
        #expect(await deliveries.count == 1)
        #expect(await deliveries.lastState == .expired)

        release.finish()
        for _ in 0..<50 { await Task.yield() }

        #expect(lease.state == .expired)
        #expect(await attempts.count == 1)
        #expect(await deliveries.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("stored-nil retries with budget while timeout never does")
    func storedNilRetriesWithBudget() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "D7StoredNil")
        defer { store.unregisterCapability(for: pluginId) }

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 1)
        let attempts = Probe()
        struct D7Flaky: Error {}
        let result = await store.scheduleTaskAndWait(task) { () async throws -> String in
            let n = await attempts.next()
            if n == 1 { throw D7Flaky() }
            return "d7-recovered"
        }

        #expect(result == "d7-recovered")
        #expect(await attempts.count == 2)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("mid-wait capability flip wins with the executed value")
    func midWaitFlipWinsWithValue() async {
        let store = DynamicStore()
        store.schedulingGenerations.enableDeterministicTime(owner: store)
        let cap = Capability.custom("D7FlipWin_\(UUID().uuidString)")
        let task = TaskDescriptor(requiredCapabilities: [cap], timeout: 4.0)
        async let result = store.scheduleTaskAndWait(task) { "d7-flipped" }
        await store.schedulingGenerations.waitForDeterministicWaiters(count: 1)
        let pluginId = "D7FlipWin_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }

        #expect(await result == "d7-flipped")
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("single TaskGroup topology in the expiry detail")
    func singleTaskGroupTopology() throws {
        let path = try String(contentsOf: d7TimeURL(), encoding: .utf8)
        #expect(path.components(separatedBy: "withTaskGroup").count - 1 == 1)
    }

    @Test("single outer-optional decode at the settlement entry")
    func singleOuterOptionalDecodeAtSettlement() throws {
        let path = try String(contentsOf: d7PathURL(), encoding: .utf8)
        let decodeSites = path.components(separatedBy: "\n").filter {
            $0.contains("raced")
                && ($0.contains("guard let") || $0.contains("if let") || $0.contains("switch raced"))
        }
        #expect(decodeSites.count == 1)
    }

    private func d7PathURL() -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        let root = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return root.appendingPathComponent("Sources/TPCapabilityKit/TaskScheduler+Path.swift")
    }

    private func d7TimeURL() -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        let root = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return root.appendingPathComponent("Sources/TPCapabilityKit/Time.swift")
    }
}
