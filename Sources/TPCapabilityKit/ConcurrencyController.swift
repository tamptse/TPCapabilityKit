import Foundation

/// Actor-based concurrency limiter that controls how many tasks can execute
/// concurrently per capability and globally.
///
/// Inspired by Meta's AsyncLimiter and Swift's AsyncSemaphore.
/// Uses structured concurrency for safe slot management.
public actor ConcurrencyController {
    /// Configuration for concurrency limits.
    public struct Configuration: Sendable {
        /// Maximum concurrent tasks per capability. Nil means no per-capability limit.
        public let maxPerCapability: Int?

        /// Maximum concurrent tasks globally. Nil means no global limit.
        public let maxGlobal: Int?

        public init(maxPerCapability: Int? = nil, maxGlobal: Int? = nil) {
            self.maxPerCapability = maxPerCapability
            self.maxGlobal = maxGlobal
        }

        /// Default configuration: 5 per capability, 20 global.
        public static let `default` = Configuration(maxPerCapability: 5, maxGlobal: 20)
    }

    private let configuration: Configuration
    private var capabilitySlots: [Capability: Int] = [:]
    private var globalSlots: Int = 0
    private var waitingContinuations: [CheckedContinuation<Void, Never>] = []

    /// Creates a new ConcurrencyController.
    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// Acquires a slot for the given task. Suspends if no slots available.
    /// - Parameter task: The task descriptor to acquire a slot for.
    public func acquire(for task: TaskDescriptor) async {
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
    public func release(for task: TaskDescriptor) {
        decrementSlots(for: task)

        // Wake up waiting continuations
        let toResume = waitingContinuations
        waitingContinuations = []

        for continuation in toResume {
            continuation.resume()
        }
    }

    /// Returns current utilization stats.
    public func stats() -> Stats {
        Stats(
            globalActive: globalSlots,
            globalMax: configuration.maxGlobal,
            perCapability: capabilitySlots
        )
    }

    // MARK: - Private Helpers

    private func canAcquire(for task: TaskDescriptor) -> Bool {
        // Check global limit
        if let maxGlobal = configuration.maxGlobal {
            guard globalSlots < maxGlobal else { return false }
        }

        // Check per-capability limits
        if let maxPerCap = configuration.maxPerCapability {
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
    public struct Stats: Sendable {
        public let globalActive: Int
        public let globalMax: Int?
        public let perCapability: [Capability: Int]
    }
}
