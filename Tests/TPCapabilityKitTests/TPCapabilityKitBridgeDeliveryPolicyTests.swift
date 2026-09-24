@preconcurrency import Foundation
import Testing
@testable import TPCapabilityKit
@testable import TPCapabilityKitBridge

private final class DeliveryFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var didRun = false
    private var wasMain = false

    func record(wasMain isMain: Bool) {
        lock.withLock {
            didRun = true
            wasMain = isMain
        }
    }

    var snapshot: (didRun: Bool, wasMain: Bool) {
        lock.withLock { (didRun, wasMain) }
    }
}

private final class QueueIdentity: @unchecked Sendable {
    let key = DispatchSpecificKey<Bool>()
}

struct BridgeDeliveryPolicyTests {
    private func firstValue<T: Sendable>(from stream: AsyncStream<T>, timeout seconds: Double) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                for await value in stream { return value }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            var result: T? = nil
            for await value in group {
                if let value {
                    result = value
                }
                break
            }
            group.cancelAll()
            return result
        }
    }

    @Test func bridgeSubscribeNilDeliversOnMain() {
        let bridge = ObjcStoreBridge(store: DynamicStore())
        let pluginId = "DeliveryPolicy_\(UUID().uuidString)"
        let flag = DeliveryFlag()
        let cancellable = bridge.subscribe(pluginId: pluginId, queue: nil) { _ in
            flag.record(wasMain: Thread.isMainThread)
        }
        defer { cancellable.cancel() }

        bridge.updateState(pluginId: pluginId, newState: NSString(string: "Main"))

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if flag.snapshot.didRun { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        let snapshot = flag.snapshot
        #expect(snapshot.didRun)
        #expect(snapshot.wasMain)
    }

    @Test func bridgeSubscribeDeliversOnGivenQueue() async {
        struct Observation: Sendable {
            let onQueue: Bool
            let isMain: Bool
        }

        let bridge = ObjcStoreBridge(store: DynamicStore())
        let pluginId = "DeliveryPolicy_\(UUID().uuidString)"
        let queue = DispatchQueue(label: "bridge.subscribe.policy.\(UUID().uuidString)")
        let identity = QueueIdentity()
        queue.setSpecific(key: identity.key, value: true)

        let gated = AsyncStream<Observation>.makeStream()
        let cancellable = bridge.subscribe(pluginId: pluginId, queue: queue) { _ in
            gated.continuation.yield(Observation(
                onQueue: DispatchQueue.getSpecific(key: identity.key) == true,
                isMain: Thread.isMainThread
            ))
            gated.continuation.finish()
        }
        defer { cancellable.cancel() }

        bridge.updateState(pluginId: pluginId, newState: NSString(string: "Custom"))

        let result = await firstValue(from: gated.stream, timeout: 2.0)
        #expect(result != nil)
        #expect(result?.onQueue == true)
        #expect(result?.isMain == false)
    }

    @Test func bridgeCapabilitySubscribeDeliversOnGivenQueue() async {
        struct Observation: Sendable {
            let onQueue: Bool
            let isMain: Bool
        }

        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let uniqueCap = "deliveryCap_\(UUID().uuidString)"
        let queue = DispatchQueue(label: "bridge.capability.policy.\(UUID().uuidString)")
        let identity = QueueIdentity()
        queue.setSpecific(key: identity.key, value: true)

        let gated = AsyncStream<Observation>.makeStream()
        let cancellable = bridge.subscribeCapability(uniqueCap, queue: queue) { _ in
            gated.continuation.yield(Observation(
                onQueue: DispatchQueue.getSpecific(key: identity.key) == true,
                isMain: Thread.isMainThread
            ))
            gated.continuation.finish()
        }
        defer { cancellable.cancel() }

        let result = await firstValue(from: gated.stream, timeout: 2.0)
        #expect(result != nil)
        #expect(result?.onQueue == true)
        #expect(result?.isMain == false)
    }

    @Test func viewWaitNilDeliversOnMain() async {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let pluginId = "DeliveryPolicyWait_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }

        await withCheckedContinuation { continuation in
            bridge.taskScheduler.runWhenAvailable(
                capability: "heavyTask", timeout: 1.0, queue: nil,
                task: { NSString(string: "MainDefault") },
                completion: { result in
                    #expect(Thread.isMainThread)
                    #expect((result as? String) == "MainDefault")
                    continuation.resume()
                }
            )
        }
    }

    @Test func viewWaitDeliversOnGivenQueue() async {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let pluginId = "DeliveryPolicyWait_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }

        let queue = DispatchQueue(label: "bridge.wait.policy.\(UUID().uuidString)")
        let key = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: key, value: true)

        await withCheckedContinuation { continuation in
            bridge.taskScheduler.runWhenAvailable(
                capability: "heavyTask", timeout: 1.0, queue: queue,
                task: { NSString(string: "CustomQueue") },
                completion: { result in
                    #expect(DispatchQueue.getSpecific(key: key) == true)
                    #expect((result as? String) == "CustomQueue")
                    continuation.resume()
                }
            )
        }
    }
}
