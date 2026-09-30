import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Timeout Pins Tests")
struct TimeoutPinsTests {
    @Test("configured default applies to waiter when task timeout is nil")
    func defaultTimeoutAppliesToWaiter() async {
        let store = DynamicStore()
        let clock = makeDeterministicClock()
        let scheduler = makeScheduler(
            store: store,
            configuration: .init(defaultTimeout: 0.3, maxPerCapability: 5, maxGlobal: 20),
            clock: clock
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
        let clock = makeDeterministicClock()
        let scheduler = makeScheduler(
            store: store,
            configuration: .init(defaultTimeout: 0.3, maxPerCapability: 5, maxGlobal: 20),
            clock: clock
        )

        let task = TaskDescriptor(
            requiredCapabilities: [.custom("ResolveOnce_\(UUID().uuidString)")]
        )
        #expect(task.timeout == nil)

        let done = AsyncGate()
        let lease = scheduler.schedule(task, taskExecution: {}, completion: { _ in
            done.signal()
        })
        #expect(lease.task.timeout == nil)
        #expect(task.timeout == nil)

        await clock.waitForWaiters(count: 1)
        await clock.advance(by: 0.3)

        await done.wait()
        #expect(lease.state == .expired)
    }

    @Test("explicit timeout travels unchanged through enqueue")
    func explicitTimeoutTravelsUnchanged() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "ExplicitPin")
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = makeScheduler(
            store: store,
            configuration: .init(defaultTimeout: 0.3, maxPerCapability: 5, maxGlobal: 20)
        )

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0)
        let done = AsyncGate()
        let lease = scheduler.schedule(task, taskExecution: {}, completion: { _ in
            done.signal()
        })
        #expect(lease.task.timeout == 30.0)

        await done.wait()
        #expect(lease.state == .completed)
    }
}
