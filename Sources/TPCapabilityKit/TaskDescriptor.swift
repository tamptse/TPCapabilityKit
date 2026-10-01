import Foundation

/// Priority levels for scheduled tasks.
/// Higher priority tasks are dequeued before lower priority tasks.
/// Within the same priority, tasks are processed FIFO.
public enum TaskPriority: Int, Comparable, CaseIterable, Sendable, CustomStringConvertible {
    case background = 0
    case low = 1
    case normal = 2
    case high = 3
    case critical = 4

    /// Canonical dequeue sequence from highest priority down to lowest priority.
    public static let dequeueOrder: [TaskPriority] = [.critical, .high, .normal, .low, .background]

    public var description: String {
        switch self {
        case .background: return "background"
        case .low: return "low"
        case .normal: return "normal"
        case .high: return "high"
        case .critical: return "critical"
        }
    }

    public static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

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
    /// Nil means the scheduler's configured default applies.
    public let timeout: TimeInterval?

    /// Maximum number of retry attempts on failure. Default is 0 (no retries).
    public let maxRetries: Int

    /// Metadata for debugging or custom logic. Optional.
    public let metadata: [String: String]

    /// Creates a new TaskDescriptor.
    public init(
        id: String = UUID().uuidString,
        requiredCapabilities: Set<Capability>,
        priority: TaskPriority = .normal,
        timeout: TimeInterval? = nil,
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
