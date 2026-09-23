import Testing
import Foundation
@testable import TPCapabilityKit
@testable import TPCapabilityKitBridge

/// Pins the Bridge single scheduler view: every scheduling call — schedule,
/// wait-then-run, cancel, counts, sync fast-path — crosses `ObjcTaskScheduler`,
/// which owns descriptor building, timeout compat, queue hopping, and defaults
/// with one delivery story. All pins are behavior-level through public
/// interfaces; completion rendezvous replaces sleeps and polls.
struct BridgeSingleViewTests {
    private func makeBridge() -> (DynamicStore, ObjcStoreBridge) {
        let store = DynamicStore()
        return (store, ObjcStoreBridge(store: store))
    }

    private func register(_ capability: Capability, on store: DynamicStore) -> String {
        let pluginId = "SingleView_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [capability])
        return pluginId
    }

    @Test func viewWaitThenRunDeliversResultWhenAvailable() async {
        let (store, bridge) = makeBridge()
        let pluginId = register(.heavyTask, on: store)
        defer { store.unregisterCapability(for: pluginId) }

        await withCheckedContinuation { continuation in
            bridge.taskScheduler.runWhenAvailable(
                capability: "heavyTask", timeout: 1.0, queue: nil,
                task: { NSString(string: "ViewWait") },
                completion: { result in
                    #expect((result as? String) == "ViewWait")
                    continuation.resume()
                }
            )
        }
    }

    @Test func viewWaitThenRunReturnsNilWhenUnavailable() async {
        let (_, bridge) = makeBridge()
        let uniqueCap = "singleViewMissing_\(UUID().uuidString)"

        await withCheckedContinuation { continuation in
            bridge.taskScheduler.runWhenAvailable(
                capability: uniqueCap, timeout: 0.1, queue: nil,
                task: { NSString(string: "ShouldNotRun") },
                completion: { result in
                    #expect(result == nil)
                    continuation.resume()
                }
            )
        }
    }

    @Test func bridgeWaitThenRunAgreesWithViewScheduleAndWait() async {
        let (store, bridge) = makeBridge()
        let uniqueCap = "agreeCap_\(UUID().uuidString)"
        let pluginId = register(.custom(uniqueCap), on: store)
        defer { store.unregisterCapability(for: pluginId) }

        async let bridgeDone: Void = await withCheckedContinuation { continuation in
            bridge.runTaskWhenAvailable(
                capability: uniqueCap, timeout: 1.0, queue: nil,
                task: { NSString(string: "BridgeWait") },
                completion: { result in
                    #expect((result as? String) == "BridgeWait")
                    continuation.resume()
                }
            )
        }
        async let viewDone: Void = await withCheckedContinuation { continuation in
            bridge.taskScheduler.scheduleAndWait(
                ObjcTaskDescriptor(capabilities: [uniqueCap], timeout: 1.0),
                task: { NSString(string: "ViewWait") },
                completion: { result in
                    #expect((result as? String) == "ViewWait")
                    continuation.resume()
                }
            )
        }

        await bridgeDone
        await viewDone
    }

    @Test func bridgeAndViewWaitAgreeWhenUnavailable() async {
        let (_, bridge) = makeBridge()
        let uniqueCap = "agreeMissing_\(UUID().uuidString)"

        async let bridgeDone: Void = await withCheckedContinuation { continuation in
            bridge.runTaskWhenAvailable(
                capability: uniqueCap, timeout: 0.1, queue: nil,
                task: { NSString(string: "ShouldNotRun") },
                completion: { result in
                    #expect(result == nil)
                    continuation.resume()
                }
            )
        }
        async let viewDone: Void = await withCheckedContinuation { continuation in
            bridge.taskScheduler.runWhenAvailable(
                capability: uniqueCap, timeout: 0.1, queue: nil,
                task: { NSString(string: "ShouldNotRun") },
                completion: { result in
                    #expect(result == nil)
                    continuation.resume()
                }
            )
        }

        await bridgeDone
        await viewDone
    }

    @Test func viewSyncAndWaitAgreeWhenAvailable() async {
        let (store, bridge) = makeBridge()
        let pluginId = register(.heavyTask, on: store)
        defer { store.unregisterCapability(for: pluginId) }

        let syncResult = bridge.taskScheduler.runIfAvailable(capability: "heavyTask") {
            NSString(string: "SyncResult")
        }
        #expect((syncResult as? String) == "SyncResult")

        await withCheckedContinuation { continuation in
            bridge.taskScheduler.runWhenAvailable(
                capability: "heavyTask", timeout: 1.0, queue: nil,
                task: { NSString(string: "AsyncResult") },
                completion: { result in
                    #expect((result as? String) == "AsyncResult")
                    continuation.resume()
                }
            )
        }
    }

    @Test func viewSyncAndWaitAgreeWhenUnavailable() async {
        let (_, bridge) = makeBridge()
        let uniqueCap = "syncMissing_\(UUID().uuidString)"

        let syncResult = bridge.taskScheduler.runIfAvailable(capability: uniqueCap) {
            NSString(string: "ShouldNotRun")
        }
        #expect(syncResult == nil)

        await withCheckedContinuation { continuation in
            bridge.taskScheduler.runWhenAvailable(
                capability: uniqueCap, timeout: 0.1, queue: nil,
                task: { NSString(string: "ShouldNotRun") },
                completion: { result in
                    #expect(result == nil)
                    continuation.resume()
                }
            )
        }
    }

    @Test func bridgeSyncAgreesWithViewSync() {
        let (store, bridge) = makeBridge()
        let pluginId = register(.heavyTask, on: store)
        defer { store.unregisterCapability(for: pluginId) }

        let bridgeResult = bridge.runTask(capability: "heavyTask") {
            NSString(string: "BridgeSync")
        }
        let viewResult = bridge.taskScheduler.runIfAvailable(capability: "heavyTask") {
            NSString(string: "ViewSync")
        }
        #expect((bridgeResult as? String) == "BridgeSync")
        #expect((viewResult as? String) == "ViewSync")

        let uniqueCap = "bridgeSyncMissing_\(UUID().uuidString)"
        #expect(bridge.runTask(capability: uniqueCap) { NSString(string: "X") } == nil)
        #expect(bridge.taskScheduler.runIfAvailable(capability: uniqueCap) { NSString(string: "X") } == nil)
    }

    @Test func viewWaitNegativeTimeoutMeansUnspecified() async {
        let (store, bridge) = makeBridge()
        let pluginId = register(.heavyTask, on: store)
        defer { store.unregisterCapability(for: pluginId) }

        await withCheckedContinuation { continuation in
            bridge.taskScheduler.runWhenAvailable(
                capability: "heavyTask", timeout: -1, queue: nil,
                task: { NSString(string: "NegativeMeansDefault") },
                completion: { result in
                    #expect((result as? String) == "NegativeMeansDefault")
                    continuation.resume()
                }
            )
        }
    }

    @Test func viewWaitCompletionDefaultsToMainQueue() async {
        let (store, bridge) = makeBridge()
        let pluginId = register(.heavyTask, on: store)
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

    @Test func bridgeWaitPreservesGivenQueue() async {
        let (store, bridge) = makeBridge()
        let pluginId = register(.heavyTask, on: store)
        defer { store.unregisterCapability(for: pluginId) }

        let queue = DispatchQueue(label: "single.view.queue.\(UUID().uuidString)")
        let key = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: key, value: true)

        await withCheckedContinuation { continuation in
            bridge.runTaskWhenAvailable(
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

    @Test func viewCountsTrackStoreFacade() {
        let (store, bridge) = makeBridge()

        #expect(bridge.taskScheduler.pendingCount == store.pendingTaskCount)
        #expect(bridge.taskScheduler.activeCount == store.activeTaskCount)
        #expect(bridge.taskScheduler.pendingCount == 0)
        #expect(bridge.taskScheduler.activeCount == 0)
    }

    @Test func viewScheduleCancelLeavesNoResidue() async {
        let (_, bridge) = makeBridge()
        let uniqueCap = "residueCap_\(UUID().uuidString)"
        let view = bridge.taskScheduler

        let descriptor = ObjcTaskDescriptor(capabilities: [uniqueCap], timeout: 5.0)
        let done = AsyncStream<Void>.makeStream()
        let lease = view.schedule(descriptor, task: {}, completion: { _ in
            done.continuation.yield()
        })

        view.cancel(taskId: descriptor.id)

        for await _ in done.stream { break }
        #expect(lease.underlying.isTerminal)
        #expect(lease.state != .pending || lease.underlying.isTerminal)
        #expect(view.pendingCount == 0)
        #expect(view.activeCount == 0)
    }

    @Test func descriptorDisplayCollapsesToStoredOrPinnedDefault() {
        let pinned = TaskScheduler.Configuration.default.defaultTimeout

        let omitted = ObjcTaskDescriptor(capabilities: ["heavyTask"])
        #expect(omitted.underlying.timeout == pinned)
        #expect(omitted.hasExplicitTimeout)
        #expect(omitted.timeout == pinned)

        let negative = ObjcTaskDescriptor(capabilities: ["heavyTask"], timeout: -1)
        #expect(negative.underlying.timeout == nil)
        #expect(!negative.hasExplicitTimeout)
        #expect(negative.timeout == pinned)

        let explicit = ObjcTaskDescriptor(capabilities: ["heavyTask"], timeout: 60.0)
        #expect(explicit.underlying.timeout == 60.0)
        #expect(explicit.hasExplicitTimeout)
        #expect(explicit.timeout == 60.0)

        let swiftNil = ObjcTaskDescriptor(underlying: TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: nil))
        #expect(!swiftNil.hasExplicitTimeout)
        #expect(swiftNil.timeout == pinned)
    }

    @Test func priorityCoercionExplicitAtView() {
        for rawValue in [99, -1, 5, -100] {
            let descriptor = ObjcTaskDescriptor(capabilities: ["heavyTask"], priority: rawValue)
            #expect(descriptor.underlying.priority == .normal)
            #expect(descriptor.priority == TaskPriority.normal.rawValue)
            #expect(descriptor.priority == descriptor.underlying.priority.rawValue)
        }

        let critical = ObjcTaskDescriptor(capabilities: ["heavyTask"], priority: 4)
        #expect(critical.underlying.priority == .critical)
        #expect(critical.priority == critical.underlying.priority.rawValue)
    }
}
