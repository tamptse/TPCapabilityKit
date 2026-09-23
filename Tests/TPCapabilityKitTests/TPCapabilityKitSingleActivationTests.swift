import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Single Activation Tests")
struct SingleActivationTests {
    @Test("slot-exhausted-while-parked stays pending then completes")
    func slotExhaustedWhileParked() async {
        let store = DynamicStore(configuration: .init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1))
        let cap = Capability.custom("singleActivationParked_\(UUID().uuidString)")
        let pluginId = "SingleActivationParked_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let blockerDone = AsyncStream<Void>.makeStream()
        let secondDone = AsyncStream<Void>.makeStream()
        actor Executions {
            var count = 0
            func increment() { count += 1 }
        }
        let executions = Executions()

        let blocker = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(blocker, task: {
            started.continuation.yield()
            for await _ in release.stream { break }
        }, completion: { _ in blockerDone.continuation.yield() })

        for await _ in started.stream { break }
        #expect(store.activeTaskCount == 1)

        let second = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(second, task: {
            await executions.increment()
        }, completion: { _ in secondDone.continuation.yield() })

        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(await executions.count == 0)
        #expect(store.activeTaskCount == 1)
        #expect(store.pendingTaskCount == 1)

        release.continuation.finish()
        for await _ in blockerDone.stream { break }
        for await _ in secondDone.stream { break }
        #expect(await executions.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("cancel-while-in-slot settles once and frees slot")
    func cancelWhileInSlot() async {
        let store = DynamicStore(configuration: .init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1))
        let cap = Capability.custom("singleActivationCancel_\(UUID().uuidString)")
        let pluginId = "SingleActivationCancel_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let blockerDone = AsyncStream<Void>.makeStream()
        let secondDone = AsyncStream<Void>.makeStream()
        actor State {
            var blockerCalls = 0
            var blockerState: Lease.State?
            var secondCalls = 0
            func recordBlocker(_ lease: Lease) {
                blockerCalls += 1
                blockerState = lease.state
            }
            func recordSecond() { secondCalls += 1 }
        }
        let state = State()

        let blocker = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        let blockerLease = store.scheduleTask(blocker, task: {
            started.continuation.yield()
            for await _ in release.stream { break }
        }, completion: { finished in
            Task {
                await state.recordBlocker(finished)
                blockerDone.continuation.yield()
            }
        })

        for await _ in started.stream { break }
        #expect(store.activeTaskCount == 1)

        let second = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(second, task: {}, completion: { _ in
            Task {
                await state.recordSecond()
                secondDone.continuation.yield()
            }
        })

        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(store.pendingTaskCount == 1)

        store.cancelTask(taskId: blocker.id)
        for await _ in blockerDone.stream { break }
        release.continuation.finish()
        for await _ in secondDone.stream { break }

        #expect(await state.blockerCalls == 1)
        #expect(await state.blockerState == .expired)
        #expect(blockerLease.state == .expired)
        #expect(await state.secondCalls == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
