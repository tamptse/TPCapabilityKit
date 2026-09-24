import Testing
import Foundation
@testable import TPCapabilityKit

/// Pins the activation ordering contract: the post-admission gates decide
/// without settling, `activate` settles failed exits and silently releases
/// refused ones, and refused exits never leak slots.
///
/// The entry-availability exit has no pump-driven integration test by design:
/// the dequeue guard makes it reachable only through TOCTOU injection, so the
/// gate unit test plus review cover it instead of a flaky timing test.
struct ActivationGateTests {
    private func makeScheduler(store: DynamicStore) -> TaskScheduler {
        TaskScheduler(store: store, concurrencyController: ConcurrencyController())
    }

    @Test func gateFailsWhenCapabilityMissing() {
        let store = DynamicStore()
        let scheduler = makeScheduler(store: store)
        let missing = Capability.custom("GateMissing_\(UUID().uuidString)")
        let lease = scheduler.schedule(
            TaskDescriptor(requiredCapabilities: [missing], timeout: 30.0),
            taskExecution: {}
        )
        defer { scheduler.cancel(taskId: lease.task.id) }

        #expect(scheduler.gateAdmitted(lease) == .failed)
    }

    @Test func gateNeverSettles() {
        let store = DynamicStore()
        let scheduler = makeScheduler(store: store)
        let missing = Capability.custom("GateNoSettle_\(UUID().uuidString)")
        let lease = scheduler.schedule(
            TaskDescriptor(requiredCapabilities: [missing], timeout: 30.0),
            taskExecution: {}
        )
        defer { scheduler.cancel(taskId: lease.task.id) }

        _ = scheduler.gateAdmitted(lease)
        #expect(!lease.isTerminal)
    }

    @Test func gateRefusesTerminalLease() {
        let store = DynamicStore()
        let scheduler = makeScheduler(store: store)
        let missing = Capability.custom("GateTerminal_\(UUID().uuidString)")
        let lease = scheduler.schedule(
            TaskDescriptor(requiredCapabilities: [missing], timeout: 30.0),
            taskExecution: {}
        )

        scheduler.cancel(taskId: lease.task.id)
        #expect(lease.isTerminal)
        #expect(scheduler.gateAdmitted(lease) == .refused)
    }

    @Test func gateProceedsWhenAvailable() {
        let store = DynamicStore()
        let cap = Capability.custom("GateProceed_\(UUID().uuidString)")
        let pluginId = "GateProceed_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = makeScheduler(store: store)

        let gate = AsyncStream<Void>.makeStream()
        let lease = scheduler.schedule(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            taskExecution: {
                for await _ in gate.stream { break }
            }
        )
        defer {
            gate.continuation.finish()
            scheduler.cancel(taskId: lease.task.id)
        }

        #expect(scheduler.gateAdmitted(lease) == .proceed)
    }

    /// A capability withdrawn mid-admission expires the lease without ever
    /// executing it: `fail()` is active-only per the Lease contract, so the
    /// never-activated failure surfaces as expired — terminal with delivery,
    /// never stuck pending.
    @Test func withdrawnCapabilityDuringAdmissionExpiresWithoutExecuting() async {
        let store = DynamicStore(configuration: .init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1))
        let cap = Capability.custom("GateFlap_\(UUID().uuidString)")
        let pluginId = "GateFlap_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let blocker = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(blocker, task: {
            started.continuation.yield()
            for await _ in release.stream { break }
        })
        for await _ in started.stream { break }

        actor Executions {
            var count = 0
            func increment() { count += 1 }
        }
        let executions = Executions()
        let done = AsyncStream<Void>.makeStream()
        let target = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        let lease = store.scheduleTask(target, task: {
            await executions.increment()
        }, completion: { _ in done.continuation.yield() })

        try? await Task.sleep(nanoseconds: 300_000_000)
        store.unregisterCapability(for: pluginId)
        release.continuation.finish()

        for await _ in done.stream { break }
        #expect(lease.state == .expired)
        #expect(await executions.count == 0)
    }

    @Test func refusedExitFreesSlotForNextTask() async {
        let store = DynamicStore(configuration: .init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1))
        let cap = Capability.custom("GateRefused_\(UUID().uuidString)")
        let pluginId = "GateRefused_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let blockerDone = AsyncStream<Void>.makeStream()
        let blocker = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(blocker, task: {
            started.continuation.yield()
            for await _ in release.stream { break }
        }, completion: { _ in blockerDone.continuation.yield() })
        for await _ in started.stream { break }

        let parkedDone = AsyncStream<Void>.makeStream()
        let parked = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        let parkedLease = store.scheduleTask(parked, task: {}, completion: { _ in parkedDone.continuation.yield() })
        try? await Task.sleep(nanoseconds: 300_000_000)
        store.cancelTask(taskId: parkedLease.task.id)
        for await _ in parkedDone.stream { break }
        #expect(parkedLease.state == .expired)

        release.continuation.finish()
        for await _ in blockerDone.stream { break }

        let thirdDone = AsyncStream<Void>.makeStream()
        let third = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(third, task: {}, completion: { _ in thirdDone.continuation.yield() })
        for await _ in thirdDone.stream { break }
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
