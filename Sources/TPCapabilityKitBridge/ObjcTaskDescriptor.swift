import Foundation
import TPCapabilityKit

/// Objective-C wrapper for TaskDescriptor.
@objc(TPTaskDescriptor)
public final class ObjcTaskDescriptor: NSObject, @unchecked Sendable {
    /// Unique identifier for this task.
    @objc public let id: String

    /// Priority level (TaskPriority.rawValue).
    @objc public let priority: Int

    /// Maximum time in seconds the task can run.
    @objc public let timeout: TimeInterval

    /// Maximum number of retry attempts.
    @objc public let maxRetries: Int

    /// Capabilities required to execute this task.
    @objc public let capabilities: [String]

    /// Metadata for debugging or custom logic.
    @objc public let metadata: [String: String]

    /// The underlying Swift TaskDescriptor.
    public let underlying: TaskDescriptor

    /// Creates a new task descriptor.
    /// - Parameters:
    ///   - capabilities: Array of capability strings required.
    ///   - priority: Priority level (0=background, 4=critical). Default is 2 (normal).
    ///   - timeout: Maximum execution time in seconds. Default is 30.0.
    ///   - maxRetries: Maximum retry attempts. Default is 0.
    ///   - metadata: Optional metadata dictionary.
    @objc public init(
        capabilities: [String],
        priority: Int = 2,
        timeout: TimeInterval = 30.0,
        maxRetries: Int = 0,
        metadata: [String: String] = [:]
    ) {
        let caps = capabilities.map { ObjcMapper.capability(from: $0) }
        self.underlying = TaskDescriptor(
            requiredCapabilities: Set(caps),
            priority: ObjcMapper.taskPriority(from: priority),
            timeout: timeout,
            maxRetries: maxRetries,
            metadata: metadata
        )
        self.id = underlying.id
        self.priority = priority
        self.timeout = timeout
        self.maxRetries = maxRetries
        self.capabilities = capabilities
        self.metadata = metadata
        super.init()
    }

    internal init(underlying: TaskDescriptor) {
        self.underlying = underlying
        self.id = underlying.id
        self.priority = underlying.priority.rawValue
        self.timeout = underlying.timeout
        self.maxRetries = underlying.maxRetries
        self.capabilities = underlying.requiredCapabilities.map { $0.rawValue }
        self.metadata = underlying.metadata
        super.init()
    }
}
