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
        let scheduler = TaskScheduler(store: store, concurrencyController: ConcurrencyController())

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
        let scheduler = TaskScheduler(store: store, concurrencyController: ConcurrencyController())

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
        let scheduler = TaskScheduler(store: store, concurrencyController: ConcurrencyController())

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
        let scheduler = TaskScheduler(store: store, concurrencyController: ConcurrencyController())

        struct Boom: Error {}
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 0)
        let result: String? = await scheduler.scheduleAndWait(task) { () async throws -> String in
            throw Boom()
        }
        #expect(result == nil)
    }

    @Test("schedule Void task completes with completion delivered")
    func voidScheduleCompletes() async {
        let store = DynamicStore()
        let pluginId = "SettleVoid_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(store: store, concurrencyController: ConcurrencyController())

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
        let scheduler = TaskScheduler(store: store, concurrencyController: ConcurrencyController())

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

    @Test("same-id sequential reuse delivers both completions")
    func sameIdSequentialReuse() async {
        let store = DynamicStore()
        let pluginId = "SameIdReuse_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }

        let id = "reuse_\(UUID().uuidString)"
        actor Counter {
            var completions = 0
            func inc() { completions += 1 }
        }
        let counter = Counter()

        func runOnce() async -> Lease {
            await withCheckedContinuation { (done: CheckedContinuation<Lease, Never>) in
                store.scheduleTask(
                    TaskDescriptor(id: id, requiredCapabilities: [.heavyTask], timeout: 5.0),
                    task: {},
                    completion: { finished in
                        Task {
                            await counter.inc()
                            done.resume(returning: finished)
                        }
                    }
                )
            }
        }

        let first = await runOnce()
        #expect(first.isTerminal)
        #expect(first.state == .completed)
        #expect(await counter.completions == 1)

        let second = await runOnce()
        #expect(second.isTerminal)
        #expect(second.state == .completed)
        #expect(await counter.completions == 2)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test("same-id overwrite expires the old row once and the new row completes")
    func sameIdOverwriteSettlesOldRow() async {
        let store = DynamicStore()
        let pluginId = "SameIdOverwrite_\(UUID().uuidString)"
        let cap = Capability.custom("overwrite_\(UUID().uuidString)")

        let id = "overwrite_\(UUID().uuidString)"
        actor State {
            var oldCalls = 0
            var oldState: Lease.State?
            var newCalls = 0
            var newState: Lease.State?
            func recordOld(_ lease: Lease) {
                oldCalls += 1
                oldState = lease.state
            }
            func recordNew(_ lease: Lease) {
                newCalls += 1
                newState = lease.state
            }
        }
        let state = State()
        let done = AsyncStream<Void>.makeStream()

        store.scheduleTask(
            TaskDescriptor(id: id, requiredCapabilities: [cap], timeout: 10.0),
            task: {},
            completion: { finished in
                Task {
                    await state.recordOld(finished)
                    done.continuation.yield()
                }
            }
        )
        store.scheduleTask(
            TaskDescriptor(id: id, requiredCapabilities: [cap], timeout: 10.0),
            task: {},
            completion: { finished in
                Task {
                    await state.recordNew(finished)
                    done.continuation.yield()
                }
            }
        )

        store.registerCapability(for: pluginId, capabilities: [cap])
        defer { store.unregisterCapability(for: pluginId) }

        for await _ in done.stream {
            let oldCalls = await state.oldCalls
            let newCalls = await state.newCalls
            if oldCalls == 1 && newCalls == 1 { break }
        }

        #expect(await state.oldCalls == 1)
        #expect(await state.oldState == .expired)
        #expect(await state.newCalls == 1)
        #expect(await state.newState == .completed)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
