import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Scoped Slot Tests")
struct ScopedSlotTests {
    @Test("completed tasks drain slots synchronously via public counts")
    func completedDrainsSynchronously() async {
        let store = DynamicStore()
        let pluginId = "SlotDrain_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(store: store)

        let total = 10
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<total {
                group.addTask {
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0)
                        scheduler.schedule(task, taskExecution: {}, completion: { _ in done.resume() })
                    }
                }
            }
        }

        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("cancel active drains slot exactly once via public counts")
    func cancelActiveDrainsExactlyOnce() async {
        let store = DynamicStore()
        let pluginId = "SlotCancel_\(UUID().uuidString)"
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
        scheduler.schedule(descriptor, taskExecution: {
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
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("late unregister during slot contention never executes")
    func lateUnregisterNeverExecutes() async {
        let store = DynamicStore(configuration: .init(defaultTimeout: 5.0, maxPerCapability: 5, maxGlobal: 1))
        store.enableDeterministicTime()
        let pluginId = "SlotGate_\(UUID().uuidString)"
        let cap = Capability.custom("slotGate_\(UUID().uuidString)")
        store.registerCapability(for: pluginId, capabilities: [cap])

        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let blockerDone = AsyncStream<Void>.makeStream()
        let gatedDone = AsyncStream<Void>.makeStream()
        actor Executions {
            var count = 0
            func inc() { count += 1 }
        }
        let executions = Executions()

        let blocker = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(blocker, task: {
            started.continuation.yield()
            for await _ in release.stream { break }
        }, completion: { _ in blockerDone.continuation.yield() })

        for await _ in started.stream { break }

        let gated = TaskDescriptor(requiredCapabilities: [cap], timeout: 5.0, maxRetries: 0)
        let gatedLease = store.scheduleTask(gated, task: {
            Task {
                await executions.inc()
            }
        }, completion: { _ in gatedDone.continuation.yield() })

        store.unregisterCapability(for: pluginId)
        release.continuation.finish()

        for await _ in blockerDone.stream { break }
        await store.waitForDeterministicWaiters(count: 1)
        await store.advanceTime(by: 5.0)
        for await _ in gatedDone.stream { break }

        #expect(await executions.count == 0)
        #expect(gatedLease.state == .expired)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("cancel during slot-acquire suspension never executes")
    func cancelDuringAcquireNeverExecutes() async {
        let store = DynamicStore(configuration: .init(defaultTimeout: 5.0, maxPerCapability: 5, maxGlobal: 1))
        store.enableDeterministicTime()
        let pluginId = "SlotCancelFlight_\(UUID().uuidString)"
        let cap = Capability.custom("slotCancelFlight_\(UUID().uuidString)")
        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }

        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let blockerDone = AsyncStream<Void>.makeStream()

        let blocker = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0)
        store.scheduleTask(blocker, task: {
            started.continuation.yield()
            for await _ in release.stream { break }
        }, completion: { _ in blockerDone.continuation.yield() })

        for await _ in started.stream { break }
        #expect(store.activeTaskCount == 1)

        let gated = TaskDescriptor(requiredCapabilities: [cap], timeout: 30.0, maxRetries: 0)
        let gatedDone = AsyncStream<Void>.makeStream()
        actor GatedState {
            var executions = 0
            var terminal: Lease.State?
            func recordExec() { executions += 1 }
            func recordTerminal(_ state: Lease.State) { terminal = state }
        }
        let gatedState = GatedState()
        let gatedLease = store.scheduleTask(gated, task: {
            Task {
                await gatedState.recordExec()
            }
        }, completion: { finished in
            Task {
                await gatedState.recordTerminal(finished.state)
                gatedDone.continuation.yield()
            }
        })

        #expect(store.pendingTaskCount == 1)
        store.cancelTask(taskId: gated.id)
        release.continuation.finish()

        for await _ in gatedDone.stream { break }
        #expect(await gatedState.executions == 0)
        #expect(await gatedState.terminal == .expired)
        #expect(gatedLease.state == .expired)
        for await _ in blockerDone.stream { break }
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
