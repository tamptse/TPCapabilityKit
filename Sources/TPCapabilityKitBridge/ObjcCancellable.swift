import Combine
import Foundation

/// Objective-C wrapper token for managing `AnyCancellable` subscription lifecycles.
@objc(TPCancellable)
public final class ObjcCancellable: NSObject, @unchecked Sendable {
    private var cancellable: AnyCancellable?
    private let lock = NSLock()

    /// Initializes with an `AnyCancellable` instance.
    public init(_ cancellable: AnyCancellable) {
        self.cancellable = cancellable
        super.init()
    }

    /// Cancels the active subscription.
    @objc public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancellable?.cancel()
        cancellable = nil
    }

    deinit {
        cancel()
    }
}
