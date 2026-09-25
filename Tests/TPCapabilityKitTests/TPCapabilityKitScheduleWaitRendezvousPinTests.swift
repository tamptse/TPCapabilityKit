import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Schedule-Wait Rendezvous Pins")
struct ScheduleWaitRendezvousPinTests {
    @Test("wait success resumes value once and drains")
    func waitSuccessResumesValueOnce() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "S3WaitSuccess")
        defer { store.unregisterCapability(for: pluginId) }

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0)
        let result = await store.scheduleTaskAndWait(task) { "ok" }

        #expect(result == "ok")
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("wait failure resumes nil once and drains")
    func waitFailureResumesNilOnce() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "S3WaitFail")
        defer { store.unregisterCapability(for: pluginId) }

        struct Boom: Error {}
        let attempts = Probe()
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 0)
        let result: String? = await store.scheduleTaskAndWait(task) { () async throws -> String in
            await attempts.next()
            throw Boom()
        }

        #expect(result == nil)
        #expect(await attempts.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("wait timeout resumes nil and drains")
    func waitTimeoutResumesNil() async {
        let store = DynamicStore()
        let clock = makeDeterministicClock()
        let scheduler = makeScheduler(store: store, clock: clock)

        let task = TaskDescriptor(
            requiredCapabilities: [.custom("S3Timeout_\(UUID().uuidString)")],
            timeout: 0.3
        )
        async let result: String? = scheduler.scheduleAndWait(task) { "should-not-run" }
        await clock.waitForWaiters(count: 1)
        await clock.advance(by: 0.3)

        #expect(await result == nil)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("cancel during wait delivers nil once then same identity reschedules")
    func cancelDuringWaitThenReschedule() async {
        let store = DynamicStore()
        let missing = Capability.custom("S3CancelWait_\(UUID().uuidString)")
        let id = "s3-cancelwait_\(UUID().uuidString)"
        let descriptor = TaskDescriptor(id: id, requiredCapabilities: [missing], timeout: 10.0)

        async let first: String? = store.scheduleTaskAndWait(descriptor) { () async throws -> String in
            "unreachable"
        }
        await Task.yield()
        await Task.yield()
        store.cancelTask(taskId: id)
        let firstResult = await first

        #expect(firstResult == nil)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)

        let pluginId = "S3CancelRereserve_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [missing])
        defer { store.unregisterCapability(for: pluginId) }

        let second: String? = await store.scheduleTaskAndWait(descriptor) { "second" }
        #expect(second == "second")
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("displacement during wait expires old once while new completes")
    func displacementDuringWaitExpiresOldOnce() async {
        let store = DynamicStore()
        let cap = Capability.custom("S3DisplaceWait_\(UUID().uuidString)")
        let id = "s3-displace_\(UUID().uuidString)"

        let oldTask = TaskDescriptor(id: id, requiredCapabilities: [cap], timeout: 10.0)
        let oldWait = Task<String?, Never> {
            await store.scheduleTaskAndWait(oldTask) { () async throws -> String in
                "old"
            }
        }
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        let newTask = TaskDescriptor(id: id, requiredCapabilities: [cap], timeout: 10.0)
        let newWait = Task<String?, Never> {
            await store.scheduleTaskAndWait(newTask) { () async throws -> String in
                "new"
            }
        }

        let oldResult = await oldWait.value
        #expect(oldResult == nil)

        let pluginId = "S3DisplaceWait_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }

        let newResult = await newWait.value
        #expect(newResult == "new")
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("retry preserves waiter to recovery")
    func retryPreservesWaiterToRecovery() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "S3RetryWait")
        defer { store.unregisterCapability(for: pluginId) }

        struct Flaky: Error {}
        let attempts = Probe()
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 1)
        let result = await store.scheduleTaskAndWait(task) { () async throws -> String in
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
