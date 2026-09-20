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

    @Test("cancel parked-at-active task delivers exactly one terminal event")
    func cancelParkedActiveDeliversOnce() async {
        let store = DynamicStore()
        let pluginId = "ParkActive_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(store: store)

        let activatedBox = SendableBox<CheckedContinuation<Void, Never>?>(nil)
        let startedBox = SendableBox<CheckedContinuation<Void, Never>?>(nil)
        let releaseBox = SendableBox<CheckedContinuation<Void, Never>?>(nil)
        let doneBox = SendableBox<CheckedContinuation<Void, Never>?>(nil)
        var expiredCount = 0
        var completionCount = 0
        let eventsCancellable = scheduler.events.sink { event in
            if case .taskExpired = event { expiredCount += 1 }
        }
        defer { eventsCancellable.cancel() }

        scheduler.onActivate = { _ in activatedBox.value?.resume() }
        let descriptor = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 10.0)

        await withCheckedContinuation { (activated: CheckedContinuation<Void, Never>) in
            activatedBox.setValue(activated)
            scheduler.schedule(descriptor, taskExecution: {
                startedBox.value?.resume()
                await withCheckedContinuation { (release: CheckedContinuation<Void, Never>) in
                    releaseBox.setValue(release)
                }
            }, completion: { _ in
                completionCount += 1
                doneBox.value?.resume()
            })
        }

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            doneBox.setValue(done)
            scheduler.cancel(taskId: descriptor.id)
        }

        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            if releaseBox.value != nil {
                started.resume()
            } else {
                startedBox.setValue(started)
            }
        }
        releaseBox.value?.resume()

        #expect(expiredCount == 1)
        #expect(completionCount == 1)
    }

    @Test("storm acquire and cancel drains slots to zero")
    func stormAcquireCancelDrainsSlots() async {
        let store = DynamicStore()
        let pluginId = "Storm_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        let scheduler = TaskScheduler(store: store)

        var leases: [Lease] = []
        for _ in 0..<20 {
            let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 10.0)
            leases.append(scheduler.schedule(task, taskExecution: {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }))
        }

        let warmedUp = await pollUntil(timeout: 3.0) {
            await scheduler.concurrencyStats().globalActive > 0
        }
        #expect(warmedUp)

        for lease in leases {
            scheduler.cancel(taskId: lease.task.id)
        }

        let drained = await pollUntil(timeout: 5.0) {
            let stats = await scheduler.concurrencyStats()
            return stats.globalActive == 0
                && stats.waitingCount == 0
                && scheduler.activeCount == 0
                && scheduler.pendingCount == 0
                && leases.allSatisfy(\.isTerminal)
        }
        #expect(drained)
        let stats = await scheduler.concurrencyStats()
        #expect(stats.globalActive == 0)
        #expect(stats.waitingCount == 0)
        #expect(scheduler.activeCount == 0)
        #expect(scheduler.pendingCount == 0)
        #expect(leases.allSatisfy { $0.isTerminal })
    }

    private func pollUntil(timeout: TimeInterval, condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }
}
