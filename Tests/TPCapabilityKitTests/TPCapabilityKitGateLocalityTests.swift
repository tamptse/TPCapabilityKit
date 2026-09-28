import Testing
import Foundation
@testable import TPCapabilityKit

/// Gate-locality pins for the availability gate beside activation
/// (see `gateAdmitted` in TaskScheduler+Path).
struct GateLocalityTests {
    @Test func flipDuringAdmissionFailsWithoutExecuting() async {
        let cap = Capability.custom("GateLocalityFlip_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap(
            [cap],
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1),
            deterministic: true,
            prefix: "GateLocalityFlip"
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
        for _ in 0..<100 { await Task.yield() }
        store.unregisterCapability(for: pluginId)
        release.finish()

        await done.wait()
        await blockerDone.wait()
        #expect(lease.isTerminal)
        #expect(lease.state == .expired)
        #expect(lease.state != .completed)
        #expect(await executions.count == 0)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test func terminalDuringWaitRefusesWithoutSettling() async {
        let (store, _) = makeStoreWithCap([], deterministic: true, prefix: "GateLocalityTerminal")
        let missing = Capability.custom("GateLocalityTerminal_\(UUID().uuidString)")
        let executions = Probe()
        let completions = Probe()
        let done = AsyncGate()
        let lease = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [missing], timeout: 30.0),
            task: { await executions.inc() },
            completion: { _ in
                Task { await completions.inc() }
                done.signal()
            }
        )

        await store.waitForDeterministicWaiters(count: 1)
        store.cancelTask(taskId: lease.task.id)
        await done.wait()
        #expect(lease.isTerminal)
        #expect(lease.state == .expired)
        #expect(await executions.count == 0)
        for _ in 0..<1000 {
            if await completions.count == 1 { break }
            await Task.yield()
        }
        #expect(await completions.count == 1)

        let pluginId = "GateLocalityTerminal_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [missing])
        defer { store.unregisterCapability(for: pluginId) }
        for _ in 0..<100 { await Task.yield() }

        #expect(lease.isTerminal)
        #expect(lease.state == .expired)
        #expect(await executions.count == 0)
        #expect(await completions.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
