import Foundation
import TPCapabilityKit

/// Objective-C wrapper for TaskDescriptor.
@objc(TPTaskDescriptor)
public final class ObjcTaskDescriptor: NSObject, @unchecked Sendable {
    @objc public var id: String { underlying.id }

    @objc public var priority: Int { underlying.priority.rawValue }

    /// Collapsed timeout reading: the stored value when explicit, otherwise
    /// the pinned compat default. `hasExplicitTimeout` tells the two apart;
    /// both read through the single mapper-owned statement
    /// (`ObjcMapper.displayTimeout`/`hasExplicitTimeout`).
    @objc public var timeout: TimeInterval {
        ObjcMapper.displayTimeout(for: underlying)
    }

    @objc public var hasExplicitTimeout: Bool { ObjcMapper.hasExplicitTimeout(for: underlying) }

    @objc public var maxRetries: Int { underlying.maxRetries }

    @objc public var capabilities: [String] {
        underlying.requiredCapabilities.map { $0.rawValue }
    }

    @objc public var metadata: [String: String] { underlying.metadata }

    /// The underlying Swift TaskDescriptor.
    public let underlying: TaskDescriptor

    /// Creates a new task descriptor. Timeout compat follows the single
    /// mapper-owned resolver (see `ObjcMapper.resolveTimeout`).
    /// - Parameters:
    ///   - capabilities: Array of capability strings required.
    ///   - priority: Priority level (0=background, 4=critical). Default is 2 (normal).
    ///     Out-of-range values coerce to normal (see `ObjcMapper.taskPriority`).
    ///   - timeout: Maximum execution time in seconds. Negative means unspecified,
    ///     so the scheduler Configuration default applies at execution.
    ///   - maxRetries: Maximum retry attempts. Default is 0.
    ///   - metadata: Optional metadata dictionary.
    @objc public convenience init(
        capabilities: [String],
        priority: Int = 2,
        timeout: TimeInterval = ObjcMapper.omittedTimeout,
        maxRetries: Int = 0,
        metadata: [String: String] = [:]
    ) {
        self.init(
            id: nil,
            capabilities: capabilities,
            priority: priority,
            timeout: timeout,
            maxRetries: maxRetries,
            metadata: metadata
        )
    }

    /// Creates a new task descriptor with a client-chosen identifier.
    /// The identifier survives the Bridge round-trip, so cancel-by-id works from ObjC.
    /// Timeout compat follows the single mapper-owned resolver (see `ObjcMapper.resolveTimeout`).
    /// - Parameters:
    ///   - clientId: Client-chosen task identifier, preserved as the descriptor id.
    ///   - capabilities: Array of capability strings required.
    ///   - priority: Priority level (0=background, 4=critical). Default is 2 (normal).
    ///     Out-of-range values coerce to normal (see `ObjcMapper.taskPriority`).
    ///   - timeout: Maximum execution time in seconds. Negative means unspecified,
    ///     so the scheduler Configuration default applies at execution.
    ///   - maxRetries: Maximum retry attempts. Default is 0.
    ///   - metadata: Optional metadata dictionary.
    @objc public convenience init(
        clientId: String,
        capabilities: [String],
        priority: Int = 2,
        timeout: TimeInterval = ObjcMapper.omittedTimeout,
        maxRetries: Int = 0,
        metadata: [String: String] = [:]
    ) {
        self.init(
            id: clientId,
            capabilities: capabilities,
            priority: priority,
            timeout: timeout,
            maxRetries: maxRetries,
            metadata: metadata
        )
    }

    private init(
        id: String?,
        capabilities: [String],
        priority: Int,
        timeout: TimeInterval,
        maxRetries: Int,
        metadata: [String: String]
    ) {
        self.underlying = ObjcMapper.makeDescriptor(
            id: id,
            capabilities: capabilities,
            priority: priority,
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
