import Foundation

/// Priority levels for scheduled tasks.
/// Higher priority tasks are dequeued before lower priority tasks.
/// Within the same priority, tasks are processed FIFO.
public enum TaskPriority: Int, Comparable, Sendable {
    case background = 0
    case low = 1
    case normal = 2
    case high = 3
    case critical = 4

    public static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
