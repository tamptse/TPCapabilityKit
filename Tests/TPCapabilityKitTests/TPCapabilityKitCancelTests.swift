import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Cancel Task Tests")
struct CancelTests {
    @Test("cancel settles expired exactly once")
    func cancelSendsOneEvent() async {
        let store = DynamicStore()
        let scheduler = TaskScheduler(store: store)

        let started = AsyncStream<Void>.makeStream()
        let done = AsyncStream<Void>.makeStream()
        actor Counter {
            var completions = 0
            func inc() { completions += 1 }
        }
        let counter = Counter()

        let descriptor = TaskDescriptor(requiredCapabilities: [])
        let lease = scheduler.schedule(descriptor, taskExecution: {
            started.continuation.yield()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }, completion: { _ in
            Task {
                await counter.inc()
                done.continuation.yield()
            }
        })

        for await _ in started.stream { break }
        scheduler.cancel(taskId: lease.task.id)
        for await _ in done.stream { break }

        #expect(await counter.completions == 1)
        #expect(lease.isTerminal)
        #expect(lease.state == .expired)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("cancel active task expires lease and calls completion")
    func cancelActiveTask() async {
        let store = DynamicStore()
        let scheduler = TaskScheduler(store: store)
        let pluginId = "CancelActive_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncStream<Void>.makeStream()
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
            timeout: 10.0
        )

        let lease = scheduler.schedule(descriptor, taskExecution: {
            started.continuation.yield()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }, completion: { finished in
            Task {
                await state.record(finished)
                done.continuation.yield()
            }
        })

        for await _ in started.stream { break }
        scheduler.cancel(taskId: lease.task.id)
        for await _ in done.stream { break }

        #expect(lease.state == .expired)
        #expect(lease.isTerminal)
        #expect(await state.calls == 1)
        #expect(await state.terminal == true)
    }

    @Test("cancel parked-at-active task settles expired exactly once")
    func cancelParkedActiveDeliversOnce() async {
        let store = DynamicStore()
        let pluginId = "ParkActive_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(store: store)

        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let done = AsyncStream<Void>.makeStream()
        actor Counter {
            var completions = 0
            func inc() { completions += 1 }
        }
        let counter = Counter()

        let descriptor = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 10.0)
        let lease = scheduler.schedule(descriptor, taskExecution: {
            started.continuation.yield()
            for await _ in release.stream { break }
        }, completion: { _ in
            Task {
                await counter.inc()
                done.continuation.yield()
            }
        })

        for await _ in started.stream { break }
        scheduler.cancel(taskId: descriptor.id)
        for await _ in done.stream { break }
        release.continuation.finish()

        #expect(await counter.completions == 1)
        #expect(lease.isTerminal)
        #expect(lease.state == .expired)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("storm acquire and cancel drains slots to zero")
    func stormAcquireCancelDrainsSlots() async {
        let store = DynamicStore()
        let pluginId = "Storm_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(store: store)

        let started = AsyncStream<Void>.makeStream()
        let done = AsyncStream<Void>.makeStream()
        let total = 20
        var leases: [Lease] = []
        for _ in 0..<total {
            let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 10.0)
            leases.append(scheduler.schedule(task, taskExecution: {
                started.continuation.yield()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }, completion: { _ in
                done.continuation.yield()
            }))
        }

        for await _ in started.stream.prefix(5) { }
        for lease in leases {
            scheduler.cancel(taskId: lease.task.id)
        }

        var finished = 0
        for await _ in done.stream {
            finished += 1
            if finished == total { break }
        }

        #expect(scheduler.activeCount == 0)
        #expect(scheduler.pendingCount == 0)
        #expect(leases.allSatisfy { $0.isTerminal })
    }
}
