@preconcurrency import Foundation
import Combine
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

    @Test func deliverNilExecutesOnMainThread() {
        let flag = DeliveryFlag()
        ObjcBridgeDelivery.deliver(on: nil) {
            flag.record(wasMain: Thread.isMainThread)
        }

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if flag.snapshot.didRun { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        let snapshot = flag.snapshot
        #expect(snapshot.didRun)
        #expect(snapshot.wasMain)
    }

    @Test func deliverOnBackgroundQueueExecutesOffMain() async {
        struct Observation: Sendable {
            let isMain: Bool
            let onQueue: Bool
        }

        let queue = DispatchQueue(label: "bridge.delivery.policy.\(UUID().uuidString)")
        let identity = QueueIdentity()
        queue.setSpecific(key: identity.key, value: true)

        let gated = AsyncStream<Observation>.makeStream()
        ObjcBridgeDelivery.deliver(on: queue) {
            let observation = Observation(
                isMain: Thread.isMainThread,
                onQueue: DispatchQueue.getSpecific(key: identity.key) == true
            )
            gated.continuation.yield(observation)
            gated.continuation.finish()
        }

        let result = await firstValue(from: gated.stream, timeout: 2.0)
        #expect(result != nil)
        #expect(result?.onQueue == true)
        #expect(result?.isMain == false)
    }

    @Test func receivedDeliversValuesOnGivenQueue() async {
        struct Observation: Sendable {
            let value: Int
            let onQueue: Bool
            let isMain: Bool
        }

        let queue = DispatchQueue(label: "bridge.received.policy.\(UUID().uuidString)")
        let identity = QueueIdentity()
        queue.setSpecific(key: identity.key, value: true)

        let subject = PassthroughSubject<Int, Never>()
        let gated = AsyncStream<Observation>.makeStream()
        let cancellable = ObjcBridgeDelivery.received(subject.eraseToAnyPublisher(), on: queue)
            .sink { value in
                gated.continuation.yield(Observation(
                    value: value,
                    onQueue: DispatchQueue.getSpecific(key: identity.key) == true,
                    isMain: Thread.isMainThread
                ))
                gated.continuation.finish()
            }
        defer { _ = cancellable }

        subject.send(42)

        let result = await firstValue(from: gated.stream, timeout: 2.0)
        #expect(result?.value == 42)
        #expect(result?.onQueue == true)
        #expect(result?.isMain == false)
    }
}
