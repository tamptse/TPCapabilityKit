import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Expiry Tests")
struct DeadlineTests {
    @Test("resolve once at Deadline construction shares one expiry through lease state")
    func resolveOnceAtDeadlineConstruction() async {
        let store = DynamicStore()
        let clock = makeDeterministicClock()
        let scheduler = makeScheduler(
            store: store,
            configuration: .init(defaultTimeout: 0.3, maxPerCapability: 5, maxGlobal: 20),
            clock: clock
        )

        let implicit = TaskDescriptor(
            requiredCapabilities: [.custom("ExpiryImplicit_\(UUID().uuidString)")]
        )
        #expect(implicit.timeout == nil)
        let implicitDone = AsyncGate()
        let implicitLease = scheduler.schedule(implicit, taskExecution: {}, completion: { _ in
            implicitDone.signal()
        })
        #expect(implicitLease.task.timeout == nil)
        #expect(implicit.timeout == nil)

        let explicit = TaskDescriptor(
            requiredCapabilities: [.custom("ExpiryExplicit_\(UUID().uuidString)")],
            timeout: 7.5
        )
        let explicitDone = AsyncGate()
        let explicitLease = scheduler.schedule(explicit, taskExecution: {}, completion: { _ in
            explicitDone.signal()
        })
        #expect(explicitLease.task.timeout == 7.5)

        await clock.waitForWaiters(count: 2)
        await clock.advance(by: 7.5)

        await implicitDone.wait()
        await explicitDone.wait()
        #expect(implicitLease.state == .expired)
        #expect(explicitLease.state == .expired)
    }

    @Test("execution expiry delivers expired through completion")
    func executionExpiryDeliversExpired() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "ExpiryExec")
        defer { store.unregisterCapability(for: pluginId) }
        let clock = makeDeterministicClock()
        let scheduler = makeScheduler(store: store, clock: clock)

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 0.2, maxRetries: 0)
        let done = AsyncGate()
        let started = AsyncGate()
        let release = AsyncGate()
        let lease = scheduler.schedule(task, taskExecution: {
            started.signal()
            await release.wait()
        }, completion: { _ in
            done.signal()
        })
        await started.wait()
        await clock.waitForWaiters(count: 1)
        await clock.advance(by: 0.2)
        await done.wait()
        release.finish()

        #expect(lease.state == .expired)
    }

    @Test("operation wins the single race when the clock never fires")
    func operationWinsSingleRace() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "ExpiryWin")
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = makeScheduler(store: store, clock: makeDeterministicClock())

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 0.5)
        let result: String? = await scheduler.scheduleAndWait(task) {
            return "ok"
        }

        #expect(result == "ok")
    }
}
