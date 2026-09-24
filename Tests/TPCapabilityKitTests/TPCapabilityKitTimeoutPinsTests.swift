import Testing
import Foundation
@testable import TPCapabilityKit

private func immediateClock() -> Clock {
    let clock = Clock()
    clock.enableDeterministic()
    return clock
}

@Suite("Timeout Pins Tests")
struct TimeoutPinsTests {
    @Test("configured default applies to waiter when task timeout is nil")
    func defaultTimeoutAppliesToWaiter() async {
        let store = DynamicStore()
        let clock = immediateClock()
        let scheduler = TaskScheduler(
            store: store,
            configuration: .init(defaultTimeout: 0.3, maxPerCapability: 5, maxGlobal: 20),
            clock: clock,
            concurrencyController: ConcurrencyController(maxPerCapability: 5, maxGlobal: 20)
        )

        let task = TaskDescriptor(
            requiredCapabilities: [.custom("DefaultPin_\(UUID().uuidString)")]
        )
        #expect(task.timeout == nil)

        async let result: String? = scheduler.scheduleAndWait(task) {
            return "should-not-run"
        }
        await clock.waitForWaiters(count: 1)
        await clock.advance(by: 0.3)

        #expect(await result == nil)
    }

    @Test("nil timeout keeps nil in lease; Deadline resolves to configured default once")
    func nilTimeoutResolvesOnceAtEnqueue() async {
        let store = DynamicStore()
        let clock = immediateClock()
        let scheduler = TaskScheduler(
            store: store,
            configuration: .init(defaultTimeout: 0.3, maxPerCapability: 5, maxGlobal: 20),
            clock: clock,
            concurrencyController: ConcurrencyController(maxPerCapability: 5, maxGlobal: 20)
        )

        let task = TaskDescriptor(
            requiredCapabilities: [.custom("ResolveOnce_\(UUID().uuidString)")]
        )
        #expect(task.timeout == nil)

        let done = AsyncStream<Void>.makeStream()
        let lease = scheduler.schedule(task, taskExecution: {}, completion: { _ in
            done.continuation.yield()
        })
        #expect(lease.task.timeout == nil)
        #expect(task.timeout == nil)

        await clock.waitForWaiters(count: 1)
        await clock.advance(by: 0.3)

        for await _ in done.stream { break }
        #expect(lease.state == .expired)
    }

    @Test("explicit timeout travels unchanged through enqueue")
    func explicitTimeoutTravelsUnchanged() async {
        let store = DynamicStore()
        let pluginId = "ExplicitPin_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(
            store: store,
            configuration: .init(defaultTimeout: 0.3, maxPerCapability: 5, maxGlobal: 20),
            concurrencyController: ConcurrencyController(maxPerCapability: 5, maxGlobal: 20)
        )

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0)
        let done = AsyncStream<Void>.makeStream()
        let lease = scheduler.schedule(task, taskExecution: {}, completion: { _ in
            done.continuation.yield()
        })
        #expect(lease.task.timeout == 30.0)

        for await _ in done.stream { break }
        #expect(lease.state == .completed)
    }
}
