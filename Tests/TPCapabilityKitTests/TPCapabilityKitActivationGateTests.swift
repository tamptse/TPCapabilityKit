import Testing
import Foundation
@testable import TPCapabilityKit

/// Pins the activation ordering contract through the public Store seam:
/// post-admission failure expires without executing, refusal frees slots,
/// availability proceeds to completion, and parking alone never settles.
///
/// The entry-availability exit has no pump-driven integration test by design:
/// the dequeue guard makes it reachable only through TOCTOU injection between
/// the dequeue check and the activator entry, so review covers that narrow
/// window while the post-admission re-check (same settlement) is pinned below.
struct ActivationGateTests {
    @Test func missingCapabilityParksWithoutTerminalizing() async {
        let store = DynamicStore()
        let missing = Capability.custom("GateMissing_\(UUID().uuidString)")
        let done = AsyncStream<Void>.makeStream()
        let lease = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [missing], timeout: 30.0),
            task: {},
            completion: { _ in done.continuation.yield() }
        )

        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(!lease.isTerminal)
        #expect(lease.state == .pending)
        #expect(store.pendingTaskCount == 1)
        #expect(store.activeTaskCount == 0)

        store.cancelTask(taskId: lease.task.id)
        for await _ in done.stream { break }
        #expect(lease.isTerminal)
        #expect(lease.state == .expired)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test func cancelledLeaseExpiresWithoutExecuting() async {
        let store = DynamicStore()
        let missing = Capability.custom("GateTerminal_\(UUID().uuidString)")
        actor Executions {
            var count = 0
            func increment() { count += 1 }
        }
        let executions = Executions()
        let done = AsyncStream<Void>.makeStream()
        let lease = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [missing], timeout: 30.0),
            task: { await executions.increment() },
            completion: { _ in done.continuation.yield() }
        )

        store.cancelTask(taskId: lease.task.id)
        for await _ in done.stream { break }
        #expect(lease.isTerminal)
        #expect(lease.state == .expired)
        #expect(await executions.count == 0)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test func availableCapabilityProceedsToCompletion() async {
        let store = DynamicStore()
        let cap = Capability.custom("GateProceed_\(UUID().uuidString)")
        let pluginId = "GateProceed_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }

        actor Executions {
            var count = 0
            func increment() { count += 1 }
        }
        let executions = Executions()
        let done = AsyncStream<Void>.makeStream()
        let lease = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: { await executions.increment() },
            completion: { _ in done.continuation.yield() }
        )

        for await _ in done.stream { break }
        #expect(lease.isTerminal)
        #expect(lease.state == .completed)
        #expect(await executions.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
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
