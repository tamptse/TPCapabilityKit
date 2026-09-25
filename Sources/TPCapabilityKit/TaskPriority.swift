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
