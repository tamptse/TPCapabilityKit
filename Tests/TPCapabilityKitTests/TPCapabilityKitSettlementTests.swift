import Testing
import Foundation
@testable import TPCapabilityKit

@Suite("Settlement Tests")
struct SettlementTests {
    @Test("scheduleAndWait preserves waiter across retry")
    func preservesWaiterAcrossRetry() async {
        let store = DynamicStore()
        let pluginId = "SettleRetry_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(store: store)

        let task = TaskDescriptor(
            requiredCapabilities: [.heavyTask],
            timeout: 5.0,
            maxRetries: 1
        )

        actor Attempts {
            var count = 0
            func next() -> Int {
                count += 1
                return count
            }
        }
        let attempts = Attempts()
        struct FirstFailed: Error {}

        let result = await scheduler.scheduleAndWait(task) { () async throws -> String in
            let n = await attempts.next()
            if n == 1 { throw FirstFailed() }
            return "recovered"
        }

        #expect(result == "recovered")
    }

    @Test("schedule preserves completion across retry")
    func preservesCompletionAcrossRetry() async {
        let store = DynamicStore()
        let pluginId = "SettleCompletion_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(store: store)

        let task = TaskDescriptor(
            requiredCapabilities: [.heavyTask],
            timeout: 5.0,
            maxRetries: 1
        )

        actor Counter {
            var completions = 0
            func record() { completions += 1 }
        }
        let counter = Counter()

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            scheduler.schedule(task, taskExecution: {}, completion: { _ in
                Task {
                    await counter.record()
                    done.resume()
                }
            })
        }

        #expect(await counter.completions == 1)
    }

    @Test("completed delivers exactly once")
    func completedExactlyOnce() async {
        let store = DynamicStore()
        let pluginId = "SettleCompleted_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(store: store)

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0)
        let result = await scheduler.scheduleAndWait(task) { "ok" }
        #expect(result == "ok")

        actor Counter {
            var count = 0
            func inc() { count += 1 }
        }
        let counter = Counter()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            scheduler.schedule(task, taskExecution: {}, completion: { _ in
                Task {
                    await counter.inc()
                    done.resume()
                }
            })
        }
        #expect(await counter.count == 1)
    }

    @Test("failed delivers exactly once without retry")
    func failedExactlyOnce() async {
        let store = DynamicStore()
        let pluginId = "SettleFailed_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(store: store)

        struct Boom: Error {}
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 0)
        let result: String? = await scheduler.scheduleAndWait(task) { () async throws -> String in
            throw Boom()
        }
        #expect(result == nil)
    }

    @Test("expired delivers exactly once on timeout")
    func expiredExactlyOnce() async {
        let store = DynamicStore()
        let pluginId = "SettleExpired_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(store: store)

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 0.2, maxRetries: 0)
        actor Counter {
            var completions = 0
            var state: Lease.State?
            func record(_ lease: Lease) {
                completions += 1
                state = lease.state
            }
        }
        let counter = Counter()

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            scheduler.schedule(task, taskExecution: {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }, completion: { lease in
                Task {
                    await counter.record(lease)
                    done.resume()
                }
            })
        }

        #expect(await counter.completions == 1)
        #expect(await counter.state == .expired)
    }

    @Test("schedule Void task completes with completion delivered")
    func voidScheduleCompletes() async {
        let store = DynamicStore()
        let pluginId = "SettleVoid_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(store: store)

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0)
        actor State {
            var calls = 0
            var terminal: Lease.State?
            func record(_ lease: Lease) {
                calls += 1
                terminal = lease.state
            }
        }
        let state = State()

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            scheduler.schedule(task, taskExecution: {}, completion: { lease in
                Task {
                    await state.record(lease)
                    done.resume()
                }
            })
        }

        #expect(await state.calls == 1)
        #expect(await state.terminal == .completed)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test("cancel delivers exactly one expired completion")
    func cancelExactlyOnce() async {
        let store = DynamicStore()
        let pluginId = "SettleCancel_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(store: store)

        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let done = AsyncStream<Void>.makeStream()
        let expired = AsyncStream<Void>.makeStream()
        actor Counter {
            var completions = 0
            func inc() { completions += 1 }
        }
        let counter = Counter()
        let cancellable = scheduler.events.sink { event in
            if case .taskExpired = event {
                expired.continuation.yield()
            }
        }
        defer { cancellable.cancel() }

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
        for await _ in expired.stream { break }
    }
}
