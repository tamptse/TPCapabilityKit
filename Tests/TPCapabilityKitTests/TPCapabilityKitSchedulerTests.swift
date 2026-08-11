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
        let controller = ConcurrencyController(configuration: .init(maxPerCapability: 2, maxGlobal: 5))
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask])

        await controller.acquire(for: task)
        let stats = await controller.stats()
        #expect(stats.globalActive == 1)

        await controller.release(for: task)
        let statsAfter = await controller.stats()
        #expect(statsAfter.globalActive == 0)
    }

    @Test func respectsGlobalLimit() async {
        let controller = ConcurrencyController(configuration: .init(maxGlobal: 2))

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
        let controller = ConcurrencyController(configuration: .init(maxPerCapability: 1))

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
