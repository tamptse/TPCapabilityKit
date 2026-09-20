@preconcurrency import Foundation
import Combine
import Testing
@testable import TPCapabilityKit
@testable import TPCapabilityKitSample

struct TPCapabilityKitCoreTests {
    
    struct TestPlugin: AppPlugin {
        let id: String
        func start(with store: DynamicStore) {
            store.updateState(pluginId: id, newState: "InitialPluginState")
        }
    }

    @Test func swiftCoreRegisterAndUpdateState() {
        let store = DynamicStore()
        let plugin = TestPlugin(id: "PluginA")
        
        store.register(plugin: plugin)
        
        let state = store.getState(pluginId: "PluginA", type: String.self)
        #expect(state == "InitialPluginState")
        
        store.updateState(pluginId: "PluginA", newState: "UpdatedState")
        let updated = store.getState(pluginId: "PluginA", type: String.self)
        #expect(updated == "UpdatedState")
    }
    
    @Test func orderAgnosticSubscription() {
        let store = DynamicStore()
        var receivedValue: String?
        var cancellables = Set<AnyCancellable>()
        
        store.observeState(pluginId: "LatePlugin", type: String.self)
            .sink { value in
                receivedValue = value
            }
            .store(in: &cancellables)
            
        store.updateState(pluginId: "LatePlugin", newState: "LateValue")
        #expect(receivedValue == "LateValue")
    }
    
    @Test func typeCastingSafety() {
        let store = DynamicStore()
        store.updateState(pluginId: "TypePlugin", newState: "StringValue")
        
        let wrongState = store.getState(pluginId: "TypePlugin", type: Int.self)
        #expect(wrongState == nil)
        
        let correctState = store.getState(pluginId: "TypePlugin", type: String.self)
        #expect(correctState == "StringValue")
    }

    @Test func emptyPluginIdHandling() {
        let store = DynamicStore()
        
        // registerCapability with empty pluginId should not crash
        store.registerCapability(for: "", capabilities: [.heavyTask])
        
        // unregisterCapability with empty pluginId should not crash
        store.unregisterCapability(for: "")
        
        // removeState with empty pluginId should not crash
        store.removeState(for: "")
        
        // queryCapabilities with empty pluginId should return empty
        let caps = store.queryCapabilities(for: "")
        #expect(caps.isEmpty)
    }

    @Test func getStateNonExistentPlugin() {
        let store = DynamicStore()
        let nonExistentId = "NonExistentPlugin_\(UUID().uuidString)"
        
        // getState for non-existent plugin should return nil
        let state = store.getState(pluginId: nonExistentId, type: String.self)
        #expect(state == nil)
    }

    @Test func removeStateStopsFutureObservations() {
        let store = DynamicStore()
        let pluginId = "RemoveNotify_\(UUID().uuidString)"
        var receivedValues: [String] = []
        var cancellables = Set<AnyCancellable>()

        store.observeState(pluginId: pluginId, type: String.self)
            .sink { value in
                receivedValues.append(value)
            }
            .store(in: &cancellables)

        store.updateState(pluginId: pluginId, newState: "BeforeRemove")
        #expect(receivedValues.last == "BeforeRemove")

        // removeState sends nil, but observeState uses compactMap which filters nil
        // So subscribers stop receiving updates, and the subject is removed
        store.removeState(for: pluginId)

        // After removeState, the subject is removed from stateSubjects
        // A new update will create a fresh subject (no nil delivered through compactMap)
        store.updateState(pluginId: pluginId, newState: "AfterRemove")
        #expect(receivedValues.last == "BeforeRemove")

        // But the new subject is accessible via getState
        let state = store.getState(pluginId: pluginId, type: String.self)
        #expect(state == "AfterRemove")

        cancellables.removeAll()
    }

    @Test func concurrentStateReadWrite() async {
        let store = DynamicStore()
        let taskCount = 10
        let operationsPerTask = 5_000

        await withTaskGroup(of: Void.self) { group in
            for taskId in 0..<taskCount {
                group.addTask {
                    let pluginId = "ConcurrentStatePlugin_\(taskId)"
                    for i in 0..<operationsPerTask {
                        store.updateState(pluginId: pluginId, newState: i)
                        _ = store.getState(pluginId: pluginId, type: Int.self)
                    }
                }
            }
        }
        // Verify at least one plugin has a valid state
        for taskId in 0..<taskCount {
            let pluginId = "ConcurrentStatePlugin_\(taskId)"
            let state = store.getState(pluginId: pluginId, type: Int.self)
            #expect(state != nil)
        }
    }

    @Test func unregisterPlugin() {
        let store = DynamicStore()
        let pluginId = "UnregisterPlugin_\(UUID().uuidString)"
        let plugin = TestPlugin(id: pluginId)
        
        store.register(plugin: plugin)
        store.updateState(pluginId: pluginId, newState: "TestState")
        #expect(store.getState(pluginId: pluginId, type: String.self) == "TestState")
        
        store.unregister(plugin: plugin)
        #expect(store.getState(pluginId: pluginId, type: String.self) == nil)
        #expect(store.queryCapabilities(for: pluginId).isEmpty)
    }

    @Test func removeStateStopsFutureUpdates() {
        let store = DynamicStore()
        let pluginId = "StopFuture_\(UUID().uuidString)"
        var receivedValues: [String] = []
        var cancellables = Set<AnyCancellable>()

        store.observeState(pluginId: pluginId, type: String.self)
            .sink { value in
                receivedValues.append(value)
            }
            .store(in: &cancellables)

        store.updateState(pluginId: pluginId, newState: "First")
        #expect(receivedValues.last == "First")

        store.removeState(for: pluginId)

        // After removeState, the subject is removed.
        // A new update creates a fresh subject — old subscriber doesn't see it.
        store.updateState(pluginId: pluginId, newState: "Second")
        #expect(receivedValues.last == "First")
        #expect(receivedValues.count == 1)

        // New subscriber sees the new value
        var newReceived: [String] = []
        var newCancellables = Set<AnyCancellable>()
        store.observeState(pluginId: pluginId, type: String.self)
            .sink { value in
                newReceived.append(value)
            }
            .store(in: &newCancellables)
        #expect(newReceived.last == "Second")

        cancellables.removeAll()
        newCancellables.removeAll()
    }

    @Test func sampleUsageRunsCleanly() {
        TPCapabilityKitSample.runExample()
    }
}
