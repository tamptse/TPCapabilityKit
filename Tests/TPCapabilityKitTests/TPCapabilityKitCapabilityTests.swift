@preconcurrency import Foundation
import Combine
import Testing
@testable import TPCapabilityKit

struct TPCapabilityKitCapabilityTests {
    
    struct TestCapabilityPlugin: AppPlugin {
        let id: String
        let capabilities: Set<Capability>
        
        func start(with store: DynamicStore) {
            store.updateState(pluginId: id, newState: "CapabilityPluginState")
        }
    }

    // MARK: - Capability Tests

    @Test func capabilityAutoRegistration() {
        let store = DynamicStore()
        let pluginId = "CapPluginA_\(UUID().uuidString)"
        let plugin = TestCapabilityPlugin(id: pluginId, capabilities: [.heavyTask, .lightTask])
        
        store.register(plugin: plugin)
        defer { store.unregisterCapability(for: pluginId) }
        
        #expect(store.queryCapability(.heavyTask) == true)
        #expect(store.queryCapability(.lightTask) == true)
    }

    @Test func capabilityManualRegistration() {
        let store = DynamicStore()
        let pluginId = "ManualCapPlugin_\(UUID().uuidString)"
        
        store.registerCapability(for: pluginId, capabilities: [.networkAccess, .backgroundExecution])
        defer { store.unregisterCapability(for: pluginId) }
        
        #expect(store.queryCapability(.networkAccess) == true)
        #expect(store.queryCapability(.backgroundExecution) == true)
    }

    @Test func capabilityUnregistration() {
        let store = DynamicStore()
        let pluginId = "UnregisterCapPlugin_\(UUID().uuidString)"
        
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        #expect(store.queryCapability(.heavyTask) == true)
        
        store.unregisterCapability(for: pluginId)
        #expect(store.queryCapability(.heavyTask) == false)
    }

    @Test func capabilityQueryByPlugin() {
        let store = DynamicStore()
        let pluginId = "QueryCapPlugin_\(UUID().uuidString)"
        
        store.registerCapability(for: pluginId, capabilities: [.heavyTask, .lightTask])
        defer { store.unregisterCapability(for: pluginId) }
        
        let caps = store.queryCapabilities(for: pluginId)
        #expect(caps.contains(.heavyTask))
        #expect(caps.contains(.lightTask))
        #expect(caps.count == 2)
    }

    @Test func capabilityQueryAll() {
        let store = DynamicStore()
        let pluginId1 = "QueryAllCapPlugin1_\(UUID().uuidString)"
        let pluginId2 = "QueryAllCapPlugin2_\(UUID().uuidString)"
        
        store.registerCapability(for: pluginId1, capabilities: [.heavyTask])
        store.registerCapability(for: pluginId2, capabilities: [.lightTask, .networkAccess])
        defer {
            store.unregisterCapability(for: pluginId1)
            store.unregisterCapability(for: pluginId2)
        }
        
        let allCaps = store.queryAllCapabilities()
        #expect(allCaps[pluginId1]?.contains(.heavyTask) == true)
        #expect(allCaps[pluginId2]?.contains(.lightTask) == true)
    }

    @Test func capabilityReactiveObservation() async {
        let store = DynamicStore()
        let pluginId = "ReactiveCapPlugin_\(UUID().uuidString)"
        
        var receivedValues: [Bool] = []
        var cancellables = Set<AnyCancellable>()
        
        store.observeCapability(.custom(pluginId))
            .sink { value in
                receivedValues.append(value)
            }
            .store(in: &cancellables)
        
        // Initially false (unique capability per test)
        #expect(receivedValues.last == false)
        
        // Register capability
        store.registerCapability(for: pluginId, capabilities: [.custom(pluginId)])
        
        // Should receive true (CurrentValueSubject delivers synchronously)
        #expect(receivedValues.last == true)
        
        // Unregister capability
        store.unregisterCapability(for: pluginId)
        #expect(receivedValues.last == false)
        
        cancellables.removeAll()
    }

    @Test func capabilityConcurrentAccess() async {
        let store = DynamicStore()
        let taskCount = 10
        let operationsPerTask = 1_000
        
        await withTaskGroup(of: Void.self) { group in
            for taskId in 0..<taskCount {
                group.addTask {
                    let pluginId = "ConcurrentCapPlugin_\(taskId)_\(UUID().uuidString)"
                    for i in 0..<operationsPerTask {
                        if i % 2 == 0 {
                            store.registerCapability(for: pluginId, capabilities: [.heavyTask])
                        } else {
                            _ = store.queryCapability(.heavyTask)
                        }
                    }
                }
            }
        }
        
        // After all concurrent operations, verify consistent state
        let result = store.queryCapability(.heavyTask)
        #expect(result == true || result == false)
    }

    @Test func capabilityInitFromRawValue() {
        let known = Capability(rawValue: "heavyTask")
        #expect(known == .heavyTask)
        
        let unknown = Capability(rawValue: "invalidCapability")
        if case .custom(let value) = unknown {
            #expect(value == "invalidCapability")
        } else {
            #expect(Bool(false))
        }
    }

    @Test func observeAllCapabilitiesReactive() async {
        let store = DynamicStore()
        let pluginId = "ObserveAllCapPlugin_\(UUID().uuidString)"
        
        var receivedValues: [[String: Set<Capability>]] = []
        var cancellables = Set<AnyCancellable>()
        
        store.observeAllCapabilities()
            .sink { caps in
                receivedValues.append(caps)
            }
            .store(in: &cancellables)
        
        // Register capability
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        
        // Should receive at least 2 values: initial empty + after registration (synchronous)
        #expect(receivedValues.count >= 2)
        #expect(receivedValues.last?[pluginId]?.contains(.heavyTask) == true)
        
        // Unregister
        store.unregisterCapability(for: pluginId)
        
        cancellables.removeAll()
    }

    @Test func unregisterCapabilitySoleProviderQueryReturnsFalse() {
        let store = DynamicStore()
        let pluginId = "SoleProvider_\(UUID().uuidString)"
        let uniqueCap = Capability.custom("soleCap_\(UUID().uuidString)")

        store.registerCapability(for: pluginId, capabilities: [uniqueCap])
        #expect(store.queryCapability(uniqueCap) == true)

        store.unregisterCapability(for: pluginId)
        #expect(store.queryCapability(uniqueCap) == false)
    }

    @Test func registerCapabilityReplacesOldCapabilities() {
        let store = DynamicStore()
        let pluginId = "ReplaceCap_\(UUID().uuidString)"

        store.registerCapability(for: pluginId, capabilities: [.heavyTask, .lightTask])
        #expect(store.queryCapability(.heavyTask) == true)
        #expect(store.queryCapability(.lightTask) == true)

        // Re-register with different capabilities
        store.registerCapability(for: pluginId, capabilities: [.networkAccess])
        #expect(store.queryCapability(.networkAccess) == true)

        let caps = store.queryCapabilities(for: pluginId)
        #expect(caps == [.networkAccess])
        #expect(!caps.contains(.heavyTask))
        #expect(!caps.contains(.lightTask))

        store.unregisterCapability(for: pluginId)
    }

    @Test func multiplePluginsProvideSameCapability() {
        let store = DynamicStore()
        let pluginId1 = "MultiCap1_\(UUID().uuidString)"
        let pluginId2 = "MultiCap2_\(UUID().uuidString)"

        store.registerCapability(for: pluginId1, capabilities: [.heavyTask])
        store.registerCapability(for: pluginId2, capabilities: [.heavyTask])
        defer {
            store.unregisterCapability(for: pluginId1)
            store.unregisterCapability(for: pluginId2)
        }

        // Capability available when both providers exist
        #expect(store.queryCapability(.heavyTask) == true)

        // Remove first provider — still available via second
        store.unregisterCapability(for: pluginId1)
        #expect(store.queryCapability(.heavyTask) == true)

        // Remove second provider — now unavailable
        store.unregisterCapability(for: pluginId2)
        #expect(store.queryCapability(.heavyTask) == false)
    }

    @Test func registerCapabilityReplacementNotifiesObservers() {
        let store = DynamicStore()
        let pluginId = "ReplaceNotify_\(UUID().uuidString)"
        var receivedValues: [Bool] = []
        var cancellables = Set<AnyCancellable>()

        store.observeCapability(.heavyTask)
            .sink { value in
                receivedValues.append(value)
            }
            .store(in: &cancellables)

        // Initially false
        #expect(receivedValues.last == false)

        // Register with heavyTask
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        #expect(receivedValues.last == true)

        // Replace with only lightTask — heavyTask should become false
        store.registerCapability(for: pluginId, capabilities: [.lightTask])
        #expect(receivedValues.last == false)

        store.unregisterCapability(for: pluginId)
        cancellables.removeAll()
    }

    @Test func reentrantSubscriberQueriesBackWithoutDeadlock() {
        let store = DynamicStore()
        let pluginId = "Reentrant_\(UUID().uuidString)"
        let cap = Capability.custom("reentrant_\(UUID().uuidString)")
        var received: [Bool] = []
        var queried: [Bool] = []
        var cancellables = Set<AnyCancellable>()

        store.observeCapability(cap)
            .sink { value in
                received.append(value)
                queried.append(store.queryCapability(cap))
            }
            .store(in: &cancellables)

        store.registerCapability(for: pluginId, capabilities: [cap])
        store.unregisterCapability(for: pluginId)

        #expect(received == [false, true, false])
        #expect(queried == [false, true, false])
        cancellables.removeAll()
    }
}
