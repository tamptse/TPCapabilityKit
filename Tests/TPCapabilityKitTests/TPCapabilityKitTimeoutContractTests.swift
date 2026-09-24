import Testing
import Foundation
@testable import TPCapabilityKit
@testable import TPCapabilityKitBridge

private final class ContractRecordedTimeouts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []

    func record(_ timeout: TimeInterval) {
        lock.withLock { values.append(timeout) }
    }

    var all: [TimeInterval] {
        lock.withLock { values }
    }
}

private func contractImmediateClock() -> Clock {
    Clock(sleep: { _ in })
}

private func contractBlockingRecordingClock(
    recording: ContractRecordedTimeouts
) -> Clock {
    Clock(sleep: { timeout in
        recording.record(timeout)
        try? await Task.sleep(nanoseconds: UInt64.max)
    })
}

@Suite("Timeout Contract Tests")
struct TimeoutContractTests {
    @Test("Swift nil timeout resolves to the configured default at Deadline construction")
    func swiftNilResolvesToConfiguredDefault() {
        let clock = contractImmediateClock()
        let configured: TimeInterval = 11.25
        let task = TaskDescriptor(
            requiredCapabilities: [.custom("TimeoutContractNil_\(UUID().uuidString)")]
        )
        #expect(task.timeout == nil)

        let deadline = TaskScheduler.Deadline(task: task, default: configured, clock: clock)
        #expect(deadline.timeout == configured)

        let other = TaskScheduler.Deadline(task: task, default: 12.5, clock: clock)
        #expect(other.timeout == 12.5)

        let explicitTask = TaskDescriptor(
            requiredCapabilities: [.custom("TimeoutContractNilExplicit_\(UUID().uuidString)")],
            timeout: 7.5
        )
        let explicitDeadline = TaskScheduler.Deadline(
            task: explicitTask,
            default: configured,
            clock: clock
        )
        #expect(explicitDeadline.timeout == 7.5)
    }

    @Test("ObjC omitted timeout pins the 30.0 compat literal as explicit")
    func objcOmittedPinsCompatLiteralAsExplicit() {
        let cap = "TimeoutContractOmitted_\(UUID().uuidString)"
        let plain = ObjcTaskDescriptor(capabilities: [cap])
        #expect(plain.underlying.timeout == 30.0)
        #expect(plain.underlying.timeout == ObjcMapper.omittedTimeout)
        #expect(plain.timeout == 30.0)
        #expect(plain.hasExplicitTimeout)

        let client = ObjcTaskDescriptor(
            clientId: "contract-omitted-\(UUID().uuidString)",
            capabilities: [cap]
        )
        #expect(client.underlying.timeout == 30.0)
        #expect(client.underlying.timeout == ObjcMapper.omittedTimeout)
        #expect(client.timeout == 30.0)
        #expect(client.hasExplicitTimeout)
    }

    @Test("ObjC negative timeout means unspecified and resolves at Deadline construction")
    func objcNegativeMeansUnspecifiedResolvesAtDeadline() {
        let cap = "TimeoutContractNegative_\(UUID().uuidString)"
        let configured: TimeInterval = 9.75
        let clock = contractImmediateClock()

        let descriptor = ObjcTaskDescriptor(capabilities: [cap], timeout: -1)
        #expect(descriptor.underlying.timeout == nil)
        #expect(!descriptor.hasExplicitTimeout)
        #expect(descriptor.timeout == ObjcMapper.omittedTimeout)

        let deadline = TaskScheduler.Deadline(
            task: descriptor.underlying,
            default: configured,
            clock: clock
        )
        #expect(deadline.timeout == configured)

        let client = ObjcTaskDescriptor(
            clientId: "contract-negative-\(UUID().uuidString)",
            capabilities: [cap],
            timeout: -1
        )
        #expect(client.underlying.timeout == nil)
        #expect(!client.hasExplicitTimeout)
        let clientDeadline = TaskScheduler.Deadline(
            task: client.underlying,
            default: configured,
            clock: clock
        )
        #expect(clientDeadline.timeout == configured)
    }

    @Test("waiter and executor share one resolved expiry across a mid-wait capability flip")
    func waiterAndExecutorShareOneResolvedExpiry() async {
        let store = DynamicStore()
        let resolved: TimeInterval = 4.25
        let recorded = ContractRecordedTimeouts()
        let scheduler = TaskScheduler(
            store: store,
            configuration: .init(defaultTimeout: resolved, maxPerCapability: 5, maxGlobal: 20),
            clock: contractBlockingRecordingClock(recording: recorded),
            concurrencyController: ConcurrencyController(maxPerCapability: 5, maxGlobal: 20)
        )

        let cap = Capability.custom("TimeoutContractShared_\(UUID().uuidString)")
        let task = TaskDescriptor(requiredCapabilities: [cap])
        #expect(task.timeout == nil)

        actor Produced {
            var value: String?
            func store(_ newValue: String) { value = newValue }
        }
        let produced = Produced()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let done = AsyncStream<Void>.makeStream()
        let lease = scheduler.schedule(task, taskExecution: {
            started.continuation.yield()
            for await _ in release.stream { break }
            await produced.store("flipped-ok")
        }, completion: { _ in
            done.continuation.yield()
        })

        let waitDeadline = Date().addingTimeInterval(5.0)
        while recorded.all.count < 1 && Date() < waitDeadline {
            await Task.yield()
        }
        #expect(recorded.all.count >= 1)

        let pluginId = "TimeoutContractShared_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }

        for await _ in started.stream { break }

        let execDeadline = Date().addingTimeInterval(5.0)
        while recorded.all.count < 2 && Date() < execDeadline {
            await Task.yield()
        }
        #expect(recorded.all.count >= 2)
        release.continuation.finish()

        for await _ in done.stream { break }
        #expect(lease.state == .completed)
        #expect(await produced.value == "flipped-ok")
        #expect(recorded.all == [resolved, resolved])
    }
}
