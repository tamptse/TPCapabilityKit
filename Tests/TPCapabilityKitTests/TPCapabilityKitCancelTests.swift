import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Cancel Task Tests")
struct CancelTests {
    @Test("cancel settles expired exactly once")
    func cancelSendsOneEvent() async {
        let store = DynamicStore()
        store.enableDeterministicTime()

        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let done = AsyncStream<Void>.makeStream()
        actor Counter {
            var completions = 0
            func inc() { completions += 1 }
        }
        let counter = Counter()

        let descriptor = TaskDescriptor(requiredCapabilities: [])
        let lease = store.scheduleTask(descriptor, task: {
            started.continuation.yield()
            for await _ in release.stream { break }
        }, completion: { _ in
            Task {
                await counter.inc()
                done.continuation.yield()
            }
        })

        for await _ in started.stream { break }
        store.cancelTask(taskId: lease.task.id)
        for await _ in done.stream { break }
        release.continuation.finish()

        #expect(await counter.completions == 1)
        #expect(lease.isTerminal)
        #expect(lease.state == .expired)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("cancel active task expires lease and calls completion")
    func cancelActiveTask() async {
        let store = DynamicStore()
        store.enableDeterministicTime()
        let pluginId = "CancelActive_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let done = AsyncStream<Void>.makeStream()
        actor State {
            var calls = 0
            var terminal: Bool?
            func record(_ lease: Lease) {
                calls += 1
                terminal = lease.isTerminal
            }
        }
        let state = State()

        let descriptor = TaskDescriptor(
            requiredCapabilities: [.heavyTask],
            timeout: 30.0
        )

        let lease = store.scheduleTask(descriptor, task: {
            started.continuation.yield()
            for await _ in release.stream { break }
        }, completion: { finished in
            Task {
                await state.record(finished)
                done.continuation.yield()
            }
        })

        for await _ in started.stream { break }
        store.cancelTask(taskId: lease.task.id)
        for await _ in done.stream { break }
        release.continuation.finish()

        #expect(lease.state == .expired)
        #expect(lease.isTerminal)
        #expect(await state.calls == 1)
        #expect(await state.terminal == true)
    }

    @Test("cancel parked-at-active task settles expired exactly once")
    func cancelParkedActiveDeliversOnce() async {
        let store = DynamicStore()
        store.enableDeterministicTime()
        let pluginId = "ParkActive_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let done = AsyncStream<Void>.makeStream()
        actor Counter {
            var completions = 0
            func inc() { completions += 1 }
        }
        let counter = Counter()

        let descriptor = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0)
        let lease = store.scheduleTask(descriptor, task: {
            started.continuation.yield()
            for await _ in release.stream { break }
        }, completion: { _ in
            Task {
                await counter.inc()
                done.continuation.yield()
            }
        })

        for await _ in started.stream { break }
        store.cancelTask(taskId: descriptor.id)
        for await _ in done.stream { break }
        release.continuation.finish()

        #expect(await counter.completions == 1)
        #expect(lease.isTerminal)
        #expect(lease.state == .expired)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("storm acquire and cancel drains slots to zero")
    func stormAcquireCancelDrainsSlots() async {
        let store = DynamicStore(configuration: .init(defaultTimeout: 30.0, maxPerCapability: 10, maxGlobal: 5))
        store.enableDeterministicTime()
        let pluginId = "Storm_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let done = AsyncStream<Void>.makeStream()
        let total = 20
        var leases: [Lease] = []
        for _ in 0..<total {
            let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 30.0)
            leases.append(store.scheduleTask(task, task: {
                started.continuation.yield()
                for await _ in release.stream { break }
            }, completion: { _ in
                done.continuation.yield()
            }))
        }

        for await _ in started.stream.prefix(5) { }
        for lease in leases {
            store.cancelTask(taskId: lease.task.id)
        }
        release.continuation.finish()

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
