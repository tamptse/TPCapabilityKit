@preconcurrency import Foundation
import Combine
import Testing
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
        let done = AsyncGate()
        let lease = view.schedule(descriptor, task: {}, completion: { _ in
            done.signal()
        })

        view.cancel(taskId: descriptor.id)

        await done.wait()
        #expect(lease.underlying.isTerminal)
        #expect(lease.state == .expired)
        #expect(view.pendingCount == 0)
        #expect(view.activeCount == 0)
    }
}

struct TPCapabilityKitObjCBridgeTests {

    final class MockObjcPlugin: NSObject, ObjcAppPlugin, @unchecked Sendable {
        let id: String
        var isStarted = false

        init(id: String = "ObjcPluginA") {
            self.id = id
            super.init()
        }

        func start(with store: ObjcStoreBridge) {
            isStarted = true
            store.updateState(pluginId: id, newState: NSString(string: "ObjcInitialState"))
        }
    }

    @Test func objcBridge() {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let pluginId = "ObjcBridge_\(UUID().uuidString)"
        let objcPlugin = MockObjcPlugin(id: pluginId)

        bridge.register(plugin: objcPlugin)
        #expect(objcPlugin.isStarted)

        let fetchedState = bridge.getState(pluginId: pluginId) as? String
        #expect(fetchedState == "ObjcInitialState")

        bridge.updateState(pluginId: pluginId, newState: NSString(string: "ObjcNewState"))
        let updatedState = bridge.getState(pluginId: pluginId) as? String
        #expect(updatedState == "ObjcNewState")
    }

    @Test func objcSubscribeAndCancel() {
        let bridge = ObjcStoreBridge(store: DynamicStore())
        let pluginId = "SubPlugin_\(UUID().uuidString)"
        var receivedState: NSObject?

        let cancellable = bridge.subscribe(pluginId: pluginId, queue: nil) { state in
            receivedState = state
        }

        bridge.updateState(pluginId: pluginId, newState: NSString(string: "SubValue"))

        let deadline = Date().addingTimeInterval(0.2)
        while receivedState == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        #expect(receivedState as? String == "SubValue")
        cancellable.cancel()
    }

    @Test func objcSubscribeOnCustomQueue() {
        let bridge = ObjcStoreBridge(store: DynamicStore())
        let pluginId = "CustomQueuePlugin_\(UUID().uuidString)"
        var receivedState: NSObject?
        let lock = NSLock()
        let semaphore = DispatchSemaphore(value: 0)

        let customQueue = DispatchQueue(label: "test.custom.queue")
        let cancellable = bridge.subscribe(pluginId: pluginId, queue: customQueue) { state in
            lock.lock()
            receivedState = state
            lock.unlock()
            semaphore.signal()
        }

        bridge.updateState(pluginId: pluginId, newState: NSString(string: "CustomQueueValue"))

        _ = semaphore.wait(timeout: .now() + 1.0)

        lock.lock()
        let result = receivedState as? String
        lock.unlock()

        #expect(result == "CustomQueueValue")
        cancellable.cancel()
    }

    @Test func objcSubscribeCancelStopsDelivery() {
        let bridge = ObjcStoreBridge(store: DynamicStore())
        let pluginId = "CancelStopPlugin_\(UUID().uuidString)"
        var receivedValues: [String] = []

        let cancellable = bridge.subscribe(pluginId: pluginId) { state in
            if let str = state as? String {
                receivedValues.append(str)
            }
        }

        bridge.updateState(pluginId: pluginId, newState: NSString(string: "BeforeCancel"))

        let deadline1 = Date().addingTimeInterval(0.2)
        while receivedValues.isEmpty && Date() < deadline1 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        #expect(receivedValues.last == "BeforeCancel")

        cancellable.cancel()

        bridge.updateState(pluginId: pluginId, newState: NSString(string: "AfterCancel"))
        let deadline2 = Date().addingTimeInterval(0.3)
        let _ = deadline2
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        #expect(receivedValues.last == "BeforeCancel")
        #expect(!receivedValues.contains("AfterCancel"))
    }

    @Test func objcRunTaskWhenAvailable() {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let pluginId = "ObjcRunTaskCap_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }

        let result = bridge.runTask(capability: "heavyTask") {
            NSString(string: "TaskResult")
        }
        #expect((result as? String) == "TaskResult")
    }

    @Test func objcRunTaskWhenNotAvailable() {
        let bridge = ObjcStoreBridge(store: DynamicStore())
        let uniqueCap = "missingCap_\(UUID().uuidString)"

        let result = bridge.runTask(capability: uniqueCap) {
            NSString(string: "ShouldNotRun")
        }
        #expect(result == nil)
    }

    @Test func objcQueryCapability() {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let pluginId = "ObjcQueryCap_\(UUID().uuidString)"
        let uniqueCap = "queryCap_\(UUID().uuidString)"

        store.registerCapability(for: pluginId, capabilities: [.custom(uniqueCap)])
        defer { store.unregisterCapability(for: pluginId) }

        #expect(bridge.queryCapability(uniqueCap) == true)
    }

    @Test func objcPluginIsCapabilityConsumerOnly() {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let pluginId = "ObjcConsumer_\(UUID().uuidString)"
        let objcPlugin = MockObjcPlugin(id: pluginId)

        bridge.register(plugin: objcPlugin)
        #expect(objcPlugin.isStarted)

        #expect(store.queryCapabilities(for: pluginId).isEmpty)
        #expect(bridge.queryCapability("heavyTask") == false)
    }

    @Test func objcRunTaskWhenAvailableNegativeTimeoutMeansDefault() async {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let pluginId = "ObjcNegTimeout_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }

        await withCheckedContinuation { continuation in
            bridge.runTaskWhenAvailable(capability: "heavyTask", timeout: -1, queue: nil, task: {
                return NSString(string: "NegativeMeansDefault")
            }, completion: { result in
                #expect((result as? String) == "NegativeMeansDefault")
                continuation.resume()
            })
        }
    }
}

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

struct ObjcStoreBridgeSchedulingTests {
    @Test func objcScheduleWithoutCapability() async {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let uniqueCap = "missingCap_\(UUID().uuidString)"

        let descriptor = ObjcTaskDescriptor(capabilities: [uniqueCap], timeout: 0.1)

        await withCheckedContinuation { continuation in
            bridge.taskScheduler.scheduleAndWait(descriptor, task: {
                NSString(string: "ShouldNotRun")
            }, completion: { result in
                #expect(result == nil)
                continuation.resume()
            })
        }
    }

    @Test func taskSchedulerIsLiveView() {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)

        let scheduler1 = bridge.taskScheduler
        let scheduler2 = bridge.taskScheduler

        #expect(scheduler1.pendingCount == store.pendingTaskCount)
        #expect(scheduler2.pendingCount == store.pendingTaskCount)
        #expect(scheduler1.activeCount == store.activeTaskCount)
        #expect(scheduler2.activeCount == store.activeTaskCount)
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
    }

    @Test func bridgeSchedulingDelegatesToSinglePath() async {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let uniqueCap = "singlePathCap_\(UUID().uuidString)"

        let descriptor = ObjcTaskDescriptor(capabilities: [uniqueCap], timeout: 5.0)
        let done = AsyncGate()
        let lease = bridge.taskScheduler.schedule(descriptor, task: {
        }, completion: { _ in
            done.signal()
        })

        bridge.taskScheduler.cancel(taskId: descriptor.id)

        await done.wait()
        #expect(lease.underlying.isTerminal)
        #expect(bridge.taskScheduler.pendingCount == store.pendingTaskCount)
        #expect(bridge.taskScheduler.activeCount == store.activeTaskCount)
    }

    @Test func cancelByClientIdWorks() async {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let uniqueCap = "clientIdCancelCap_\(UUID().uuidString)"
        let clientId = "client-cancel-\(UUID().uuidString)"

        let descriptor = ObjcTaskDescriptor(clientId: clientId, capabilities: [uniqueCap], timeout: 5.0)
        #expect(descriptor.id == clientId)

        let done = AsyncGate()
        let lease = bridge.taskScheduler.schedule(descriptor, task: {
        }, completion: { _ in
            done.signal()
        })

        bridge.taskScheduler.cancel(taskId: clientId)

        await done.wait()
        #expect(lease.underlying.isTerminal)
        #expect(lease.taskId == clientId)
    }
}

struct ObjcLeaseTests {
    @Test func stateTransitions() {
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask])
        let lease = Lease(task: task)
        let objcLease = ObjcLease(underlying: lease)

        #expect(objcLease.state == .pending)
        #expect(objcLease.underlying.state == .pending)

        lease.activate()
        #expect(lease.state == .active)
        #expect(objcLease.underlying.activatedAt != nil)

        lease.terminalize(.completed("result"))
        #expect(lease.state == .completed)
        #expect(objcLease.underlying.completedAt != nil)
        #expect(objcLease.underlying.result as? String == "result")
    }

    @Test func failureState() {
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask])
        let lease = Lease(task: task)
        let objcLease = ObjcLease(underlying: lease)

        lease.activate()
        struct TestError: Error {}
        lease.terminalize(.failed(TestError()))

        if case .failed = lease.state {
        } else {
            Issue.record("Expected failed state")
        }
        #expect(objcLease.underlying.isTerminal)
    }

    @Test func underlyingProperty() {
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask])
        let lease = Lease(task: task)
        let objcLease = ObjcLease(underlying: lease)

        #expect(objcLease.underlying === lease)
    }

    @Test func liveViewReadsStateWithoutSync() {
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask])
        let lease = Lease(task: task)
        let objcLease = ObjcLease(underlying: lease)

        #expect(objcLease.state == .pending)

        lease.activate()

        #expect(objcLease.state == .active)

        lease.terminalize(.completed("result"))

        #expect(objcLease.state == .completed)
        #expect(objcLease.result as? String == "result")
    }
}

struct BridgeDetachSliceTests {
    final class DetachPlugin: NSObject, ObjcAppPlugin, @unchecked Sendable {
        let id: String
        init(id: String) {
            self.id = id
            super.init()
        }
        func start(with store: ObjcStoreBridge) {
            store.updateState(pluginId: id, newState: NSString(string: "DetachInitial"))
        }
    }

    private final class StateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        private let gate = DispatchSemaphore(value: 0)
        func append(_ value: String) {
            lock.withLock { values.append(value) }
            gate.signal()
        }
        var snapshot: [String] {
            lock.withLock { values }
        }
        func waitForCount(_ count: Int, timeout: TimeInterval = 2.0) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while lock.withLock({ values.count }) < count && Date() < deadline {
                _ = gate.wait(timeout: .now() + 0.05)
            }
            return lock.withLock({ values.count }) >= count
        }
    }

    @Test func bridgeRemoveStateClearsRead() {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let pluginId = "BridgeRemove_\(UUID().uuidString)"

        bridge.register(plugin: DetachPlugin(id: pluginId))
        bridge.updateState(pluginId: pluginId, newState: NSString(string: "V1"))
        #expect((bridge.getState(pluginId: pluginId) as? String) == "V1")

        bridge.removeState(pluginId: pluginId)
        #expect(bridge.getState(pluginId: pluginId) == nil)
    }

    @Test func bridgeRemoveStateDetachesOldSubjectOnly() {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let pluginId = "BridgeRemoveSubject_\(UUID().uuidString)"
        let queueA = DispatchQueue(label: "detach.a.\(UUID().uuidString)")
        let queueB = DispatchQueue(label: "detach.b.\(UUID().uuidString)")

        bridge.register(plugin: DetachPlugin(id: pluginId))

        let oldBox = StateBox()
        let oldToken = bridge.subscribe(pluginId: pluginId, queue: queueA) { state in
            if let str = state as? String { oldBox.append(str) }
        }
        defer { oldToken.cancel() }
        bridge.updateState(pluginId: pluginId, newState: NSString(string: "V1"))
        #expect(oldBox.waitForCount(2))

        bridge.removeState(pluginId: pluginId)

        let newBox = StateBox()
        let newToken = bridge.subscribe(pluginId: pluginId, queue: queueB) { state in
            if let str = state as? String { newBox.append(str) }
        }
        defer { newToken.cancel() }
        bridge.updateState(pluginId: pluginId, newState: NSString(string: "V2"))
        #expect(newBox.waitForCount(1))
        #expect(newBox.snapshot == ["V2"])

        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            queueA.sync {}
            queueB.sync {}
        }
        #expect(!oldBox.snapshot.contains("V2"))
        #expect(oldBox.snapshot == ["DetachInitial", "V1"])
    }

    @Test func bridgeRemoveStateEmptyIdIsNoOp() {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let pluginId = "BridgeRemoveNoop_\(UUID().uuidString)"
        let uniqueCap = "noopCap_\(UUID().uuidString)"

        bridge.register(plugin: DetachPlugin(id: pluginId))
        let beforeRead = bridge.getState(pluginId: pluginId) as? String
        #expect(beforeRead == "DetachInitial")

        var capValues: [Bool] = []
        let capLock = NSLock()
        let capGate = DispatchSemaphore(value: 0)
        let capToken = bridge.subscribeCapability(uniqueCap, queue: DispatchQueue(label: "noop.cap.\(UUID().uuidString)")) { available in
            capLock.withLock { capValues.append(available) }
            capGate.signal()
        }
        defer { capToken.cancel() }
        _ = capGate.wait(timeout: .now() + 2.0)
        #expect(capLock.withLock { capValues } == [false])

        var snapshots: [[String: Set<Capability>]] = []
        let snapLock = NSLock()
        let snapGate = DispatchSemaphore(value: 0)
        var snapCancellables = Set<AnyCancellable>()
        store.observeAllCapabilities()
            .sink { snapshot in
                snapLock.withLock { snapshots.append(snapshot) }
                snapGate.signal()
            }
            .store(in: &snapCancellables)
        defer { snapCancellables.removeAll() }
        _ = snapGate.wait(timeout: .now() + 2.0)
        let snapshotCountBefore = snapLock.withLock { snapshots.count }

        bridge.removeState(pluginId: "")

        #expect((bridge.getState(pluginId: pluginId) as? String) == beforeRead)
        #expect(bridge.queryCapability(uniqueCap) == false)

        store.registerCapability(for: "NoopProbe_\(UUID().uuidString)", capabilities: [.custom(uniqueCap)])
        _ = capGate.wait(timeout: .now() + 2.0)
        _ = snapGate.wait(timeout: .now() + 2.0)
        #expect(capLock.withLock { capValues } == [false, true])
        snapLock.withLock {
            #expect(snapshots.count == snapshotCountBefore + 1)
        }
    }
}
struct BridgeUnregisterSliceTests {
    final class UnregPlugin: NSObject, ObjcAppPlugin, @unchecked Sendable {
        let id: String
        init(id: String) {
            self.id = id
            super.init()
        }
        func start(with store: ObjcStoreBridge) {
            store.updateState(pluginId: id, newState: NSString(string: "UnregInitial"))
        }
    }

    private final class StateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        private let gate = DispatchSemaphore(value: 0)
        func append(_ value: String) {
            lock.withLock { values.append(value) }
            gate.signal()
        }
        var snapshot: [String] {
            lock.withLock { values }
        }
        func waitForCount(_ count: Int, timeout: TimeInterval = 2.0) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while lock.withLock({ values.count }) < count && Date() < deadline {
                _ = gate.wait(timeout: .now() + 0.05)
            }
            return lock.withLock({ values.count }) >= count
        }
    }

    @Test func bridgeUnregisterDetachesFullyById() {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let pluginId = "BridgeUnreg_\(UUID().uuidString)"
        let probeCap = "unregProbe_\(UUID().uuidString)"
        let queueA = DispatchQueue(label: "unreg.a.\(UUID().uuidString)")
        let queueB = DispatchQueue(label: "unreg.b.\(UUID().uuidString)")

        bridge.register(plugin: UnregPlugin(id: pluginId))
        #expect(store.queryCapabilities(for: pluginId).isEmpty)
        #expect(bridge.queryCapability(probeCap) == false)

        let rowCap = Capability.custom("rowDetachProbe_\(UUID().uuidString)")
        store.registerCapability(for: pluginId, capabilities: [rowCap])
        #expect(store.queryCapabilities(for: pluginId) == [rowCap])
        #expect(bridge.queryCapability(rowCap.rawValue) == true)

        let oldBox = StateBox()
        let oldToken = bridge.subscribe(pluginId: pluginId, queue: queueA) { state in
            if let str = state as? String { oldBox.append(str) }
        }
        defer { oldToken.cancel() }
        bridge.updateState(pluginId: pluginId, newState: NSString(string: "V1"))
        #expect(oldBox.waitForCount(2))

        bridge.unregister(pluginId: pluginId)

        #expect(bridge.getState(pluginId: pluginId) == nil)
        #expect(store.queryCapabilities(for: pluginId).isEmpty)
        #expect(bridge.queryCapability(rowCap.rawValue) == false)
        #expect(bridge.queryCapability(probeCap) == false)

        let newBox = StateBox()
        let newToken = bridge.subscribe(pluginId: pluginId, queue: queueB) { state in
            if let str = state as? String { newBox.append(str) }
        }
        defer { newToken.cancel() }
        bridge.updateState(pluginId: pluginId, newState: NSString(string: "V2"))
        #expect(newBox.waitForCount(1))
        #expect(newBox.snapshot == ["V2"])

        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            queueA.sync {}
            queueB.sync {}
        }
        #expect(!oldBox.snapshot.contains("V2"))
        #expect(oldBox.snapshot == ["UnregInitial", "V1"])

        bridge.register(plugin: UnregPlugin(id: pluginId))
        #expect((bridge.getState(pluginId: pluginId) as? String) == "UnregInitial")
    }

    @Test func bridgeUnregisterEmptyIdIsNoOp() {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let pluginId = "BridgeUnregNoop_\(UUID().uuidString)"
        let uniqueCap = "unregNoopCap_\(UUID().uuidString)"

        bridge.register(plugin: UnregPlugin(id: pluginId))
        let beforeRead = bridge.getState(pluginId: pluginId) as? String
        #expect(beforeRead == "UnregInitial")

        var capValues: [Bool] = []
        let capLock = NSLock()
        let capGate = DispatchSemaphore(value: 0)
        let capToken = bridge.subscribeCapability(uniqueCap, queue: DispatchQueue(label: "unreg.noop.cap.\(UUID().uuidString)")) { available in
            capLock.withLock { capValues.append(available) }
            capGate.signal()
        }
        defer { capToken.cancel() }
        _ = capGate.wait(timeout: .now() + 2.0)
        #expect(capLock.withLock { capValues } == [false])

        var snapshots: [[String: Set<Capability>]] = []
        let snapLock = NSLock()
        let snapGate = DispatchSemaphore(value: 0)
        var snapCancellables = Set<AnyCancellable>()
        store.observeAllCapabilities()
            .sink { snapshot in
                snapLock.withLock { snapshots.append(snapshot) }
                snapGate.signal()
            }
            .store(in: &snapCancellables)
        defer { snapCancellables.removeAll() }
        _ = snapGate.wait(timeout: .now() + 2.0)
        let snapshotCountBefore = snapLock.withLock { snapshots.count }
        let beforeQuery = bridge.queryCapability(uniqueCap)

        bridge.unregister(pluginId: "")

        #expect((bridge.getState(pluginId: pluginId) as? String) == beforeRead)
        #expect(bridge.queryCapability(uniqueCap) == beforeQuery)
        #expect(store.queryCapabilities(for: pluginId).isEmpty)

        store.registerCapability(for: "UnregNoopProbe_\(UUID().uuidString)", capabilities: [.custom(uniqueCap)])
        _ = capGate.wait(timeout: .now() + 2.0)
        _ = snapGate.wait(timeout: .now() + 2.0)
        #expect(capLock.withLock { capValues } == [false, true])
        snapLock.withLock {
            #expect(snapshots.count == snapshotCountBefore + 1)
        }
    }
}
struct ObjcFastPathAgreementTests {
    @Test func bridgeRunTaskAgreesWithSchedulerFastPath() {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let pluginId = "ObjcFastPathDeleg_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }

        let viaScheduler = bridge.taskScheduler.runIfAvailable(capability: "heavyTask") {
            NSString(string: "Delegated")
        }
        let viaBridge = bridge.runTask(capability: "heavyTask") {
            NSString(string: "Delegated")
        }
        #expect((viaScheduler as? String) == "Delegated")
        #expect((viaBridge as? String) == "Delegated")

        let missingCap = "fastPathDelegMissing_\(UUID().uuidString)"
        #expect(bridge.taskScheduler.runIfAvailable(capability: missingCap) {
            NSString(string: "ShouldNotRun")
        } == nil)
        #expect(bridge.runTask(capability: missingCap) {
            NSString(string: "ShouldNotRun")
        } == nil)
    }
}
