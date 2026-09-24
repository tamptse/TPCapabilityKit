import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Lifecycle Transition Agreement Tests (single writer: Lease state vs table place)")
struct LifecycleTransitionTests {
    private func makeScheduler(store: DynamicStore) -> TaskScheduler {
        TaskScheduler(store: store, concurrencyController: ConcurrencyController())
    }

    private func registerHeavyTask(on store: DynamicStore) -> String {
        let pluginId = "lifecycleTransition_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        return pluginId
    }

    @Test("activation and completion leave Lease state and counts in agreement")
    func activateSettleAgreement() async {
        let store = DynamicStore()
        let pluginId = registerHeavyTask(on: store)
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = makeScheduler(store: store)

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0)
        let finished = await withCheckedContinuation { (done: CheckedContinuation<Lease, Never>) in
            scheduler.schedule(task, taskExecution: {}, completion: { done.resume(returning: $0) })
        }

        #expect(finished.task.id == task.id)
        #expect(finished.state == .completed)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("retry resets the Lease and re-queues as one move")
    func retryAgreement() async {
        let store = DynamicStore()
        let pluginId = registerHeavyTask(on: store)
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = makeScheduler(store: store)

        actor Attempts {
            var count = 0
            func next() -> Int {
                count += 1
                return count
            }
        }
        let attempts = Attempts()
        struct Flaky: Error {}
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 1)
        let result = await scheduler.scheduleAndWait(task) { () async throws -> String in
            let n = await attempts.next()
            if n == 1 { throw Flaky() }
            return "recovered"
        }

        #expect(result == "recovered")
        #expect(await attempts.count == 2)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("terminal failure without retry drains the row exactly once")
    func failureAgreement() async {
        let store = DynamicStore()
        let pluginId = registerHeavyTask(on: store)
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = makeScheduler(store: store)

        actor Attempts {
            var count = 0
            func next() -> Int {
                count += 1
                return count
            }
        }
        let attempts = Attempts()
        struct AlwaysFails: Error {}
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 0)
        let result = await scheduler.scheduleAndWait(task) { () async throws -> String in
            _ = await attempts.next()
            throw AlwaysFails()
        }

        #expect(result == nil)
        #expect(await attempts.count == 1)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("cancel expires the Lease and drains the row together")
    func cancelAgreement() async {
        let store = DynamicStore()
        let scheduler = makeScheduler(store: store)
        let missing = Capability.custom("lifecycleTransitionCancel_\(UUID().uuidString)")
        let task = TaskDescriptor(id: "transition-cancel_\(UUID().uuidString)", requiredCapabilities: [missing], timeout: 10.0)

        let finished = AsyncStream<Lease>.makeStream()
        let lease = scheduler.schedule(task, taskExecution: {}, completion: { finished.continuation.yield($0) })

        #expect(await scheduler.waitForCounts(parked: 1))
        scheduler.cancel(taskId: task.id)
        var expired: Lease?
        for await value in finished.stream {
            expired = value
            break
        }

        #expect(expired?.task.id == task.id)
        #expect(lease.state == .expired)
        #expect(lease.isTerminal)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }
}
