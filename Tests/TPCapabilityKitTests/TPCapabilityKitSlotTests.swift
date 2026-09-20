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

    @Test("timeout drains slot exactly once via public counts")
    func timeoutDrainsExactlyOnce() async {
        let store = DynamicStore()
        let pluginId = "SlotTimeout_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(store: store)

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 0.2, maxRetries: 0)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            scheduler.schedule(task, taskExecution: {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }, completion: { _ in done.resume() })
        }

        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }
}
