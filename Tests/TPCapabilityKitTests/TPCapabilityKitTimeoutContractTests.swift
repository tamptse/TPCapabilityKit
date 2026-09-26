import Testing
import Foundation
@testable import TPCapabilityKit
@testable import TPCapabilityKitBridge

@Suite("Timeout Contract Tests")
struct TimeoutContractTests {
    @Test("Swift nil timeout resolves to the configured default through shared expiry")
    func swiftNilResolvesToConfiguredDefault() async {
        let configured: TimeInterval = 11.25
        let task = TaskDescriptor(
            requiredCapabilities: [.custom("TimeoutContractNil_\(UUID().uuidString)")]
        )
        #expect(task.timeout == nil)

        let explicitTask = TaskDescriptor(
            requiredCapabilities: [.custom("TimeoutContractNilExplicit_\(UUID().uuidString)")],
            timeout: 7.5
        )
        #expect(explicitTask.timeout == 7.5)

        let storeA = DynamicStore()
        let clockA = makeDeterministicClock()
        let schedulerA = makeScheduler(
            store: storeA,
            configuration: .init(defaultTimeout: configured, maxPerCapability: 5, maxGlobal: 20),
            clock: clockA
        )
        let doneA = AsyncGate()
        let leaseA = schedulerA.schedule(task, taskExecution: {}, completion: { _ in
            doneA.signal()
        })
        await clockA.waitForWaiters(count: 1)
        await clockA.advance(by: 7.5)
        for _ in 0..<20 { await Task.yield() }
        #expect(!leaseA.isTerminal)
        await clockA.advance(by: configured - 7.5)
        await doneA.wait()
        #expect(leaseA.state == .expired)

        let storeB = DynamicStore()
        let clockB = makeDeterministicClock()
        let schedulerB = makeScheduler(
            store: storeB,
            configuration: .init(defaultTimeout: configured, maxPerCapability: 5, maxGlobal: 20),
            clock: clockB
        )
        let doneB = AsyncGate()
        let leaseB = schedulerB.schedule(explicitTask, taskExecution: {}, completion: { _ in
            doneB.signal()
        })
        await clockB.waitForWaiters(count: 1)
        await clockB.advance(by: 7.5)
        await doneB.wait()
        #expect(leaseB.state == .expired)

        let storeC = DynamicStore()
        let clockC = makeDeterministicClock()
        let schedulerC = makeScheduler(
            store: storeC,
            configuration: .init(defaultTimeout: 12.5, maxPerCapability: 5, maxGlobal: 20),
            clock: clockC
        )
        let doneC = AsyncGate()
        let leaseC = schedulerC.schedule(task, taskExecution: {}, completion: { _ in
            doneC.signal()
        })
        await clockC.waitForWaiters(count: 1)
        await clockC.advance(by: configured)
        for _ in 0..<20 { await Task.yield() }
        #expect(!leaseC.isTerminal)
        await clockC.advance(by: 12.5 - configured)
        await doneC.wait()
        #expect(leaseC.state == .expired)
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

    @Test("ObjC negative timeout means unspecified and resolves at shared expiry")
    func objcNegativeMeansUnspecifiedResolvesAtDeadline() async {
        let cap = "TimeoutContractNegative_\(UUID().uuidString)"
        let configured: TimeInterval = 9.75

        let descriptor = ObjcTaskDescriptor(capabilities: [cap], timeout: -1)
        #expect(descriptor.underlying.timeout == nil)
        #expect(!descriptor.hasExplicitTimeout)
        #expect(descriptor.timeout == 30.0)

        let client = ObjcTaskDescriptor(
            clientId: "contract-negative-\(UUID().uuidString)",
            capabilities: [cap],
            timeout: -1
        )
        #expect(client.underlying.timeout == nil)
        #expect(!client.hasExplicitTimeout)

        let store = DynamicStore()
        let clock = makeDeterministicClock()
        let scheduler = makeScheduler(
            store: store,
            configuration: .init(defaultTimeout: configured, maxPerCapability: 5, maxGlobal: 20),
            clock: clock
        )
        let done = AsyncGate()
        let lease = scheduler.schedule(descriptor.underlying, taskExecution: {}, completion: { _ in
            done.signal()
        })
        await clock.waitForWaiters(count: 1)
        await clock.advance(by: configured)
        await done.wait()
        #expect(lease.state == .expired)
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
