import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Cancel Task Tests")
struct CancelTests {
    @Test("cancel settles expired exactly once")
    func cancelSendsOneEvent() async {
        let store = DynamicStore()
        store.enableDeterministicTime()

        let started = AsyncGate()
        let release = AsyncGate()
        let done = AsyncGate()
        let counter = Probe()

        let descriptor = TaskDescriptor(requiredCapabilities: [])
        let lease = store.scheduleTask(descriptor, task: {
            started.signal()
            await release.wait()
        }, completion: { _ in
            Task {
                await counter.inc()
                done.signal()
            }
        })

        await started.wait()
        store.cancelTask(taskId: lease.task.id)
        await done.wait()
        release.finish()

        #expect(await counter.count == 1)
        #expect(lease.isTerminal)
        #expect(lease.state == .expired)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("cancel active task expires lease and calls completion")
    func cancelActiveTask() async {
        let (store, pluginId) = makeStoreWithCap(
            [.heavyTask],
            deterministic: true,
            prefix: "CancelActive"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        let done = AsyncGate()
        let state = Probe()

        let descriptor = TaskDescriptor(
            requiredCapabilities: [.heavyTask],
            timeout: 30.0
        )

        let lease = store.scheduleTask(descriptor, task: {
            started.signal()
            await release.wait()
        }, completion: { finished in
            Task {
                await state.record(finished)
                done.signal()
            }
        })

        await started.wait()
        store.cancelTask(taskId: lease.task.id)
        await done.wait()
        release.finish()

        #expect(lease.state == .expired)
        #expect(lease.isTerminal)
        #expect(await state.count == 1)
        #expect(await state.lastLease?.isTerminal == true)
    }

    @Test("cancel parked-at-active task settles expired exactly once")
    func cancelParkedActiveDeliversOnce() async {
        let (store, pluginId) = makeStoreWithCap(
            [.heavyTask],
            deterministic: true,
            prefix: "ParkActive"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        let done = AsyncGate()
        let counter = Probe()

        let descriptor = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0)
        let lease = store.scheduleTask(descriptor, task: {
            started.signal()
            await release.wait()
        }, completion: { _ in
            Task {
                await counter.inc()
                done.signal()
            }
        })

        await started.wait()
        store.cancelTask(taskId: descriptor.id)
        await done.wait()
        release.finish()

        #expect(await counter.count == 1)
        #expect(lease.isTerminal)
        #expect(lease.state == .expired)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("storm acquire and cancel drains slots to zero")
    func stormAcquireCancelDrainsSlots() async {
        let (store, pluginId) = makeStoreWithCap(
            [.heavyTask],
            configuration: .init(defaultTimeout: 30.0, maxPerCapability: 10, maxGlobal: 5),
            deterministic: true,
            prefix: "Storm"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncGate()
        let release = AsyncGate()
        let done = AsyncGate()
        let total = 20
        var leases: [Lease] = []
        for _ in 0..<total {
            let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0)
            leases.append(store.scheduleTask(task, task: {
                started.signal()
                await release.wait()
            }, completion: { _ in
                done.signal()
            }))
        }

        for await _ in started.stream.prefix(5) { }
        for lease in leases {
            store.cancelTask(taskId: lease.task.id)
        }
        release.finish()

        var finished = 0
        for await _ in done.stream {
            finished += 1
            if finished == total { break }
        }

        #expect(store.activeTaskCount == 0)
        #expect(store.pendingTaskCount == 0)
        #expect(leases.allSatisfy { $0.isTerminal })
    }
}
