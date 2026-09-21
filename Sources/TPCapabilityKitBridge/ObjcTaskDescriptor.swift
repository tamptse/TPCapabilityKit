import Foundation
import TPCapabilityKit

/// Objective-C wrapper for TaskDescriptor.
@objc(TPTaskDescriptor)
public final class ObjcTaskDescriptor: NSObject, @unchecked Sendable {
    @objc public var id: String { underlying.id }

    @objc public var priority: Int { underlying.priority.rawValue }

    @objc public var timeout: TimeInterval {
        underlying.timeout ?? TaskScheduler.Configuration.default.defaultTimeout
    }

    @objc public var maxRetries: Int { underlying.maxRetries }

    @objc public var capabilities: [String] {
        underlying.requiredCapabilities.map { $0.rawValue }
    }

    @objc public var metadata: [String: String] { underlying.metadata }

    /// The underlying Swift TaskDescriptor.
    public let underlying: TaskDescriptor

    /// Creates a new task descriptor.
    /// - Parameters:
    ///   - capabilities: Array of capability strings required.
    ///   - priority: Priority level (0=background, 4=critical). Default is 2 (normal).
    ///     Out-of-range values coerce to normal (see `ObjcMapper.taskPriority`).
    ///   - timeout: Maximum execution time in seconds. Defaults to the scheduler Configuration default.
    ///   - maxRetries: Maximum retry attempts. Default is 0.
    ///   - metadata: Optional metadata dictionary.
    @objc public init(
        capabilities: [String],
        priority: Int = 2,
        timeout: TimeInterval = TaskScheduler.Configuration.default.defaultTimeout,
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
        super.init()
    }

    internal init(underlying: TaskDescriptor) {
        self.underlying = underlying
        super.init()
    }
}
