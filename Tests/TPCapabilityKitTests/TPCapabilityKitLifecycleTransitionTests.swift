import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Lifecycle Transition Agreement Tests (single writer: Lease state vs table place)")
struct LifecycleTransitionTests {
    @Test("activation and completion leave Lease state and counts in agreement")
    func activateSettleAgreement() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "lifecycleTransition")
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
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "lifecycleTransition")
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = makeScheduler(store: store)

        let attempts = Probe()
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
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "lifecycleTransition")
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = makeScheduler(store: store)

        let attempts = Probe()
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

        let finished = AsyncGate()
        let completions = Probe()
        let lease = scheduler.schedule(task, taskExecution: {}, completion: { finishedLease in
            Task {
                await completions.record(finishedLease)
                finished.signal()
            }
        })

        #expect(scheduler.pendingCount == 1)
        #expect(scheduler.activeCount == 0)
        #expect(!lease.isTerminal)
        scheduler.cancel(taskId: task.id)
        await finished.wait()

        #expect(await completions.lastLease?.task.id == task.id)
        #expect(lease.state == .expired)
        #expect(lease.isTerminal)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }
}
