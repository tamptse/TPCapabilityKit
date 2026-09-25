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
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "LeaseSeamComplete")
        defer { store.unregisterCapability(for: pluginId) }

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0)
        let lease = await withCheckedContinuation { (done: CheckedContinuation<Lease, Never>) in
            store.scheduleTask(task, task: {}, completion: { finished in
                done.resume(returning: finished)
            })
        }

        #expect(lease.state == .completed)
        #expect(lease.isTerminal)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test func throwingExecutionFailsThroughSeam() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "LeaseSeamFail")
        defer { store.unregisterCapability(for: pluginId) }

        let attempts = Probe()
        struct Boom: Error {}
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 0)
        let result: String? = await store.scheduleTaskAndWait(task) { () async throws -> String in
            await attempts.next()
            throw Boom()
        }

        #expect(result == nil)
        #expect(await attempts.count == 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test func retryBudgetExhaustsThroughSeam() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "LeaseSeamBudget")
        defer { store.unregisterCapability(for: pluginId) }

        let attempts = Probe()
        struct AlwaysFails: Error {}
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 2)
        let result: String? = await store.scheduleTaskAndWait(task) { () async throws -> String in
            await attempts.next()
            throw AlwaysFails()
        }

        #expect(result == nil)
        #expect(await attempts.count == 3)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test func cancelPendingSettlesExpiredThroughSeam() async {
        let (store, _) = makeStoreWithCap([], prefix: "LeaseSeamCancel")

        let counter = Probe()
        let task = TaskDescriptor(
            requiredCapabilities: [.custom("LeaseSeamCancel_\(UUID().uuidString)")],
            timeout: 5.0
        )
        let lease = await withCheckedContinuation { (done: CheckedContinuation<Lease, Never>) in
            store.scheduleTask(task, task: {}, completion: { finished in
                Task {
                    await counter.inc()
                    done.resume(returning: finished)
                }
            })
            store.cancelTask(taskId: task.id)
        }

        #expect(await counter.count == 1)
        #expect(lease.state == .expired)
        #expect(lease.isTerminal)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test func flakyExecutionRecoversThroughSeam() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "LeaseSeamRetry")
        defer { store.unregisterCapability(for: pluginId) }

        let attempts = Probe()
        struct FirstFails: Error {}
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0, maxRetries: 1)
        let result = await store.scheduleTaskAndWait(task) { () async throws -> String in
            let n = await attempts.next()
            if n == 1 { throw FirstFails() }
            return "recovered"
        }

        #expect(result == "recovered")
        #expect(await attempts.count == 2)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}

struct ConcurrencyControllerTests {
    @Test func acquireAndRelease() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "ControllerAcquire")
        defer { store.unregisterCapability(for: pluginId) }

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0)
        let lease = await withCheckedContinuation { (done: CheckedContinuation<Lease, Never>) in
            store.scheduleTask(task, task: {}, completion: { finished in
                done.resume(returning: finished)
            })
        }

        #expect(lease.state == .completed)
        #expect(lease.isTerminal)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test func doubleReleaseIsSafe() async {
        let (store, pluginId) = makeStoreWithCap(
            [.heavyTask],
            configuration: TaskScheduler.Configuration(maxPerCapability: 2, maxGlobal: 1),
            prefix: "ControllerIdempotent"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let id = "idempotent_\(UUID().uuidString)"
        let first = TaskDescriptor(id: id, requiredCapabilities: [.heavyTask], timeout: 5.0)
        let firstResult = await store.scheduleTaskAndWait(first) { "first" }
        #expect(firstResult == "first")
        store.cancelTask(taskId: id)
        store.cancelTask(taskId: id)
        store.cancelTask(taskId: "unknown")

        let secondResult: String? = await store.scheduleTaskAndWait(first) { "second" }
        #expect(secondResult == "second")
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test func respectsGlobalLimit() async {
        let (store, pluginId) = makeStoreWithCap(
            [.heavyTask],
            configuration: TaskScheduler.Configuration(maxPerCapability: 10, maxGlobal: 2),
            prefix: "ControllerGlobal"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let probe = Probe()
        let started = AsyncGate()
        let release = AsyncGate()
        let parkedDone = AsyncGate()
        let completions = Probe()

        let holdA = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 10.0)
        let holdB = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 10.0)
        for hold in [holdA, holdB] {
            store.scheduleTask(hold, task: {
                await probe.enter()
                started.signal()
                await release.wait()
                await probe.exit()
            }, completion: { lease in
                Task {
                    await completions.record(lease)
                    parkedDone.signal()
                }
            })
        }
        await started.wait()
        await started.wait()
        #expect(store.activeTaskCount == 2)

        let parkedId = "parked_\(UUID().uuidString)"
        let parked = TaskDescriptor(id: parkedId, requiredCapabilities: [.heavyTask], timeout: 10.0)
        store.scheduleTask(parked, task: {
            await probe.enter()
            await probe.exit()
        }, completion: { lease in
            Task {
                await completions.record(lease)
                parkedDone.signal()
            }
        })

        let cancelledId = "cancelled_\(UUID().uuidString)"
        let cancelled = TaskDescriptor(id: cancelledId, requiredCapabilities: [.heavyTask], timeout: 10.0)
        let cancelledLease = store.scheduleTask(cancelled, task: {}, completion: { lease in
            Task {
                await completions.record(lease)
                parkedDone.signal()
            }
        })
        store.cancelTask(taskId: cancelledId)
        await parkedDone.wait()
        #expect(cancelledLease.state == .expired)
        #expect(cancelledLease.isTerminal)

        release.finish()
        for await _ in parkedDone.stream {
            if await completions.count == 4 { break }
        }

        #expect(await completions.count == 4)
        #expect(await completions.expiredId == cancelledId)
        #expect(await probe.maxSeen <= 2)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test func respectsPerCapabilityLimit() async {
        // Argument: holder-started gate + synchronous enqueue of 3 contenders with
        // no suspension points before release prove contention existed under a held
        // per-cap slot; entry-solitude (each contender sees activeCount==1 at entry)
        // + probe maxSeen<=1 + full drain prove serialization. In-body yields are
        // workload-wideners, not gates: they widen the overlap window so a broken
        // controller admitting 2 concurrently would surface as entry-activeCount>1
        // or maxSeen>1 (same falsifiability standard as the approved global test's
        // maxSeen bound). No pre-release assertion reads store queue counts:
        // schedule() spawns an unstructured Task that dequeues pending->parked
        // concurrently, so pendingCount here is timing-dependent (observed 0-1 in
        // solo runs); the deterministic pre-release proof is local lease count.
        let (store, pluginId) = makeStoreWithCap(
            [.heavyTask],
            configuration: TaskScheduler.Configuration(maxPerCapability: 1, maxGlobal: 10),
            prefix: "ControllerPerCap"
        )
        defer { store.unregisterCapability(for: pluginId) }

        let probe = Probe()
        let entries = Probe()
        let entryActiveCounts = Probe()
        let completions = Probe()

        let started = AsyncGate()
        let release = AsyncGate()
        let drained = AsyncGate()

        let holder = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 10.0)
        store.scheduleTask(holder, task: {
            await probe.enter()
            started.signal()
            await release.wait()
            await probe.exit()
        }, completion: { _ in
            Task {
                await completions.inc()
                drained.signal()
            }
        })
        await started.wait()
        #expect(store.activeTaskCount == 1)

        let totalContenders = 3
        var contenderLeases: [Lease] = []
        for _ in 0..<totalContenders {
            let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 10.0)
            let lease = store.scheduleTask(task, task: {
                let seen = store.activeTaskCount
                await entryActiveCounts.append(seen)
                await probe.enter()
                await Task.yield()
                await Task.yield()
                await Task.yield()
                await entries.inc()
                await probe.exit()
            }, completion: { _ in
                Task {
                    await completions.inc()
                    drained.signal()
                }
            })
            contenderLeases.append(lease)
        }
        #expect(contenderLeases.count == totalContenders)

        release.finish()
        for await _ in drained.stream {
            if await completions.count == totalContenders + 1 { break }
        }

        #expect(await entries.count == totalContenders)
        #expect(await entryActiveCounts.intValues.count == totalContenders)
        #expect(await entryActiveCounts.intValues.allSatisfy { $0 == 1 })
        #expect(await probe.maxSeen <= 1)
        #expect(await completions.count == totalContenders + 1)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}

struct TaskSchedulerTests {
    @Test func scheduleAndComplete() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "SchedulerPlugin")
        defer { store.unregisterCapability(for: pluginId) }

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask])
        let result = await store.scheduleTaskAndWait(task) {
            return "ScheduledResult"
        }

        #expect(result == "ScheduledResult")
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test func cancelTask() async {
        let (store, _) = makeStoreWithCap([], prefix: "SchedulerCancel")

        let task = TaskDescriptor(
            id: "cancelable",
            requiredCapabilities: [.custom("NeverAvailable_\(UUID().uuidString)")],
            timeout: 5.0
        )

        let done = AsyncGate()
        let lease = store.scheduleTask(task, task: {
        }, completion: { _ in done.signal() })
        store.cancelTask(taskId: task.id)

        await done.wait()
        #expect(lease.isTerminal)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test func capabilityRevocationDuringExecution() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "TOCTOU")

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0)

        let started = AsyncGate()
        let release = AsyncGate()
        let done = AsyncGate()
        let lease = store.scheduleTask(task, task: {
            started.signal()
            await release.wait()
        }, completion: { _ in done.signal() })

        await started.wait()

        store.unregisterCapability(for: pluginId)
        release.finish()

        await done.wait()

        #expect(lease.isTerminal)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test func voidTaskCompletesWithoutRetry() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "RetryPlugin")
        defer { store.unregisterCapability(for: pluginId) }

        let task = TaskDescriptor(
            requiredCapabilities: [.heavyTask],
            timeout: 5.0,
            maxRetries: 1
        )

        let done = AsyncGate()
        let lease = store.scheduleTask(task, task: {
        }, completion: { _ in done.signal() })

        await done.wait()

        #expect(lease.retryCount == 0)
        #expect(lease.state == .completed)
        #expect(lease.isTerminal)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test func retryPreservesWaiterThroughStoreFacade() async {
        let (store, pluginId) = makeStoreWithCap([.heavyTask], prefix: "FacadeRetry")
        defer { store.unregisterCapability(for: pluginId) }

        let task = TaskDescriptor(
            requiredCapabilities: [.heavyTask],
            timeout: 5.0,
            maxRetries: 2
        )

        let attempts = Probe()
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
        store.schedulingGenerations.enableDeterministicTime(owner: store)

        let task = TaskDescriptor(
            requiredCapabilities: [
                .custom("NoCapA_\(UUID().uuidString)"),
                .custom("NoCapB_\(UUID().uuidString)")
            ],
            timeout: 1.0
        )
        let done = AsyncGate()
        let completions = Probe()
        let lease = store.scheduleTask(task, task: {}, completion: { _ in
            Task {
                await completions.inc()
                done.signal()
            }
        })
        await store.schedulingGenerations.advanceTime(by: 1.0)
        await done.wait()

        #expect(await completions.count == 1)
        #expect(lease.state == .expired)
        #expect(lease.isTerminal)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }
}
