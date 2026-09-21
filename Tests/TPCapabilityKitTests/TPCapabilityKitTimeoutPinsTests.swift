import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Timeout Pins Tests")
struct TimeoutPinsTests {
    @Test("waiter expiry honours task timeout")
    func waiterExpiryHonoursTimeout() async {
        let store = DynamicStore()
        let scheduler = TaskScheduler(store: store)

        let task = TaskDescriptor(
            requiredCapabilities: [.custom("WaiterPin_\(UUID().uuidString)")],
            timeout: 0.3
        )
        let done = AsyncStream<Void>.makeStream()
        let start = Date()
        let lease = scheduler.schedule(task, taskExecution: {}, completion: { _ in
            done.continuation.yield()
        })
        for await _ in done.stream { break }
        let elapsed = Date().timeIntervalSince(start)

        #expect(lease.state == .expired)
        #expect(elapsed >= 0.15)
        #expect(elapsed < 2.0)
    }

    @Test("execution expiry honours task timeout")
    func executionExpiryHonoursTimeout() async {
        let store = DynamicStore()
        let pluginId = "ExecPin_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(store: store)

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 0.2)
        let done = AsyncStream<Void>.makeStream()
        let start = Date()
        let lease = scheduler.schedule(task, taskExecution: {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }, completion: { _ in
            done.continuation.yield()
        })
        for await _ in done.stream { break }
        let elapsed = Date().timeIntervalSince(start)

        #expect(lease.state == .expired)
        #expect(elapsed >= 0.1)
        #expect(elapsed < 1.0)
    }

    @Test("configured default applies to waiter when task timeout is nil")
    func defaultTimeoutAppliesToWaiter() async {
        let store = DynamicStore()
        let scheduler = TaskScheduler(
            store: store,
            configuration: .init(defaultTimeout: 0.3, maxPerCapability: 5, maxGlobal: 20)
        )

        let task = TaskDescriptor(
            requiredCapabilities: [.custom("DefaultPin_\(UUID().uuidString)")]
        )
        #expect(task.timeout == nil)

        let start = Date()
        let result: String? = await scheduler.scheduleAndWait(task) {
            return "should-not-run"
        }
        let elapsed = Date().timeIntervalSince(start)

        #expect(result == nil)
        #expect(elapsed >= 0.15)
        #expect(elapsed < 2.0)
    }
}
