import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Single Activation Tests")
struct SingleActivationTests {
    @Test("slot-exhausted-while-parked stays pending then completes")
    func slotExhaustedWhileParked() async {
        let cap = Capability.custom("singleActivationParked_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap(
            [cap],
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1),
            deterministic: true,
            prefix: "SingleActivationParked"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        let blockerDone = AsyncGate()
        let secondDone = AsyncGate()
        let executions = Probe()

        let blocker = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(blocker, task: {
            started.signal()
            await release.wait()
        }, completion: { _ in blockerDone.signal() })

        await started.wait()
        #expect(store.activeTaskCount == 1)

        let second = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(second, task: {
            await executions.inc()
        }, completion: { _ in secondDone.signal() })

        for _ in 0..<1000 {
            if store.pendingTaskCount == 1 && store.activeTaskCount == 1 { break }
            await Task.yield()
        }
        #expect(await executions.count == 0)
        #expect(store.activeTaskCount == 1)
        #expect(store.pendingTaskCount == 1)

        release.finish()
        await blockerDone.wait()
        await secondDone.wait()
        #expect(await executions.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("cancel-while-in-slot settles once and frees slot")
    func cancelWhileInSlot() async {
        let cap = Capability.custom("singleActivationCancel_\(UUID().uuidString)")
        let (store, pluginId) = makeStoreWithCap(
            [cap],
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 1),
            deterministic: true,
            prefix: "SingleActivationCancel"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        let blockerDone = AsyncGate()
        let secondDone = AsyncGate()
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
            started.signal()
            await release.wait()
        }, completion: { finished in
            Task {
                await state.recordBlocker(finished)
                blockerDone.signal()
            }
        })

        await started.wait()
        #expect(store.activeTaskCount == 1)

        let second = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(second, task: {}, completion: { _ in
            Task {
                await state.recordSecond()
                secondDone.signal()
            }
        })

        for _ in 0..<1000 {
            if store.pendingTaskCount == 1 { break }
            await Task.yield()
        }
        #expect(store.pendingTaskCount == 1)

        store.cancelTask(taskId: blocker.id)
        await blockerDone.wait()
        release.finish()
        await secondDone.wait()

        #expect(await state.blockerCalls == 1)
        #expect(await state.blockerState == .expired)
        #expect(blockerLease.state == .expired)
        #expect(await state.secondCalls == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
