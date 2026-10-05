import Foundation
import TPCapabilityKit

/// Objective-C wrapper for TaskDescriptor.
@objc(TPTaskDescriptor)
public final class ObjcTaskDescriptor: NSObject, @unchecked Sendable {
    @objc public var id: String { underlying.id }

    @objc public var priority: Int { underlying.priority.rawValue }

    private var storedTimeout: ObjcTimeout { ObjcTimeout.fromStored(underlying.timeout) }

    /// Collapsed timeout reading: the stored optional when present, otherwise
    /// the pinned compat default. `hasExplicitTimeout` tells the two apart;
    /// both read through the single stored-timeout helper below.
    @objc public var timeout: TimeInterval { storedTimeout.display }

    @objc public var hasExplicitTimeout: Bool { storedTimeout.isExplicit }

    @objc public var maxRetries: Int { underlying.maxRetries }

    @objc public var capabilities: [String] {
        underlying.requiredCapabilities.map { $0.rawValue }
    }

    @objc public var metadata: [String: String] { underlying.metadata }

    /// The underlying Swift TaskDescriptor holding the single stored timeout truth.
    public let underlying: TaskDescriptor

    /// Creates a new task descriptor. Timeout compat follows the single
    /// timeout-form-owned fork (see `ObjcTimeout.resolve`), delegating
    /// unspecified resolution to `Deadline` (`Time.swift`).
    /// - Parameters:
    ///   - capabilities: Array of capability strings required.
    ///   - priority: Priority level (0=background, 4=critical). Default is 2 (normal).
    ///     Out-of-range values coerce to normal (see `ObjcMapper.taskPriority`).
    ///   - timeout: Maximum execution time in seconds. Negative means unspecified,
    ///     so the scheduler Configuration default applies at Deadline construction.
    ///   - maxRetries: Maximum retry attempts. Default is 0.
    ///   - metadata: Optional metadata dictionary.
    @objc public convenience init(
        capabilities: [String],
        priority: Int = 2,
        timeout: TimeInterval = ObjcTimeout.pinnedDefault,
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
    /// Timeout compat follows the single timeout-form-owned fork (see `ObjcTimeout.resolve`),
    /// delegating unspecified resolution to `Deadline` (`Time.swift`).
    /// - Parameters:
    ///   - clientId: Client-chosen task identifier, preserved as the descriptor id.
    ///   - capabilities: Array of capability strings required.
    ///   - priority: Priority level (0=background, 4=critical). Default is 2 (normal).
    ///     Out-of-range values coerce to normal (see `ObjcMapper.taskPriority`).
    ///   - timeout: Maximum execution time in seconds. Negative means unspecified,
    ///     so the scheduler Configuration default applies at Deadline construction.
    ///   - maxRetries: Maximum retry attempts. Default is 0.
    ///   - metadata: Optional metadata dictionary.
    @objc public convenience init(
        clientId: String,
        capabilities: [String],
        priority: Int = 2,
        timeout: TimeInterval = ObjcTimeout.pinnedDefault,
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

    /// Single owner of ObjC shape plus auto-versus-client identifier policy:
    /// both public initializers share this one private build core differing
    /// only in identifier input (absent auto-generates, client-supplied
    /// preserved for cancel-by-identifier). Keeps own path for multi-capability
    /// plus id policy; single-capability shape lives in
    /// `TaskDescriptor.singleCapability`. Capability mapping plus priority
    /// coercion delegate to `ObjcMapper`, and timeout translation delegates
    /// to `ObjcTimeout.resolve` (with unspecified resolution owned solely by
    /// `Deadline` in `Time.swift`); the wrapper never restates fork or range
    /// prose of its own.
    private init(
        id: String?,
        capabilities: [String],
        priority: Int,
        timeout wire: TimeInterval,
        maxRetries: Int,
        metadata: [String: String]
    ) {
        let stored = ObjcTimeout.resolve(wire: wire)
        self.underlying = TaskDescriptor(
            id: id ?? UUID().uuidString,
            requiredCapabilities: Set(capabilities.map { ObjcMapper.capability(from: $0) }),
            priority: ObjcMapper.taskPriority(from: priority),
            timeout: stored.resolved,
            maxRetries: maxRetries,
            metadata: metadata
        )
        super.init()
    }

    /// Strict pre-flight check over the single mapper-owned range.
    /// Returns false for raw values the constructors would coerce to normal.
    /// Additive; lenient construction behavior is unchanged.
    @objc public static func isValidPriority(_ priority: Int) -> Bool {
        ObjcMapper.isValidPriority(priority)
    }

    internal init(underlying: TaskDescriptor) {
        self.underlying = underlying
        super.init()
    }
}
