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
        
        #expect(descriptor.capabilities == ["networkAccess", "backgroundExecution"])
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
            bridge.scheduleTaskAndWait(descriptor, task: {
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
            bridge.scheduleTaskAndWait(descriptor, task: {
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
        let lease = bridge.scheduleTask(descriptor) {
            // Should not execute
        }
        
        bridge.cancelTask(taskId: descriptor.id)
        
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(lease.underlying.isTerminal)
    }

    @Test func objcPendingAndActiveCounts() {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        
        #expect(bridge.pendingTaskCount == 0)
        #expect(bridge.activeTaskCount == 0)
    }
}
