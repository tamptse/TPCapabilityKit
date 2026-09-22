import Testing
import Foundation
@testable import TPCapabilityKit

struct TaskPriorityTests {
    @Test func priorityOrdering() {
        #expect(TaskPriority.background < TaskPriority.low)
        #expect(TaskPriority.low < TaskPriority.normal)
        #expect(TaskPriority.normal < TaskPriority.high)
        #expect(TaskPriority.high < TaskPriority.critical)
    }

    @Test func priorityDescription() {
        #expect(TaskPriority.normal.description == "normal")
        #expect(TaskPriority.critical.description == "critical")
    }
}

struct TaskDescriptorTests {
    @Test func defaultValues() {
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask])
        #expect(task.requiredCapabilities == [.heavyTask])
        #expect(task.priority == .normal)
        #expect(task.timeout == nil)
        #expect(task.maxRetries == 0)
        #expect(task.metadata.isEmpty)
    }

    @Test func customValues() {
        let task = TaskDescriptor(
            id: "custom-id",
            requiredCapabilities: [.networkAccess, .backgroundExecution],
            priority: .critical,
            timeout: 60.0,
            maxRetries: 3,
            metadata: ["source": "test"]
        )
        #expect(task.id == "custom-id")
        #expect(task.priority == .critical)
        #expect(task.timeout == 60.0)
        #expect(task.maxRetries == 3)
        #expect(task.metadata["source"] == "test")
    }
}

struct LeaseTests {
    @Test func scheduledTaskCompletesThroughSeam() async {
        let store = DynamicStore()
        let pluginId = "LeaseSeamComplete_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(store: store)

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0)
        let lease = await withCheckedContinuation { (done: CheckedContinuation<Lease, Never>) in
            scheduler.schedule(task, taskExecution: {}, completion: { finished in
                done.resume(returning: finished)
            })
        }

        #expect(lease.state == .completed)
        #expect(lease.isTerminal)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test func throwingExecutionFailsThroughSeam() async {
        let store = DynamicStore()
        let pluginId = "LeaseSeamFail_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(store: store)

        actor Attempts {
            var count = 0
            func next() -> Int {
                count += 1
                return count
            }
        }
        let attempts = Attempts()
        struct Boom: Error {}
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 0)
        let result: String? = await scheduler.scheduleAndWait(task) { () async throws -> String in
            await attempts.next()
            throw Boom()
        }

        #expect(result == nil)
        #expect(await attempts.count == 1)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test func retryBudgetExhaustsThroughSeam() async {
        let store = DynamicStore()
        let pluginId = "LeaseSeamBudget_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(store: store)

        actor Attempts {
            var count = 0
            func next() -> Int {
                count += 1
                return count
            }
        }
        let attempts = Attempts()
        struct AlwaysFails: Error {}
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 2)
        let result: String? = await scheduler.scheduleAndWait(task) { () async throws -> String in
            await attempts.next()
            throw AlwaysFails()
        }

        #expect(result == nil)
        #expect(await attempts.count == 3)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test func timeoutExpiresThroughSeam() async {
        let store = DynamicStore()
        let pluginId = "LeaseSeamExpire_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(store: store)

        actor Counter {
            var completions = 0
            func inc() { completions += 1 }
        }
        let counter = Counter()
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 0.2, maxRetries: 0)
        let lease = await withCheckedContinuation { (done: CheckedContinuation<Lease, Never>) in
            scheduler.schedule(task, taskExecution: {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }, completion: { finished in
                Task {
                    await counter.inc()
                    done.resume(returning: finished)
                }
            })
        }

        #expect(await counter.completions == 1)
        #expect(lease.state == .expired)
        #expect(lease.isTerminal)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test func cancelPendingSettlesExpiredThroughSeam() async {
        let store = DynamicStore()
        let scheduler = TaskScheduler(store: store)

        actor Counter {
            var completions = 0
            func inc() { completions += 1 }
        }
        let counter = Counter()
        let task = TaskDescriptor(
            requiredCapabilities: [.custom("LeaseSeamCancel_\(UUID().uuidString)")],
            timeout: 5.0
        )
        let lease = await withCheckedContinuation { (done: CheckedContinuation<Lease, Never>) in
            scheduler.schedule(task, taskExecution: {}, completion: { finished in
                Task {
                    await counter.inc()
                    done.resume(returning: finished)
                }
            })
            scheduler.cancel(taskId: task.id)
        }

        #expect(await counter.completions == 1)
        #expect(lease.state == .expired)
        #expect(lease.isTerminal)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test func flakyExecutionRecoversThroughSeam() async {
        let store = DynamicStore()
        let pluginId = "LeaseSeamRetry_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(store: store)

        actor Attempts {
            var count = 0
            func next() -> Int {
                count += 1
                return count
            }
        }
        let attempts = Attempts()
        struct FirstFails: Error {}
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 1)
        let result = await scheduler.scheduleAndWait(task) { () async throws -> String in
            let n = await attempts.next()
            if n == 1 { throw FirstFails() }
            return "recovered"
        }

        #expect(result == "recovered")
        #expect(await attempts.count == 2)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }
}

struct ConcurrencyControllerTests {
    @Test func acquireAndRelease() async {
        let store = DynamicStore()
        let pluginId = "ControllerAcquire_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(store: store)

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0)
        let lease = await withCheckedContinuation { (done: CheckedContinuation<Lease, Never>) in
            scheduler.schedule(task, taskExecution: {}, completion: { finished in
                done.resume(returning: finished)
            })
        }

        #expect(lease.state == .completed)
        #expect(lease.isTerminal)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test func doubleReleaseIsSafe() async {
        let store = DynamicStore()
        let pluginId = "ControllerIdempotent_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(
            store: store,
            configuration: TaskScheduler.Configuration(maxPerCapability: 2, maxGlobal: 1)
        )

        let id = "idempotent_\(UUID().uuidString)"
        let first = TaskDescriptor(id: id, requiredCapabilities: [.heavyTask], timeout: 5.0)
        let firstResult = await scheduler.scheduleAndWait(first) { "first" }
        #expect(firstResult == "first")
        scheduler.cancel(taskId: id)
        scheduler.cancel(taskId: id)
        scheduler.cancel(taskId: "unknown")

        let secondResult: String? = await scheduler.scheduleAndWait(first) { "second" }
        #expect(secondResult == "second")
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test func respectsGlobalLimit() async {
        let store = DynamicStore()
        let pluginId = "ControllerGlobal_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(
            store: store,
            configuration: TaskScheduler.Configuration(maxPerCapability: 10, maxGlobal: 2)
        )

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
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let parkedDone = AsyncStream<Void>.makeStream()
        actor Completions {
            var count = 0
            var expiredId: String?
            func record(_ lease: Lease) {
                count += 1
                if lease.state == .expired { expiredId = lease.task.id }
            }
        }
        let completions = Completions()

        let holdA = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 10.0)
        let holdB = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 10.0)
        for hold in [holdA, holdB] {
            scheduler.schedule(hold, taskExecution: {
                await probe.enter()
                started.continuation.yield()
                for await _ in release.stream { break }
                await probe.exit()
            }, completion: { lease in
                Task {
                    await completions.record(lease)
                    parkedDone.continuation.yield()
                }
            })
        }
        for await _ in started.stream { break }
        for await _ in started.stream { break }
        #expect(scheduler.activeCount == 2)

        let parkedId = "parked_\(UUID().uuidString)"
        let parked = TaskDescriptor(id: parkedId, requiredCapabilities: [.heavyTask], timeout: 10.0)
        scheduler.schedule(parked, taskExecution: {
            await probe.enter()
            await probe.exit()
        }, completion: { lease in
            Task {
                await completions.record(lease)
                parkedDone.continuation.yield()
            }
        })

        let cancelledId = "cancelled_\(UUID().uuidString)"
        let cancelled = TaskDescriptor(id: cancelledId, requiredCapabilities: [.heavyTask], timeout: 10.0)
        let cancelledLease = scheduler.schedule(cancelled, taskExecution: {}, completion: { lease in
            Task {
                await completions.record(lease)
                parkedDone.continuation.yield()
            }
        })
        scheduler.cancel(taskId: cancelledId)
        for await _ in parkedDone.stream { break }
        #expect(cancelledLease.state == .expired)
        #expect(cancelledLease.isTerminal)

        release.continuation.finish()
        for await _ in parkedDone.stream {
            if await completions.count == 4 { break }
        }

        #expect(await completions.count == 4)
        #expect(await completions.expiredId == cancelledId)
        #expect(await probe.maxSeen <= 2)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }

    @Test func respectsPerCapabilityLimit() async {
        // Argument: holder-started gate + synchronous enqueue of 3 contenders with
        // no suspension points before release prove contention existed under a held
        // per-cap slot; entry-solitude (each contender sees activeCount==1 at entry)
        // + probe maxSeen<=1 + full drain prove serialization. In-body yields are
        // workload-wideners, not gates: they widen the overlap window so a broken
        // controller admitting 2 concurrently would surface as entry-activeCount>1
        // or maxSeen>1 (same falsifiability standard as the approved global test's
        // maxSeen bound). No pre-release assertion reads scheduler queue counts:
        // schedule() spawns an unstructured Task that dequeues pending->parked
        // concurrently, so pendingCount here is timing-dependent (observed 0-1 in
        // solo runs); the deterministic pre-release proof is local lease count.
        let store = DynamicStore()
        let pluginId = "ControllerPerCap_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(
            store: store,
            configuration: TaskScheduler.Configuration(maxPerCapability: 1, maxGlobal: 10)
        )

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
        actor Entries {
            var count = 0
            func inc() { count += 1 }
        }
        let entries = Entries()
        actor EntryActiveCounts {
            var values: [Int] = []
            func append(_ value: Int) { values.append(value) }
        }
        let entryActiveCounts = EntryActiveCounts()
        actor Completions {
            var count = 0
            func record() { count += 1 }
        }
        let completions = Completions()

        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let drained = AsyncStream<Void>.makeStream()

        let holder = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 10.0)
        scheduler.schedule(holder, taskExecution: {
            await probe.enter()
            started.continuation.yield()
            for await _ in release.stream { break }
            await probe.exit()
        }, completion: { _ in
            Task {
                await completions.record()
                drained.continuation.yield()
            }
        })
        for await _ in started.stream { break }
        #expect(scheduler.activeCount == 1)

        let totalContenders = 3
        var contenderLeases: [Lease] = []
        for _ in 0..<totalContenders {
            let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 10.0)
            let lease = scheduler.schedule(task, taskExecution: {
                let seen = scheduler.activeCount
                await entryActiveCounts.append(seen)
                await probe.enter()
                await Task.yield()
                await Task.yield()
                await Task.yield()
                await entries.inc()
                await probe.exit()
            }, completion: { _ in
                Task {
                    await completions.record()
                    drained.continuation.yield()
                }
            })
            contenderLeases.append(lease)
        }
        #expect(contenderLeases.count == totalContenders)

        release.continuation.finish()
        for await _ in drained.stream {
            if await completions.count == totalContenders + 1 { break }
        }

        #expect(await entries.count == totalContenders)
        #expect(await entryActiveCounts.values.count == totalContenders)
        #expect(await entryActiveCounts.values.allSatisfy { $0 == 1 })
        #expect(await probe.maxSeen <= 1)
        #expect(await completions.count == totalContenders + 1)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.activeCount == 0)
    }
}

struct TaskSchedulerTests {
    @Test func scheduleAndComplete() async {
        let store = DynamicStore()
        let pluginId = "SchedulerPlugin_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])

        let scheduler = TaskScheduler(store: store)

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask])
        let result = await scheduler.scheduleAndWait(task) {
            return "ScheduledResult"
        }

        #expect(result == "ScheduledResult")
    }

    @Test func scheduleWithoutCapabilityReturnsNil() async {
        let store = DynamicStore()
        let scheduler = TaskScheduler(store: store)

        let task = TaskDescriptor(
            requiredCapabilities: [.custom("NonExistent_\(UUID().uuidString)")],
            timeout: 0.5
        )
        let result = await scheduler.scheduleAndWait(task) {
            return "ShouldNotRun"
        }

        #expect(result == nil)
    }

    @Test func priorityOrdering() async {
        let store = DynamicStore()
        let pluginId = "PriorityPlugin_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])

        let scheduler = TaskScheduler(store: store)

        actor ExecutionTracker {
            var order: [String] = []
            func append(_ value: String) { order.append(value) }
        }
        let tracker = ExecutionTracker()
        let done = AsyncStream<Void>.makeStream()

        let task1 = TaskDescriptor(
            id: "low",
            requiredCapabilities: [.heavyTask],
            priority: .low
        )
        let task2 = TaskDescriptor(
            id: "high",
            requiredCapabilities: [.heavyTask],
            priority: .high
        )

        scheduler.schedule(task2, taskExecution: {
            await tracker.append("high")
        }, completion: { _ in done.continuation.yield() })
        scheduler.schedule(task1, taskExecution: {
            await tracker.append("low")
        }, completion: { _ in done.continuation.yield() })

        var finished = 0
        for await _ in done.stream {
            finished += 1
            if finished == 2 { break }
        }

        let order = await tracker.order
        #expect(order.first == "high")
        #expect(order.count == 2)
    }

    @Test func cancelTask() async {
        let store = DynamicStore()
        let scheduler = TaskScheduler(store: store)

        let task = TaskDescriptor(
            id: "cancelable",
            requiredCapabilities: [.custom("NeverAvailable_\(UUID().uuidString)")],
            timeout: 5.0
        )

        let done = AsyncStream<Void>.makeStream()
        let lease = scheduler.schedule(task, taskExecution: {
            // This should never execute
        }, completion: { _ in done.continuation.yield() })
        scheduler.cancel(taskId: task.id)

        for await _ in done.stream { break }
        #expect(lease.isTerminal)
    }

    @Test func capabilityRevocationDuringExecution() async {
        let store = DynamicStore()
        let pluginId = "TOCTOU_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])

        let scheduler = TaskScheduler(store: store)

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0)

        let started = AsyncStream<Void>.makeStream()
        let done = AsyncStream<Void>.makeStream()
        let lease = scheduler.schedule(task, taskExecution: {
            started.continuation.yield()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }, completion: { _ in done.continuation.yield() })

        for await _ in started.stream { break }

        // Revoke capability while task is running
        store.unregisterCapability(for: pluginId)

        for await _ in done.stream { break }

        // Task should still complete (revocation doesn't kill running tasks)
        #expect(lease.isTerminal)
    }

    @Test func voidTaskCompletesWithoutRetry() async {
        let store = DynamicStore()
        let pluginId = "RetryPlugin_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }

        let scheduler = TaskScheduler(store: store)
        let task = TaskDescriptor(
            requiredCapabilities: [.heavyTask],
            timeout: 5.0,
            maxRetries: 1
        )

        let done = AsyncStream<Void>.makeStream()
        let lease = scheduler.schedule(task, taskExecution: {
        }, completion: { _ in done.continuation.yield() })

        for await _ in done.stream { break }

        #expect(lease.retryCount == 0)
        #expect(lease.state == .completed)
        #expect(lease.isTerminal)
    }

    @Test func retryPreservesWaiterThroughStoreFacade() async {
        let store = DynamicStore()
        let pluginId = "FacadeRetry_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }

        let task = TaskDescriptor(
            requiredCapabilities: [.heavyTask],
            timeout: 5.0,
            maxRetries: 2
        )

        actor Attempts {
            var count = 0
            func next() -> Int {
                count += 1
                return count
            }
        }
        let attempts = Attempts()
        struct FlakyFailure: Error {}

        let result = await store.scheduleTaskAndWait(task) { () async throws -> String in
            let n = await attempts.next()
            if n <= 2 { throw FlakyFailure() }
            return "recovered"
        }

        #expect(result == "recovered")
        #expect(await attempts.count == 3)
    }

    @Test func twoMissingCapabilitiesShareOneDeadline() async {
        let store = DynamicStore()
        let scheduler = TaskScheduler(store: store)

        let task = TaskDescriptor(
            requiredCapabilities: [
                .custom("NoCapA_\(UUID().uuidString)"),
                .custom("NoCapB_\(UUID().uuidString)")
            ],
            timeout: 1.0
        )
        let start = Date()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            scheduler.schedule(task, taskExecution: {}, completion: { _ in done.resume() })
        }
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 2.0)
        #expect(elapsed > 0.5)
    }
}
