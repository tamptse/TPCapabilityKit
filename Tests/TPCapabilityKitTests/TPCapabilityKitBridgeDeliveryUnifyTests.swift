@preconcurrency import Foundation
import Testing
@testable import TPCapabilityKit
@testable import TPCapabilityKitBridge

/// Deterministic delivery pins for the unified Bridge seam (r7-02).
///
/// Every pin crosses the public Bridge/view seam and asserts externally
/// observable delivery (given queue vs main when omitted) via continuation
/// rendezvous — no sleeps, polls, semaphores, or RunLoop spins. Scheduling
/// outcome (Lease terminal state, cancel, counts) is asserted alongside the
/// thread hop to prove zero behavior change beyond delivery.
struct BridgeDeliveryUnifyTests {
    private func makeBridge() -> (DynamicStore, ObjcStoreBridge) {
        let store = DynamicStore()
        return (store, ObjcStoreBridge(store: store))
    }

    private func register(_ capability: Capability, on store: DynamicStore) -> String {
        let pluginId = "DeliveryUnify_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [capability])
        return pluginId
    }

    @Test func scheduleArrivesOnGivenQueue() async {
        let (store, bridge) = makeBridge()
        let pluginId = register(.heavyTask, on: store)
        defer { store.unregisterCapability(for: pluginId) }
        let view = bridge.taskScheduler

        let queue = DispatchQueue(label: "delivery.unify.schedule.\(UUID().uuidString)")
        let identity = DeliveryQueueIdentity()
        queue.setSpecific(key: identity.key, value: true)

        let descriptor = ObjcTaskDescriptor(capabilities: ["heavyTask"], timeout: 5.0)
        await withCheckedContinuation { continuation in
            let lease = view.schedule(descriptor, queue: queue, task: {}, completion: { completed in
                #expect(DispatchQueue.getSpecific(key: identity.key) == true)
                #expect(Thread.isMainThread == false)
                #expect(completed.state == .completed)
                continuation.resume()
            })
            #expect(lease.state == .pending || lease.state == .active || lease.state == .completed)
        }
        #expect(view.pendingCount == 0)
        #expect(view.activeCount == 0)
    }

    @Test func scheduleArrivesOnMainWhenOmitted() async {
        let (store, bridge) = makeBridge()
        let pluginId = register(.heavyTask, on: store)
        defer { store.unregisterCapability(for: pluginId) }
        let view = bridge.taskScheduler

        let descriptor = ObjcTaskDescriptor(capabilities: ["heavyTask"], timeout: 5.0)
        await withCheckedContinuation { continuation in
            _ = view.schedule(descriptor, task: {}, completion: { completed in
                #expect(Thread.isMainThread)
                #expect(completed.state == .completed)
                continuation.resume()
            })
        }
        #expect(view.pendingCount == 0)
        #expect(view.activeCount == 0)
    }

    @Test func scheduleAndWaitArrivesOnGivenQueue() async {
        let (store, bridge) = makeBridge()
        let pluginId = register(.heavyTask, on: store)
        defer { store.unregisterCapability(for: pluginId) }

        let queue = DispatchQueue(label: "delivery.unify.scheduleAndWait.\(UUID().uuidString)")
        let identity = DeliveryQueueIdentity()
        queue.setSpecific(key: identity.key, value: true)

        let descriptor = ObjcTaskDescriptor(capabilities: ["heavyTask"], timeout: 5.0)
        await withCheckedContinuation { continuation in
            bridge.taskScheduler.scheduleAndWait(descriptor, queue: queue, task: {
                NSString(string: "ScheduleAndWait")
            }, completion: { result in
                #expect(DispatchQueue.getSpecific(key: identity.key) == true)
                #expect((result as? String) == "ScheduleAndWait")
                continuation.resume()
            })
        }
    }

    @Test func runWhenAvailableArrivesOnGivenQueue() async {
        let (store, bridge) = makeBridge()
        let pluginId = register(.heavyTask, on: store)
        defer { store.unregisterCapability(for: pluginId) }

        let queue = DispatchQueue(label: "delivery.unify.runWhenAvailable.\(UUID().uuidString)")
        let identity = DeliveryQueueIdentity()
        queue.setSpecific(key: identity.key, value: true)

        await withCheckedContinuation { continuation in
            bridge.taskScheduler.runWhenAvailable(
                capability: "heavyTask", timeout: 5.0, queue: queue,
                task: { NSString(string: "RunWhenAvailable") },
                completion: { result in
                    #expect(DispatchQueue.getSpecific(key: identity.key) == true)
                    #expect((result as? String) == "RunWhenAvailable")
                    continuation.resume()
                }
            )
        }
    }

    @Test func waitSpellingsAgreeOnMainWhenOmitted() async {
        let (store, bridge) = makeBridge()
        let pluginId = register(.heavyTask, on: store)
        defer { store.unregisterCapability(for: pluginId) }

        async let scheduleAndWaitDone: Void = await withCheckedContinuation { continuation in
            let descriptor = ObjcTaskDescriptor(capabilities: ["heavyTask"], timeout: 5.0)
            bridge.taskScheduler.scheduleAndWait(descriptor, task: {
                NSString(string: "WaitMain")
            }, completion: { result in
                #expect(Thread.isMainThread)
                #expect((result as? String) == "WaitMain")
                continuation.resume()
            })
        }
        async let runWhenAvailableDone: Void = await withCheckedContinuation { continuation in
            bridge.taskScheduler.runWhenAvailable(
                capability: "heavyTask", timeout: 5.0, queue: nil,
                task: { NSString(string: "RunMain") },
                completion: { result in
                    #expect(Thread.isMainThread)
                    #expect((result as? String) == "RunMain")
                    continuation.resume()
                }
            )
        }

        await scheduleAndWaitDone
        await runWhenAvailableDone
    }

    @Test func subscribeArrivesOnGivenQueue() async {
        let (_, bridge) = makeBridge()
        let pluginId = "DeliveryUnifySub_\(UUID().uuidString)"

        let queue = DispatchQueue(label: "delivery.unify.subscribe.\(UUID().uuidString)")
        let identity = DeliveryQueueIdentity()
        queue.setSpecific(key: identity.key, value: true)

        var cancellable: ObjcCancellable?
        defer { cancellable?.cancel() }
        await withCheckedContinuation { continuation in
            cancellable = bridge.subscribe(pluginId: pluginId, queue: queue) { state in
                #expect(DispatchQueue.getSpecific(key: identity.key) == true)
                #expect((state as? String) == "GivenQueue")
                continuation.resume()
            }
            bridge.updateState(pluginId: pluginId, newState: NSString(string: "GivenQueue"))
        }
    }

    @Test func subscribeArrivesOnMainWhenOmitted() async {
        let (_, bridge) = makeBridge()
        let pluginId = "DeliveryUnifySubMain_\(UUID().uuidString)"

        var cancellable: ObjcCancellable?
        defer { cancellable?.cancel() }
        await withCheckedContinuation { continuation in
            cancellable = bridge.subscribe(pluginId: pluginId, queue: nil) { state in
                #expect(Thread.isMainThread)
                #expect((state as? String) == "MainDefault")
                continuation.resume()
            }
            bridge.updateState(pluginId: pluginId, newState: NSString(string: "MainDefault"))
        }
    }

    @Test func subscribeCapabilityArrivesOnGivenQueue() async {
        let (store, bridge) = makeBridge()
        let uniqueCap = "deliveryUnifyCap_\(UUID().uuidString)"
        let pluginId = register(.custom(uniqueCap), on: store)
        defer { store.unregisterCapability(for: pluginId) }

        let queue = DispatchQueue(label: "delivery.unify.subscribeCap.\(UUID().uuidString)")
        let identity = DeliveryQueueIdentity()
        queue.setSpecific(key: identity.key, value: true)

        var cancellable: ObjcCancellable?
        defer { cancellable?.cancel() }
        await withCheckedContinuation { continuation in
            cancellable = bridge.subscribeCapability(uniqueCap, queue: queue) { available in
                #expect(DispatchQueue.getSpecific(key: identity.key) == true)
                #expect(available == true)
                continuation.resume()
            }
        }
    }

    @Test func subscribeCapabilityArrivesOnMainWhenOmitted() async {
        let (store, bridge) = makeBridge()
        let uniqueCap = "deliveryUnifyCapMain_\(UUID().uuidString)"
        let pluginId = register(.custom(uniqueCap), on: store)
        defer { store.unregisterCapability(for: pluginId) }

        var cancellable: ObjcCancellable?
        defer { cancellable?.cancel() }
        await withCheckedContinuation { continuation in
            cancellable = bridge.subscribeCapability(uniqueCap, queue: nil) { available in
                #expect(Thread.isMainThread)
                #expect(available == true)
                continuation.resume()
            }
        }
    }

    @Test func scheduleCancelOnGivenQueueLeavesNoResidue() async {
        let (_, bridge) = makeBridge()
        let uniqueCap = "deliveryUnifyCancel_\(UUID().uuidString)"
        let view = bridge.taskScheduler

        let queue = DispatchQueue(label: "delivery.unify.cancel.\(UUID().uuidString)")
        let identity = DeliveryQueueIdentity()
        queue.setSpecific(key: identity.key, value: true)

        let descriptor = ObjcTaskDescriptor(capabilities: [uniqueCap], timeout: 5.0)
        await withCheckedContinuation { continuation in
            let lease = view.schedule(descriptor, queue: queue, task: {}, completion: { completed in
                #expect(DispatchQueue.getSpecific(key: identity.key) == true)
                #expect(completed.state == .expired)
                continuation.resume()
            })
            view.cancel(taskId: descriptor.id)
            #expect(lease.taskId == descriptor.id)
        }
        #expect(view.pendingCount == 0)
        #expect(view.activeCount == 0)
    }
}

private final class DeliveryQueueIdentity: @unchecked Sendable {
    let key = DispatchSpecificKey<Bool>()
}
