import Testing
import Foundation
@testable import TPCapabilityKit
@testable import TPCapabilityKitBridge

struct ObjcTaskDescriptorTests {
    @Test func initWithDefaults() {
        let descriptor = ObjcTaskDescriptor(capabilities: ["heavyTask"])
        
        #expect(descriptor.capabilities == ["heavyTask"])
        #expect(descriptor.priority == 2)
        #expect(descriptor.timeout == 30.0)
        #expect(descriptor.maxRetries == 0)
        #expect(descriptor.metadata.isEmpty)
        #expect(!descriptor.id.isEmpty)
    }

    @Test func initWithCustomValues() {
        let descriptor = ObjcTaskDescriptor(
            capabilities: ["networkAccess", "backgroundExecution"],
            priority: 4,
            timeout: 60.0,
            maxRetries: 3,
            metadata: ["source": "test"]
        )

        #expect(Set(descriptor.capabilities) == Set(["networkAccess", "backgroundExecution"]))
        #expect(descriptor.priority == 4)
        #expect(descriptor.timeout == 60.0)
        #expect(descriptor.maxRetries == 3)
        #expect(descriptor.metadata["source"] == "test")
    }

    @Test func underlyingProperty() {
        let descriptor = ObjcTaskDescriptor(capabilities: ["heavyTask"])
        let underlying = descriptor.underlying

        #expect(underlying.id == descriptor.id)
        #expect(underlying.requiredCapabilities == [.heavyTask])
    }

    @Test func outOfRangePriorityCoercesToNormal() {
        let tooHigh = ObjcTaskDescriptor(capabilities: ["heavyTask"], priority: 99)
        #expect(tooHigh.underlying.priority == .normal)

        let negative = ObjcTaskDescriptor(capabilities: ["heavyTask"], priority: -1)
        #expect(negative.underlying.priority == .normal)
    }

    @Test func outOfRangePriorityReadBackIsCoerced() {
        let tooHigh = ObjcTaskDescriptor(capabilities: ["heavyTask"], priority: 99)
        #expect(tooHigh.priority == TaskPriority.normal.rawValue)
        #expect(tooHigh.priority == tooHigh.underlying.priority.rawValue)

        let negative = ObjcTaskDescriptor(capabilities: ["heavyTask"], priority: -1)
        #expect(negative.priority == TaskPriority.normal.rawValue)
        #expect(negative.priority == negative.underlying.priority.rawValue)
    }

    @Test func defaultTimeoutTracksConfiguration() {
        let descriptor = ObjcTaskDescriptor(capabilities: ["heavyTask"])
        #expect(descriptor.timeout == TaskScheduler.Configuration.default.defaultTimeout)
        #expect(descriptor.timeout == (descriptor.underlying.timeout ?? TaskScheduler.Configuration.default.defaultTimeout))

        let nilTimeout = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: nil)
        let wrapped = ObjcTaskDescriptor(underlying: nilTimeout)
        #expect(wrapped.timeout == TaskScheduler.Configuration.default.defaultTimeout)
    }

    @Test func explicitValuesRoundTrip() {
        let descriptor = ObjcTaskDescriptor(
            capabilities: ["networkAccess", "backgroundExecution"],
            priority: 4,
            timeout: 60.0,
            maxRetries: 3,
            metadata: ["source": "test"]
        )

        #expect(Set(descriptor.capabilities) == Set(["networkAccess", "backgroundExecution"]))
        #expect(descriptor.priority == TaskPriority.critical.rawValue)
        #expect(descriptor.timeout == 60.0)
        #expect(descriptor.maxRetries == 3)
        #expect(descriptor.metadata == ["source": "test"])
        #expect(descriptor.id == descriptor.underlying.id)
        #expect(descriptor.priority == descriptor.underlying.priority.rawValue)
    }
}

struct ObjcLeaseTests {
    @Test func stateTransitions() {
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask])
        let lease = Lease(task: task)
        let objcLease = ObjcLease(underlying: lease)
        
        // Initial state
        #expect(objcLease.state == .pending)
        #expect(objcLease.underlying.state == .pending)
        
        // Activate
        lease.activate()
        #expect(lease.state == .active)
        #expect(objcLease.underlying.activatedAt != nil)
        
        // Complete
        lease.complete(with: "result")
        #expect(lease.state == .completed)
        #expect(objcLease.underlying.completedAt != nil)
        #expect(objcLease.underlying.result as? String == "result")
    }

    @Test func failureState() {
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask])
        let lease = Lease(task: task)
        let objcLease = ObjcLease(underlying: lease)
        
        lease.activate()
        struct TestError: Error {}
        lease.fail(with: TestError())
        
        if case .failed = lease.state {
            // Expected
        } else {
            Issue.record("Expected failed state")
        }
        #expect(objcLease.underlying.isTerminal)
    }

    @Test func underlyingProperty() {
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask])
        let lease = Lease(task: task)
        let objcLease = ObjcLease(underlying: lease)
        
        #expect(objcLease.underlying === lease)
    }

    @Test func liveViewReadsStateWithoutSync() {
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask])
        let lease = Lease(task: task)
        let objcLease = ObjcLease(underlying: lease)

        #expect(objcLease.state == .pending)

        lease.activate()

        #expect(objcLease.state == .active)

        lease.complete(with: "result")

        #expect(objcLease.state == .completed)
        #expect(objcLease.result as? String == "result")
    }
}

struct ObjcStoreBridgeSchedulingTests {
    @Test func objcScheduleAndComplete() async {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let pluginId = "ObjcSchedCap_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        
        let descriptor = ObjcTaskDescriptor(capabilities: ["heavyTask"])
        
        await withCheckedContinuation { continuation in
            bridge.taskScheduler.scheduleAndWait(descriptor, task: {
                NSString(string: "Result")
            }, completion: { result in
                #expect((result as? String) == "Result")
                continuation.resume()
            })
        }
    }

    @Test func objcScheduleWithoutCapability() async {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let uniqueCap = "missingCap_\(UUID().uuidString)"

        let descriptor = ObjcTaskDescriptor(capabilities: [uniqueCap], timeout: 0.1)

        await withCheckedContinuation { continuation in
            bridge.taskScheduler.scheduleAndWait(descriptor, task: {
                NSString(string: "ShouldNotRun")
            }, completion: { result in
                #expect(result == nil)
                continuation.resume()
            })
        }
    }

    @Test func objcCancelTask() async {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let uniqueCap = "cancelCap_\(UUID().uuidString)"

        let descriptor = ObjcTaskDescriptor(capabilities: [uniqueCap], timeout: 5.0)
        let done = AsyncStream<Void>.makeStream()
        let lease = bridge.taskScheduler.schedule(descriptor, task: {
            // Should not execute
        }, completion: { _ in
            done.continuation.yield()
        })

        bridge.taskScheduler.cancel(taskId: descriptor.id)

        for await _ in done.stream { break }
        #expect(lease.underlying.isTerminal)
    }

    @Test func objcPendingAndActiveCounts() {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)

        #expect(bridge.taskScheduler.pendingCount == 0)
        #expect(bridge.taskScheduler.activeCount == 0)
    }

    @Test func taskSchedulerIsLiveView() {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)

        let scheduler1 = bridge.taskScheduler
        let scheduler2 = bridge.taskScheduler

        #expect(scheduler1.pendingCount == store.pendingTaskCount)
        #expect(scheduler2.pendingCount == store.pendingTaskCount)
        #expect(scheduler1.activeCount == store.activeTaskCount)
        #expect(scheduler2.activeCount == store.activeTaskCount)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test func bridgeSchedulingDelegatesToSinglePath() async {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let uniqueCap = "singlePathCap_\(UUID().uuidString)"

        let descriptor = ObjcTaskDescriptor(capabilities: [uniqueCap], timeout: 5.0)
        let done = AsyncStream<Void>.makeStream()
        let lease = bridge.taskScheduler.schedule(descriptor, task: {
            // Should not execute
        }, completion: { _ in
            done.continuation.yield()
        })

        bridge.taskScheduler.cancel(taskId: descriptor.id)

        for await _ in done.stream { break }
        #expect(lease.underlying.isTerminal)
        #expect(bridge.taskScheduler.pendingCount == store.pendingTaskCount)
        #expect(bridge.taskScheduler.activeCount == store.activeTaskCount)
    }
}
