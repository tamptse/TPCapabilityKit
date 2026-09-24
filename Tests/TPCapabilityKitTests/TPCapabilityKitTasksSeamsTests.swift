import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Tasks Internal Seams Tests")
struct TasksSeamsTests {
    @Test("parked-vs-queued observable while counting policy unchanged")
    func parkedVsQueuedObservable() async {
        let store = DynamicStore()
        let scheduler = TaskScheduler(store: store, concurrencyController: ConcurrencyController())
        let missing = Capability.custom("parkedVsQueued_\(UUID().uuidString)")
        let task = TaskDescriptor(requiredCapabilities: [missing], timeout: 10.0)
        let done = AsyncStream<Void>.makeStream()
        let lease = scheduler.schedule(task, taskExecution: {}, completion: { _ in
            done.continuation.yield()
        })

        #expect(await scheduler.waitForCounts(parked: 1))

        #expect(scheduler.queuedCount == 0)
        #expect(scheduler.parkedCount == 1)
        #expect(scheduler.pendingCount == 1)
        #expect(scheduler.pendingCount == scheduler.queuedCount + scheduler.parkedCount)
        #expect(scheduler.activeCount == 0)

        scheduler.cancel(taskId: task.id)
        for await _ in done.stream { break }

        #expect(lease.state == .expired)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.parkedCount == 0)
        #expect(scheduler.queuedCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("mixed-key contention illustrates FIFO fairness through Tasks seam")
    func mixedKeyContentionFifo() async {
        let store = DynamicStore()
        let capA = Capability.custom("fifoA_\(UUID().uuidString)")
        let capB = Capability.custom("fifoB_\(UUID().uuidString)")
        let pluginId = "fifo_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [capA, capB])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(
            store: store,
            configuration: .init(defaultTimeout: 10.0, maxPerCapability: 10, maxGlobal: 1),
            concurrencyController: ConcurrencyController(maxPerCapability: 10, maxGlobal: 1)
        )

        actor Order {
            var values: [String] = []
            func append(_ value: String) { values.append(value) }
        }
        let order = Order()
        actor Completions {
            var count = 0
            func inc() { count += 1 }
        }
        let completions = Completions()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let drained = AsyncStream<Void>.makeStream()

        let holder = TaskDescriptor(requiredCapabilities: [capA], timeout: 10.0)
        scheduler.schedule(holder, taskExecution: {
            started.continuation.yield()
            for await _ in release.stream { break }
        }, completion: { _ in
            Task {
                await completions.inc()
                drained.continuation.yield()
            }
        })
        for await _ in started.stream { break }

        let first = TaskDescriptor(requiredCapabilities: [capB], timeout: 10.0)
        let second = TaskDescriptor(requiredCapabilities: [capA, capB], timeout: 10.0)
        scheduler.schedule(first, taskExecution: {
            await order.append("first")
        }, completion: { _ in
            Task {
                await completions.inc()
                drained.continuation.yield()
            }
        })
        scheduler.schedule(second, taskExecution: {
            await order.append("second")
        }, completion: { _ in
            Task {
                await completions.inc()
                drained.continuation.yield()
            }
        })

        #expect(await scheduler.waitForCounts(pending: 2))

        release.continuation.finish()
        for await _ in drained.stream {
            if await completions.count == 3 { break }
        }

        #expect(await order.values == ["first", "second"])
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("settlement vs ordering vs admission pinned through Tasks seam")
    func settlementOrderingAdmission() async {
        let store = DynamicStore()
        let pluginId = "soa_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(
            store: store,
            configuration: .init(defaultTimeout: 10.0, maxPerCapability: 10, maxGlobal: 1),
            concurrencyController: ConcurrencyController(maxPerCapability: 10, maxGlobal: 1)
        )

        actor Order {
            var values: [String] = []
            func append(_ value: String) { values.append(value) }
        }
        let order = Order()
        actor Probe {
            var current = 0
            var maxSeen = 0
            func enter() {
                current += 1
                maxSeen = max(maxSeen, current)
            }
            func exit() { current -= 1 }
        }
        let probe = Probe()
        actor Completions {
            var count = 0
            func inc() { count += 1 }
        }
        let completions = Completions()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let drained = AsyncStream<Void>.makeStream()

        let blocker = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 10.0)
        scheduler.schedule(blocker, taskExecution: {
            await probe.enter()
            started.continuation.yield()
            for await _ in release.stream { break }
            await probe.exit()
        }, completion: { _ in
            Task {
                await completions.inc()
                drained.continuation.yield()
            }
        })
        for await _ in started.stream { break }

        let low = TaskDescriptor(
            id: "soa-low_\(UUID().uuidString)",
            requiredCapabilities: [.heavyTask],
            priority: .low,
            timeout: 10.0
        )
        let high = TaskDescriptor(
            id: "soa-high_\(UUID().uuidString)",
            requiredCapabilities: [.heavyTask],
            priority: .high,
            timeout: 10.0
        )
        scheduler.schedule(low, taskExecution: {
            await probe.enter()
            await order.append("low")
            await probe.exit()
        }, completion: { _ in
            Task {
                await completions.inc()
                drained.continuation.yield()
            }
        })
        scheduler.schedule(high, taskExecution: {
            await probe.enter()
            await order.append("high")
            await probe.exit()
        }, completion: { _ in
            Task {
                await completions.inc()
                drained.continuation.yield()
            }
        })

        #expect(await scheduler.waitForCounts(pending: 2))

        release.continuation.finish()
        for await _ in drained.stream {
            if await completions.count == 3 { break }
        }

        #expect(await order.values == ["high", "low"])
        #expect(await probe.maxSeen <= 1)
        #expect(await completions.count == 3)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }
}
