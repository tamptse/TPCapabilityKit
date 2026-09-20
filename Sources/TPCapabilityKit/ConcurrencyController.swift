import Foundation

/// Actor-based concurrency limiter that controls how many tasks can execute
/// concurrently per capability and globally.
///
/// Inspired by Meta's AsyncLimiter and Swift's AsyncSemaphore.
/// Uses structured concurrency for safe slot management.
actor ConcurrencyController {
    private let maxPerCapability: Int?
    private let maxGlobal: Int?
    private var capabilitySlots: [Capability: Int] = [:]
    private var globalSlots: Int = 0
    private var waitingContinuations: [CheckedContinuation<Void, Never>] = []

    /// Creates a new ConcurrencyController.
    init(maxPerCapability: Int? = 5, maxGlobal: Int? = 20) {
        self.maxPerCapability = maxPerCapability
        self.maxGlobal = maxGlobal
    }

    /// Acquires a slot for the given task. Suspends if no slots available.
    /// - Parameter task: The task descriptor to acquire a slot for.
    func acquire(for task: TaskDescriptor) async {
        // Check if we can acquire immediately
        if canAcquire(for: task) {
            incrementSlots(for: task)
            return
        }

        // Wait for a slot to become available
        await withCheckedContinuation { continuation in
            waitingContinuations.append(continuation)
        }

        // After suspension, acquire the slot
        incrementSlots(for: task)
    }

    /// Releases the slot for the given task.
    /// - Parameter task: The task descriptor to release the slot for.
    func release(for task: TaskDescriptor) {
        decrementSlots(for: task)

        // Wake up only one waiting continuation (FIFO order)
        // since releasing one slot can only satisfy one waiter
        if !waitingContinuations.isEmpty {
            let continuation = waitingContinuations.removeFirst()
            continuation.resume()
        }
    }

    /// Returns current utilization stats.
    func stats() -> Stats {
        Stats(
            globalActive: globalSlots,
            globalMax: maxGlobal,
            perCapability: capabilitySlots
        )
    }

    // MARK: - Private Helpers

    private func canAcquire(for task: TaskDescriptor) -> Bool {
        // Check global limit
        if let maxGlobal = maxGlobal {
            guard globalSlots < maxGlobal else { return false }
        }

        // Check per-capability limits
        if let maxPerCap = maxPerCapability {
            for cap in task.requiredCapabilities {
                guard (capabilitySlots[cap] ?? 0) < maxPerCap else { return false }
            }
        }

        return true
    }

    private func incrementSlots(for task: TaskDescriptor) {
        globalSlots += 1
        for cap in task.requiredCapabilities {
            capabilitySlots[cap, default: 0] += 1
        }
    }

    private func decrementSlots(for task: TaskDescriptor) {
        globalSlots = max(0, globalSlots - 1)
        for cap in task.requiredCapabilities {
            capabilitySlots[cap] = max(0, (capabilitySlots[cap] ?? 1) - 1)
        }
    }

    /// Statistics about current concurrency utilization.
    struct Stats: Sendable {
        let globalActive: Int
        let globalMax: Int?
        let perCapability: [Capability: Int]
    }
}
