@preconcurrency import Foundation
import Combine
import Testing
@testable import TPCapabilityKit
@testable import TPCapabilityKitBridge

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

    // MARK: - ObjC Bridge Tests

    @Test func objcBridge() {
        let bridge = ObjcStoreBridge.shared
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
        let bridge = ObjcStoreBridge.shared
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
        let bridge = ObjcStoreBridge.shared
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
        let bridge = ObjcStoreBridge.shared
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
        let _ = deadline2 // keep RunLoop spinning briefly
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        // After cancel, no new values should be delivered
        #expect(receivedValues.last == "BeforeCancel")
        #expect(!receivedValues.contains("AfterCancel"))
    }

    // MARK: - ObjC Bridge Task Execution Tests

    @Test func objcRunTaskWhenAvailable() {
        let bridge = ObjcStoreBridge.shared
        let store = DynamicStore.shared
        let pluginId = "ObjcRunTaskCap_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }

        let result = bridge.runTask(capability: "heavyTask") {
            NSString(string: "TaskResult")
        }
        #expect((result as? String) == "TaskResult")
    }

    @Test func objcRunTaskWhenNotAvailable() {
        let bridge = ObjcStoreBridge.shared
        let uniqueCap = "missingCap_\(UUID().uuidString)"

        let result = bridge.runTask(capability: uniqueCap) {
            NSString(string: "ShouldNotRun")
        }
        #expect(result == nil)
    }

    @Test func objcRunTaskWhenAvailableAlreadyAvailable() async {
        let bridge = ObjcStoreBridge.shared
        let store = DynamicStore.shared
        let pluginId = "ObjcWaitCap_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.networkAccess])
        defer { store.unregisterCapability(for: pluginId) }

        await withCheckedContinuation { continuation in
            bridge.runTaskWhenAvailable(capability: "networkAccess", timeout: 1.0, queue: nil, task: {
                return NSString(string: "ImmediateObjC")
            }, completion: { result in
                #expect((result as? String) == "ImmediateObjC")
                continuation.resume()
            })
        }
    }

    @Test func objcRunTaskWhenAvailableTimesOut() async {
        let bridge = ObjcStoreBridge.shared
        let uniqueCap = "timeoutCapObjc_\(UUID().uuidString)"

        await withCheckedContinuation { continuation in
            bridge.runTaskWhenAvailable(capability: uniqueCap, timeout: 0.1, queue: nil, task: {
                NSString(string: "ShouldNotRun")
            }, completion: { result in
                #expect(result == nil)
                continuation.resume()
            })
        }
    }

    @Test func objcQueryCapability() {
        let bridge = ObjcStoreBridge.shared
        let store = DynamicStore.shared
        let pluginId = "ObjcQueryCap_\(UUID().uuidString)"
        let uniqueCap = "queryCap_\(UUID().uuidString)"

        store.registerCapability(for: pluginId, capabilities: [.custom(uniqueCap)])
        defer { store.unregisterCapability(for: pluginId) }

        #expect(bridge.queryCapability(uniqueCap) == true)
    }
}
