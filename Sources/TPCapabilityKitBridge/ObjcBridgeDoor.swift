@preconcurrency import Foundation
import TPCapabilityKit

/// Injectable queue policy for the Bridge door.
///
/// Single statement of the given-or-main contract: every Bridge completion
/// arrives on the given queue when supplied, or the main queue when omitted.
/// `.givenOrMain` is the live default; `.immediate`
/// runs inline for tests that assert delivery without a live Store or a
/// main-queue pump. The policy never crosses `@objc` — it rides default args
/// on the internal door core, so no `@objc` signature changes.
struct ObjcQueuePolicy: Sendable {
    var deliver: @Sendable (DispatchQueue?, @escaping @Sendable () -> Void) -> Void

    static var givenOrMain: Self {
        Self { queue, work in (queue ?? .main).async(execute: work) }
    }

    static var immediate: Self {
        Self { _, work in work() }
    }
}

/// The single scheduling door behind the Bridge.
///
/// Owns the capability-spelling descriptor build, the one value-returning wait
/// core (no queue knowledge), the one delivery hop (no Store knowledge), and
/// detach-adapter construction. Callers build at most the ObjC-shaped
/// arguments then delegate here, so the given-or-main hop and the sync-vs-wait
/// agreement each live in exactly one place. Timeout compat stays on the
/// `ObjcTimeout` fork — callers pass `underlying` through without inspecting
/// timeout.
enum ObjcBridgeDoor {
    /// Id-carrying adapter for the detach path. Store detach reads only the
    /// Plugin id, so this is behaviorally identical to the registration-time
    /// adapter with no `start` side effect.
    struct BridgeDetachAdapter: AppPlugin {
        let id: String
        func start(with store: DynamicStore) {}
    }

    /// Capability-spelling build inside the door: constructs the descriptor
    /// through the same ObjC spelling the facade used to build at its call
    /// site (same defaults, same wire fork), then funnels to the descriptor
    /// core below, so the two wait spellings cannot diverge.
    static func waitThenRun(
        store: DynamicStore,
        capability: String,
        timeout: TimeInterval,
        queue: DispatchQueue?,
        task: @escaping () -> NSObject,
        completion: @escaping (NSObject?) -> Void,
        policy: ObjcQueuePolicy = .givenOrMain
    ) {
        waitThenRun(
            store: store,
            descriptor: ObjcTaskDescriptor(capabilities: [capability], timeout: timeout).underlying,
            queue: queue,
            task: task,
            completion: completion,
            policy: policy
        )
    }

    /// The one value-returning wait entry behind the Bridge. Thin composition
    /// over the wait core plus the one hop below: capability-spelling callers
    /// funnel through this descriptor spelling, which funnels through the
    /// core, so the two wait spellings cannot diverge.
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
            let result = await waitCore(store: store, descriptor: descriptor, taskBox: taskBox)
            hop(queue: queue, policy: policy) {
                completionBox.value(result)
            }
        }
    }

    /// Wait core: the one value-returning wait for every Bridge wait spelling.
    /// No queue knowledge — no queue, no policy, no delivery. Returns the
    /// task result (or nil on timeout) for the hop to deliver.
    private static func waitCore(
        store: DynamicStore,
        descriptor: TaskDescriptor,
        taskBox: ObjcCallbackBox<() -> NSObject>
    ) async -> NSObject? {
        await store.scheduleTaskAndWait(descriptor) {
            taskBox.value()
        }
    }

    /// Delivery hop: the one given-or-main crossing for schedule completions,
    /// wait completions, and subscribe values. No Store knowledge — only the
    /// injected policy decides the queue.
    private static func hop(
        queue: DispatchQueue?,
        policy: ObjcQueuePolicy,
        work: @escaping @Sendable () -> Void
    ) {
        policy.deliver(queue, work)
    }

    /// Schedule-completion hop behind the door (same hop, same contract).
    static func deliverScheduleCompletion(
        queue: DispatchQueue?,
        policy: ObjcQueuePolicy = .givenOrMain,
        work: @escaping @Sendable () -> Void
    ) {
        hop(queue: queue, policy: policy, work: work)
    }

    /// Subscribe sink-boxing behind the door: boxes the observer once, hops
    /// each state value via the injected policy.
    static func subscribeSink(
        queue: DispatchQueue?,
        policy: ObjcQueuePolicy = .givenOrMain,
        observer: @escaping (NSObject?) -> Void
    ) -> (NSObject?) -> Void {
        boxedSink(queue: queue, policy: policy, observer: observer)
    }

    /// Capability-subscribe sink-boxing behind the door: same shape as
    /// `subscribeSink` over the per-capability `Bool` grain.
    static func subscribeCapabilitySink(
        queue: DispatchQueue?,
        policy: ObjcQueuePolicy = .givenOrMain,
        observer: @escaping (Bool) -> Void
    ) -> (Bool) -> Void {
        boxedSink(queue: queue, policy: policy, observer: observer)
    }

    private static func boxedSink<T: Sendable>(
        queue: DispatchQueue?,
        policy: ObjcQueuePolicy,
        observer: @escaping (T) -> Void
    ) -> (T) -> Void {
        let observerBox = ObjcCallbackBox(observer)
        return { value in
            hop(queue: queue, policy: policy) {
                observerBox.value(value)
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
