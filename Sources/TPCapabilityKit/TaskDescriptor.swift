import Foundation

/// Describes a task to be scheduled by the TaskScheduler.
/// Contains all metadata needed for capability matching, prioritization, and lifecycle management.
public struct TaskDescriptor: Sendable, Identifiable {
    /// Unique identifier for this task instance.
    public let id: String

    /// Capabilities required to execute this task. All must be available.
    public let requiredCapabilities: Set<Capability>

    /// Priority level. Higher priority tasks are dequeued first.
    public let priority: TaskPriority

    /// Maximum time in seconds the task can run before lease expires.
    /// Default is 30.0 seconds.
    public let timeout: TimeInterval

    /// Maximum number of retry attempts on failure. Default is 0 (no retries).
    public let maxRetries: Int

    /// Metadata for debugging or custom logic. Optional.
    public let metadata: [String: String]

    /// Creates a new TaskDescriptor.
    public init(
        id: String = UUID().uuidString,
        requiredCapabilities: Set<Capability>,
        priority: TaskPriority = .normal,
        timeout: TimeInterval = 30.0,
        maxRetries: Int = 0,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.requiredCapabilities = requiredCapabilities
        self.priority = priority
        self.timeout = timeout
        self.maxRetries = maxRetries
        self.metadata = metadata
    }
}
