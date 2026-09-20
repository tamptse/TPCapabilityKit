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
        #expect(task.timeout == 30.0)
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

        lease.activate()
        #expect(lease.retry() == true)
        #expect(lease.retryCount == 1)
        #expect(lease.state == .pending)

        lease.activate()
        #expect(lease.retry() == true)
        #expect(lease.retryCount == 2)

        lease.activate()
        #expect(lease.retry() == false)
    }

    @Test func leaseExpiration() {
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 0.01)
        let lease = Lease(task: task)
        lease.activate()

        // Wait for timeout
        Thread.sleep(forTimeInterval: 0.02)
        #expect(lease.hasExpired == true)
    }
}

struct ConcurrencyControllerTests {
    @Test func acquireAndRelease() async {
        let controller = ConcurrencyController(maxPerCapability: 2, maxGlobal: 5)
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask])

        await controller.acquire(for: task)
        let stats = await controller.stats()
        #expect(stats.globalActive == 1)

        await controller.release(for: task)
        let statsAfter = await controller.stats()
        #expect(statsAfter.globalActive == 0)
    }

    @Test func respectsGlobalLimit() async {
        let controller = ConcurrencyController(maxGlobal: 2)

        let task1 = TaskDescriptor(requiredCapabilities: [.heavyTask])
        let task2 = TaskDescriptor(requiredCapabilities: [.lightTask])
        let task3 = TaskDescriptor(requiredCapabilities: [.networkAccess])

        await controller.acquire(for: task1)
        await controller.acquire(for: task2)

        // Third acquire should suspend
        let task3Task = Task {
            await controller.acquire(for: task3)
            let stats = await controller.stats()
            return stats.globalActive
        }

        // Give task3 a moment to suspend
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Release one slot
        await controller.release(for: task1)

        let result = await task3Task.value
        #expect(result == 2)
    }

    @Test func respectsPerCapabilityLimit() async {
        let controller = ConcurrencyController(maxPerCapability: 1)

        let task1 = TaskDescriptor(requiredCapabilities: [.heavyTask])
        let task2 = TaskDescriptor(requiredCapabilities: [.heavyTask])

        await controller.acquire(for: task1)

        let task2Task = Task {
            await controller.acquire(for: task2)
            return true
        }

        try? await Task.sleep(nanoseconds: 100_000_000)

        await controller.release(for: task1)
        let result = await task2Task.value
        #expect(result == true)
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
            func count() -> Int { order.count }
        }
        let tracker = ExecutionTracker()

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

        // Schedule high first, then low - to test that high is processed first
        // even though low was scheduled after
        scheduler.schedule(task2) {
            await tracker.append("high")
        }
        scheduler.schedule(task1) {
            await tracker.append("low")
        }

        // Wait for both to complete
        try? await Task.sleep(nanoseconds: 500_000_000)

        // High should execute first because it has higher priority
        let order = await tracker.order
        #expect(order.first == "high")
    }

    @Test func cancelTask() async {
        let store = DynamicStore()
        let scheduler = TaskScheduler(store: store)

        let task = TaskDescriptor(
            id: "cancelable",
            requiredCapabilities: [.custom("NeverAvailable_\(UUID().uuidString)")],
            timeout: 5.0
        )

        let lease = scheduler.schedule(task) {
            // This should never execute
        }
        scheduler.cancel(taskId: task.id)

        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(lease.isTerminal)
    }

    @Test func capabilityRevocationDuringExecution() async {
        let store = DynamicStore()
        let pluginId = "TOCTOU_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])

        let scheduler = TaskScheduler(store: store)

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 5.0)

        actor ExecutionTracker {
            var started = false
            func markStarted() { started = true }
        }
        let tracker = ExecutionTracker()

        let lease = scheduler.schedule(task) {
            await tracker.markStarted()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // Wait for task to start
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await tracker.started)

        // Revoke capability while task is running
        store.unregisterCapability(for: pluginId)

        // Wait for task to complete
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Task should still complete (revocation doesn't kill running tasks)
        #expect(lease.isTerminal)
    }

    @Test func retryOnFailure() async {
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

        let lease = scheduler.schedule(task) {
            // This will fail on first attempt
        }

        // Wait for retries to complete
        try? await Task.sleep(nanoseconds: 500_000_000)

        #expect(lease.retryCount == 1)
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
