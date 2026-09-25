import Testing
import Foundation
@testable import TPCapabilityKit
@testable import TPCapabilityKitBridge

@Suite("Timeout Contract Tests")
struct TimeoutContractTests {
    @Test("Swift nil timeout resolves to the configured default at Deadline construction")
    func swiftNilResolvesToConfiguredDefault() {
        let clock = makeDeterministicClock()
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
        #expect(plain.timeout == 30.0)
        #expect(plain.hasExplicitTimeout)

        let client = ObjcTaskDescriptor(
            clientId: "contract-omitted-\(UUID().uuidString)",
            capabilities: [cap]
        )
        #expect(client.underlying.timeout == 30.0)
        #expect(client.timeout == 30.0)
        #expect(client.hasExplicitTimeout)
    }

    @Test("ObjC negative timeout means unspecified and resolves at Deadline construction")
    func objcNegativeMeansUnspecifiedResolvesAtDeadline() {
        let cap = "TimeoutContractNegative_\(UUID().uuidString)"
        let configured: TimeInterval = 9.75
        let clock = makeDeterministicClock()

        let descriptor = ObjcTaskDescriptor(capabilities: [cap], timeout: -1)
        #expect(descriptor.underlying.timeout == nil)
        #expect(!descriptor.hasExplicitTimeout)
        #expect(descriptor.timeout == 30.0)

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
        let clock = makeDeterministicClock()
        let scheduler = makeScheduler(
            store: store,
            configuration: .init(defaultTimeout: resolved, maxPerCapability: 5, maxGlobal: 20),
            clock: clock
        )

        let cap = Capability.custom("TimeoutContractShared_\(UUID().uuidString)")
        let task = TaskDescriptor(requiredCapabilities: [cap])
        #expect(task.timeout == nil)
        #expect(TaskScheduler.Deadline(task: task, default: resolved, clock: clock).timeout == resolved)

        actor Produced {
            var value: String?
            func store(_ newValue: String) { value = newValue }
        }
        let produced = Produced()
        let started = AsyncGate()
        let release = AsyncGate()
        let done = AsyncGate()
        let lease = scheduler.schedule(task, taskExecution: {
            started.signal()
            await release.wait()
            await produced.store("flipped-ok")
        }, completion: { _ in
            done.signal()
        })

        await clock.waitForWaiters(count: 1)

        let pluginId = "TimeoutContractShared_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }

        await started.wait()

        await clock.waitForWaiters(count: 1)
        release.finish()

        await done.wait()
        #expect(lease.state == .completed)
        #expect(await produced.value == "flipped-ok")
    }
}
