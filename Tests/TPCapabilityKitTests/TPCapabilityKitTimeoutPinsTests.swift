import Testing
import Foundation
@testable import TPCapabilityKit

private final class RecordedTimeouts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []

    func record(_ timeout: TimeInterval) {
        lock.withLock { values.append(timeout) }
    }

    var all: [TimeInterval] {
        lock.withLock { values }
    }
}

private func immediateClock(recording: RecordedTimeouts? = nil) -> TaskScheduler.ExpiryClock {
    TaskScheduler.ExpiryClock(
        sleep: { timeout in
            recording?.record(timeout)
        }
    )
}

@Suite("Timeout Pins Tests")
struct TimeoutPinsTests {
    @Test("configured default applies to waiter when task timeout is nil")
    func defaultTimeoutAppliesToWaiter() async {
        let store = DynamicStore()
        let recorded = RecordedTimeouts()
        let scheduler = TaskScheduler(
            store: store,
            configuration: .init(defaultTimeout: 0.3, maxPerCapability: 5, maxGlobal: 20),
            clock: immediateClock(recording: recorded)
        )

        let task = TaskDescriptor(
            requiredCapabilities: [.custom("DefaultPin_\(UUID().uuidString)")]
        )
        #expect(task.timeout == nil)

        let result: String? = await scheduler.scheduleAndWait(task) {
            return "should-not-run"
        }

        #expect(result == nil)
        #expect(recorded.all == [0.3])
    }

    @Test("nil timeout resolves to configured default once at enqueue")
    func nilTimeoutResolvesOnceAtEnqueue() async {
        let store = DynamicStore()
        let scheduler = TaskScheduler(
            store: store,
            configuration: .init(defaultTimeout: 0.3, maxPerCapability: 5, maxGlobal: 20),
            clock: immediateClock()
        )

        let task = TaskDescriptor(
            requiredCapabilities: [.custom("ResolveOnce_\(UUID().uuidString)")]
        )
        #expect(task.timeout == nil)

        let done = AsyncStream<Void>.makeStream()
        let lease = scheduler.schedule(task, taskExecution: {}, completion: { _ in
            done.continuation.yield()
        })
        #expect(lease.task.timeout == 0.3)
        #expect(task.timeout == nil)

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
            configuration: .init(defaultTimeout: 0.3, maxPerCapability: 5, maxGlobal: 20)
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
