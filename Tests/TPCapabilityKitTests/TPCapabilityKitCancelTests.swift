import Testing
import Combine
import Foundation
@testable import TPCapabilityKit

@Suite("Cancel Task Tests")
struct CancelTests {
    @Test("cancel sends only one expired event")
    func cancelSendsOneEvent() async {
        let store = DynamicStore()
        let scheduler = TaskScheduler(store: store)
        var eventCount = 0
        
        let cancellable = scheduler.events.sink { event in
            if case .taskExpired = event {
                eventCount += 1
            }
        }
        
        let descriptor = TaskDescriptor(requiredCapabilities: [])
        let lease = scheduler.schedule(descriptor, taskExecution: {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        })
        
        // Wait for task to potentially start
        try? await Task.sleep(nanoseconds: 10_000_000)
        
        scheduler.cancel(taskId: lease.task.id)
        
        // Wait for any async processing
        try? await Task.sleep(nanoseconds: 50_000_000)
        
        #expect(eventCount == 1)
        cancellable.cancel()
    }
    
    @Test("cancel active task expires lease and calls completion")
    func cancelActiveTask() async {
        let store = DynamicStore()
        let scheduler = TaskScheduler(store: store)
        let pluginId = "CancelActive_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        
        var completionCalled = false
        var completedLease: Lease?
        
        let descriptor = TaskDescriptor(
            requiredCapabilities: [.heavyTask],
            timeout: 10.0
        )
        
        let lease = scheduler.schedule(descriptor, taskExecution: {
            // Simulate long-running task
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }, completion: { lease in
            completionCalled = true
            completedLease = lease
        })
        
        // Wait for task to start executing
        try? await Task.sleep(nanoseconds: 50_000_000)
        
        // Cancel the active task
        scheduler.cancel(taskId: lease.task.id)
        
        // Wait for cancellation to propagate
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        #expect(lease.state == .expired)
        #expect(lease.isTerminal)
        #expect(completionCalled)
        #expect(completedLease?.state == .expired)
    }
}
