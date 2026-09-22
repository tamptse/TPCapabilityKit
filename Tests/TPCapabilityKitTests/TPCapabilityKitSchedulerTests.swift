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
    @Test func leaseLifecycle() {
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 1.0)
        let lease = Lease(task: task)

        #expect(lease.state == .pending)
        #expect(lease.isTerminal == false)

        lease.activate()
        #expect(lease.state == .active)
        #expect(lease.activatedAt != nil)

        lease.complete(with: "result")
        #expect(lease.state == .completed)
        #expect(lease.isTerminal == true)
        #expect(lease.completedAt != nil)
    }

    @Test func leaseFailure() {
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask])
        let lease = Lease(task: task)
        lease.activate()

        struct TestError: Error {}
        lease.fail(with: TestError())

        if case .failed(let error) = lease.state {
            #expect(error is TestError)
        } else {
            Issue.record("Expected failed state")
        }
    }

    @Test func leaseRetry() {
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], maxRetries: 2)
        let lease = Lease(task: task)

        #expect(lease.canRetry)
        lease.activate()
        #expect(lease.activatedAt != nil)
        lease.beginRetry()
        #expect(lease.retryCount == 1)
        #expect(lease.state == .pending)
        #expect(lease.activatedAt == nil)
        #expect(lease.completedAt == nil)
        #expect(lease.result == nil)
        #expect(lease.canRetry)

        lease.activate()
        lease.beginRetry()
        #expect(lease.retryCount == 2)
        #expect(lease.state == .pending)
        #expect(!lease.canRetry)
    }

    @Test func leaseExpiration() {
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 0.01)
        let lease = Lease(task: task)
        lease.activate()
        lease.expire()

        #expect(lease.state == .expired)
        #expect(lease.isTerminal == true)
    }
}

struct ConcurrencyControllerTests {
    @Test func acquireAndRelease() async {
        let controller = ConcurrencyController(maxPerCapability: 2, maxGlobal: 5)

        await controller.acquire(keys: [.heavyTask], taskId: "t1")
        let stats = controller.stats()
        #expect(stats.globalActive == 1)

        controller.release(taskId: "t1")
        let statsAfter = controller.stats()
        #expect(statsAfter.globalActive == 0)
    }

    @Test func doubleReleaseIsSafe() async {
        let controller = ConcurrencyController(maxPerCapability: 2, maxGlobal: 5)

        await controller.acquire(keys: [.heavyTask], taskId: "t1")
        controller.release(taskId: "t1")
        controller.release(taskId: "t1")
        controller.release(taskId: "unknown")

        let stats = controller.stats()
        #expect(stats.globalActive == 0)
        #expect(stats.waitingCount == 0)
    }

    @Test func respectsGlobalLimit() async {
        let controller = ConcurrencyController(maxGlobal: 2)

        await controller.acquire(keys: [.heavyTask], taskId: "t1")
        await controller.acquire(keys: [.lightTask], taskId: "t2")

        // Third acquire should suspend
        let task3Task = Task {
            await controller.acquire(keys: [.networkAccess], taskId: "t3")
            let stats = controller.stats()
            controller.release(taskId: "t3")
            return stats.globalActive
        }

        let parked = await pollUntil(timeout: 5.0) {
            controller.stats().waitingCount == 1
        }
        #expect(parked)

        // Release one slot
        controller.release(taskId: "t1")

        let result = await task3Task.value
        #expect(result == 2)
        controller.release(taskId: "t2")
    }

    @Test func respectsPerCapabilityLimit() async {
        let controller = ConcurrencyController(maxPerCapability: 1)

        await controller.acquire(keys: [.heavyTask], taskId: "t1")

        let task2Task = Task {
            await controller.acquire(keys: [.heavyTask], taskId: "t2")
            controller.release(taskId: "t2")
            return true
        }

        let parked = await pollUntil(timeout: 5.0) {
            controller.stats().waitingCount == 1
        }
        #expect(parked)

        controller.release(taskId: "t1")
        let result = await task2Task.value
        #expect(result == true)
    }

    private func pollUntil(timeout: TimeInterval, condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
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
