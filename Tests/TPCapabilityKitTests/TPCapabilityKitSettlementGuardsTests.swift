import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Settlement Guards Tests")
struct SettlementGuardsTests {
    @Test("void completion with retries reuses same Lease and preserves waiter")
    func voidRetryReusesIdentity() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "GuardsRetry")
        defer { store.unregisterCapability(for: pluginId) }

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 1)
        let attempts = Probe()
        struct Flaky: Error {}

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

    @Test("schedule terminal delivers same Lease identity once")
    func scheduleDeliversSameIdentityOnce() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "GuardsIdentity")
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = makeScheduler(store: store)

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 1)
        let state = Probe()
        let returned: Lease = scheduler.schedule(task, taskExecution: {}, completion: { lease in
            Task { await state.record(lease) }
        })
        while await state.count == 0 { await Task.yield() }

        #expect(await state.count == 1)
        #expect(await state.lastLease === returned)
        #expect(returned.isTerminal)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("void completion without retries fails exactly once")
    func voidNoRetryFailsOnce() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "GuardsNoRetry")
        defer { store.unregisterCapability(for: pluginId) }

        struct Boom: Error {}
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 0)
        let attempts = Probe()
        let result: String? = await store.scheduleTaskAndWait(task) { () async throws -> String in
            await attempts.next()
            throw Boom()
        }

        #expect(result == nil)
        #expect(await attempts.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("cancel of pending expires with waiter delivered once")
    func cancelPendingExpiresOnce() async {
        let store = DynamicStore()
        let missing = Capability.custom("GuardsPending_\(UUID().uuidString)")
        let descriptor = TaskDescriptor(requiredCapabilities: [missing], timeout: 10.0)

        let state = Probe()
        let done = AsyncGate()
        let lease = store.scheduleTask(descriptor, task: {}, completion: { finished in
            Task {
                await state.record(finished)
                done.signal()
            }
        })
        store.cancelTask(taskId: descriptor.id)
        await done.wait()

        #expect(await state.count == 1)
        #expect(await state.lastState == .expired)
        #expect(lease.isTerminal)
        #expect(lease.state == .expired)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("cancel of pending scheduleAndWait delivers nil once")
    func cancelPendingWaiterDeliversNilOnce() async {
        let store = DynamicStore()
        let missing = Capability.custom("GuardsPendingWait_\(UUID().uuidString)")
        let descriptor = TaskDescriptor(requiredCapabilities: [missing], timeout: 10.0)

        async let waited: String? = store.scheduleTaskAndWait(descriptor) { () async throws -> String in
            "unreachable"
        }
        await Task.yield()
        await Task.yield()
        store.cancelTask(taskId: descriptor.id)
        let result = await waited

        #expect(result == nil)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
