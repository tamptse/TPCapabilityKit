import Foundation
@testable import TPCapabilityKit

extension TaskScheduler {
    var queuedCount: Int {
        lock.withLock { lifecycleStore.counts.queued }
    }

    var parkedCount: Int {
        lock.withLock { lifecycleStore.counts.parked }
    }

    func waitForCounts(parked: Int? = nil, pending: Int? = nil, timeout: TimeInterval = 2.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let satisfied = lock.withLock {
                (parked == nil || lifecycleStore.counts.parked == parked)
                    && (pending == nil || lifecycleStore.counts.pending == pending)
            }
            if satisfied { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
