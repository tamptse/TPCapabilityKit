@preconcurrency import Foundation
import TPCapabilityKit

/// Injectable queue policy for the Bridge door.
///
/// Single statement of the given-or-main contract: every Bridge completion
/// arrives on the given queue when supplied, or the main queue when omitted.
/// `.givenOrMain` is the live default (calls `ObjcDelivery.on`); `.immediate`
/// runs inline for tests that assert delivery without a live Store or a
/// main-queue pump. The policy never crosses `@objc` — it rides default args
/// on the internal door core, so no `@objc` signature changes.
struct ObjcQueuePolicy: Sendable {
    var deliver: @Sendable (DispatchQueue?, @escaping @Sendable () -> Void) -> Void

    static var givenOrMain: Self {
        Self { queue, work in ObjcDelivery.on(queue, execute: work) }
    }

    static var immediate: Self {
        Self { _, work in work() }
    }
}

/// The single scheduling door behind the Bridge.
///
/// Owns descriptor translation, the one delivery core for every
/// value-returning wait, the schedule-completion hop, the subscribe
/// sink-boxing, and detach-adapter construction. Callers build at most the
/// ObjC-shaped arguments then delegate here, so the given-or-main hop and the
/// sync-vs-wait agreement each live in exactly one place. Timeout compat
/// stays on the `ObjcTimeout` fork — `translate` passes `underlying` through
/// without inspecting timeout.
enum ObjcBridgeDoor {
    /// Id-carrying adapter for the detach path. Store detach reads only the
    /// Plugin id, so this is behaviorally identical to the registration-time
    /// adapter with no `start` side effect.
    struct BridgeDetachAdapter: AppPlugin {
        let id: String
        func start(with store: DynamicStore) {}
    }

    /// Descriptor translation passthrough (via the underlying descriptor; no
    /// timeout inspection).
    static func translate(_ descriptor: ObjcTaskDescriptor) -> TaskDescriptor {
        descriptor.underlying
    }

    /// The one delivery core for every value-returning wait behind the Bridge.
    /// Queued-wait half of the one contract on `DynamicStore.fire` (see it for
    /// the sync-vs-wait agreement); results hop via the injected policy.
    static func waitThenRun(
        store: DynamicStore,
        descriptor: TaskDescriptor,
        queue: DispatchQueue?,
        task: @escaping () -> NSObject,
        completion: @escaping (NSObject?) -> Void,
        policy: ObjcQueuePolicy = .givenOrMain
    ) {
        let taskBox = ObjcCallbackBox(task)
        let completionBox = ObjcCallbackBox(completion)
        Task {
            let result: NSObject? = await store.scheduleTaskAndWait(descriptor) {
                taskBox.value()
            }
            policy.deliver(queue) {
                completionBox.value(result)
            }
        }
    }

    /// Schedule-completion hop behind the door (same policy, same contract).
    static func deliverScheduleCompletion(
        queue: DispatchQueue?,
        policy: ObjcQueuePolicy = .givenOrMain,
        work: @escaping @Sendable () -> Void
    ) {
        policy.deliver(queue, work)
    }

    /// Subscribe sink-boxing behind the door: boxes the observer once, hops
    /// each state value via the injected policy.
    static func subscribeSink(
        queue: DispatchQueue?,
        policy: ObjcQueuePolicy = .givenOrMain,
        observer: @escaping (NSObject?) -> Void
    ) -> (NSObject?) -> Void {
        let observerBox = ObjcCallbackBox(observer)
        return { state in
            policy.deliver(queue) {
                observerBox.value(state)
            }
        }
    }

    /// Capability-subscribe sink-boxing behind the door: same shape as
    /// `subscribeSink` over the per-capability `Bool` grain.
    static func subscribeCapabilitySink(
        queue: DispatchQueue?,
        policy: ObjcQueuePolicy = .givenOrMain,
        observer: @escaping (Bool) -> Void
    ) -> (Bool) -> Void {
        let observerBox = ObjcCallbackBox(observer)
        return { available in
            policy.deliver(queue) {
                observerBox.value(available)
            }
        }
    }

    /// Detach-adapter construction behind the door, so the store-bridge
    /// `unregister` call-site is one line.
    static func makeDetachAdapter(id: String) -> BridgeDetachAdapter {
        BridgeDetachAdapter(id: id)
    }
}

/// Shared box for passing non-Sendable ObjC closures into Tasks.
final class ObjcCallbackBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
