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
        let (store, _) = makeStoreWithCap([], deterministic: true, prefix: "GateMissing")
        let missing = Capability.custom("GateMissing_\(UUID().uuidString)")
        let done = AsyncGate()
        let lease = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [missing], timeout: 30.0),
            task: {},
            completion: { _ in done.signal() }
        )

        await store.schedulingGenerations.waitForDeterministicWaiters(count: 1)
        #expect(!lease.isTerminal)
        #expect(lease.state == .pending)
        #expect(store.pendingTaskCount == 1)
        #expect(store.activeTaskCount == 0)

        store.cancelTask(taskId: lease.task.id)
        await done.wait()
        #expect(lease.isTerminal)
        #expect(lease.state == .expired)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test func cancelledLeaseExpiresWithoutExecuting() async {
        let (store, _) = makeStoreWithCap([], deterministic: true, prefix: "GateTerminal")
        let missing = Capability.custom("GateTerminal_\(UUID().uuidString)")
        let executions = Probe()
        let done = AsyncGate()
        let lease = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [missing], timeout: 30.0),
            task: { await executions.inc() },
            completion: { _ in done.signal() }
        )

        store.cancelTask(taskId: lease.task.id)
        await done.wait()
        #expect(lease.isTerminal)
        #expect(lease.state == .expired)
        #expect(await executions.count == 0)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test func availableCapabilityProceedsToCompletion() async {
        let cap = Capability.custom("GateProceed_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap([cap], deterministic: true, prefix: "GateProceed")
        defer { store.unregisterCapability(for: pluginId) }

        let executions = Probe()
        let done = AsyncGate()
        let lease = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0),
            task: { await executions.inc() },
            completion: { _ in done.signal() }
        )

        await done.wait()
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
        let cap = Capability.custom("GateFlap_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap(
            [cap],
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1),
            deterministic: true,
            prefix: "GateFlap"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        let blocker = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(blocker, task: {
            started.signal()
            await release.wait()
        })
        await started.wait()

        let executions = Probe()
        let done = AsyncGate()
        let target = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        let lease = store.scheduleTask(target, task: {
            await executions.inc()
        }, completion: { _ in done.signal() })

        for _ in 0..<1000 {
            if store.pendingTaskCount == 1 { break }
            await Task.yield()
        }
        // Let the target park in the slot queue before withdrawal: an early
        // withdraw diverts it to the registry wait whose deterministic
        // deadline this test never advances, so it would never settle.
        for _ in 0..<100 { await Task.yield() }
        store.unregisterCapability(for: pluginId)
        release.finish()

        await done.wait()
        #expect(lease.state == .expired)
        #expect(await executions.count == 0)
    }

    @Test func refusedExitFreesSlotForNextTask() async {
        let cap = Capability.custom("GateRefused_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap(
            [cap],
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1),
            deterministic: true,
            prefix: "GateRefused"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        let blockerDone = AsyncGate()
        let blocker = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(blocker, task: {
            started.signal()
            await release.wait()
        }, completion: { _ in blockerDone.signal() })
        await started.wait()

        let parkedDone = AsyncGate()
        let parked = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        let parkedLease = store.scheduleTask(parked, task: {}, completion: { _ in parkedDone.signal() })
        store.cancelTask(taskId: parkedLease.task.id)
        await parkedDone.wait()
        #expect(parkedLease.state == .expired)

        release.finish()
        await blockerDone.wait()

        let thirdDone = AsyncGate()
        let third = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(third, task: {}, completion: { _ in thirdDone.signal() })
        await thirdDone.wait()
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
