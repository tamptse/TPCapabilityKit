import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Settlement Guards Tests")
struct SettlementGuardsTests {
    @Test("void completion with retries reuses same Lease and preserves waiter")
    func voidRetryReusesIdentity() async {
        let store = DynamicStore()
        let pluginId = "GuardsRetry_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 1)
        actor Attempts {
            var count = 0
            func next() -> Int { count += 1; return count }
        }
        let attempts = Attempts()
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
        let store = DynamicStore()
        let pluginId = "GuardsIdentity_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(store: store)

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 1)
        actor State {
            var calls = 0
            var delivered: Lease?
            func record(_ lease: Lease) { calls += 1; delivered = lease }
        }
        let state = State()
        let returned: Lease = scheduler.schedule(task, taskExecution: {}, completion: { lease in
            Task { await state.record(lease) }
        })
        while await state.calls == 0 { await Task.yield() }

        #expect(await state.calls == 1)
        #expect(await state.delivered === returned)
        #expect(returned.isTerminal)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("void completion without retries fails exactly once")
    func voidNoRetryFailsOnce() async {
        let store = DynamicStore()
        let pluginId = "GuardsNoRetry_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }

        struct Boom: Error {}
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 0)
        actor Attempts {
            var count = 0
            func next() -> Int { count += 1; return count }
        }
        let attempts = Attempts()
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

        actor State {
            var calls = 0
            var terminal: Lease.State?
            func record(_ lease: Lease) { calls += 1; terminal = lease.state }
        }
        let state = State()
        let done = AsyncStream<Void>.makeStream()
        let lease = store.scheduleTask(descriptor, task: {}, completion: { finished in
            Task {
                await state.record(finished)
                done.continuation.yield()
            }
        })
        store.cancelTask(taskId: descriptor.id)
        for await _ in done.stream { break }

        #expect(await state.calls == 1)
        #expect(await state.terminal == .expired)
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
