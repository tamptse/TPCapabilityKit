import Testing
import Foundation
@testable import TPCapabilityKit

private func neverClock() -> TaskScheduler.Deadline.Clock {
    let gate = AsyncStream<Void>.makeStream()
    return TaskScheduler.Deadline.Clock(
        sleep: { _ in
            for await _ in gate.stream { break }
        }
    )
}

private func immediateClock() -> TaskScheduler.Deadline.Clock {
    TaskScheduler.Deadline.Clock(sleep: { _ in })
}

@Suite("Expiry Tests")
struct DeadlineTests {
    @Test("resolve once at Deadline construction shares one expiry through lease state")
    func resolveOnceAtDeadlineConstruction() async {
        let store = DynamicStore()
        let scheduler = TaskScheduler(
            store: store,
            configuration: .init(defaultTimeout: 0.3, maxPerCapability: 5, maxGlobal: 20),
            clock: immediateClock(),
            concurrencyController: ConcurrencyController(maxPerCapability: 5, maxGlobal: 20)
        )

        let implicit = TaskDescriptor(
            requiredCapabilities: [.custom("ExpiryImplicit_\(UUID().uuidString)")]
        )
        #expect(implicit.timeout == nil)
        let implicitDone = AsyncStream<Void>.makeStream()
        let implicitLease = scheduler.schedule(implicit, taskExecution: {}, completion: { _ in
            implicitDone.continuation.yield()
        })
        #expect(implicitLease.task.timeout == nil)
        #expect(implicit.timeout == nil)

        let explicit = TaskDescriptor(
            requiredCapabilities: [.custom("ExpiryExplicit_\(UUID().uuidString)")],
            timeout: 7.5
        )
        let explicitDone = AsyncStream<Void>.makeStream()
        let explicitLease = scheduler.schedule(explicit, taskExecution: {}, completion: { _ in
            explicitDone.continuation.yield()
        })
        #expect(explicitLease.task.timeout == 7.5)

        for await _ in implicitDone.stream { break }
        for await _ in explicitDone.stream { break }
        #expect(implicitLease.state == .expired)
        #expect(explicitLease.state == .expired)
    }

    @Test("execution expiry delivers expired through completion")
    func executionExpiryDeliversExpired() async {
        let store = DynamicStore()
        let pluginId = "ExpiryExec_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(store: store, clock: immediateClock(), concurrencyController: ConcurrencyController())

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 0.2, maxRetries: 0)
        let done = AsyncStream<Void>.makeStream()
        let lease = scheduler.schedule(task, taskExecution: {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }, completion: { _ in
            done.continuation.yield()
        })
        for await _ in done.stream { break }

        #expect(lease.state == .expired)
    }

    @Test("operation wins the single race when the clock never fires")
    func operationWinsSingleRace() async {
        let store = DynamicStore()
        let pluginId = "ExpiryWin_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(store: store, clock: neverClock(), concurrencyController: ConcurrencyController())

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 0.5)
        let result: String? = await scheduler.scheduleAndWait(task) {
            return "ok"
        }

        #expect(result == "ok")
    }
}
