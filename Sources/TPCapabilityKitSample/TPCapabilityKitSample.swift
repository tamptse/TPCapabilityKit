import Combine
import Foundation
import TPCapabilityKit
import TPCapabilityKitBridge

// MARK: - 1. Sample Models (State Value Types for Swift & ObjC)

/// Pure Swift State produced by the User Profile Plugin.
struct UserProfileState: Sendable, Equatable {
    let userId: String
    let userName: String
    let isVIP: Bool

    init(userId: String, userName: String, isVIP: Bool) {
        self.userId = userId
        self.userName = userName
        self.isVIP = isVIP
    }
}

/// Objective-C compatible State produced by legacy ObjC Plugins.
@objc(TPUserProfileState)
final class ObjcUserProfileState: NSObject, @unchecked Sendable {
    @objc let userId: String
    @objc let userName: String
    @objc let isVIP: Bool

    @objc init(userId: String, userName: String, isVIP: Bool) {
        self.userId = userId
        self.userName = userName
        self.isVIP = isVIP
        super.init()
    }
}

// MARK: - 2. Swift Plugins (Micro-Frontends)

/// Micro-frontend plugin managing user authentication and profile.
final class UserProfilePlugin: AppPlugin {
    let id: String = "UserProfilePlugin"
    private var store: DynamicStore?

    init() {}

    func start(with store: DynamicStore) {
        self.store = store
        
        // Push initial user profile state to store
        let initialState = UserProfileState(userId: "u123", userName: "Nguyen Van A", isVIP: true)
        store.updateState(pluginId: id, newState: initialState)
    }

    /// Updates user status (e.g. when user changes name or VIP status)
    func updateUserProfile(name: String, isVIP: Bool) {
        let updatedState = UserProfileState(userId: "u123", userName: name, isVIP: isVIP)
        store?.updateState(pluginId: id, newState: updatedState)
    }
}

/// Micro-frontend plugin managing active chat conversations.
final class ChatPlugin: AppPlugin {
    let id: String = "ChatPlugin"
    private var cancellables = Set<AnyCancellable>()

    init() {}

    func start(with store: DynamicStore) {
        // Decoupled communication: Observe UserProfileState without importing UserProfilePlugin!
        store.observeState(pluginId: "UserProfilePlugin", type: UserProfileState.self)
            .sink { userProfile in
                print("[ChatPlugin] Observed user profile update: \(userProfile.userName), VIP: \(userProfile.isVIP)")
            }
            .store(in: &cancellables)
    }
}

/// Micro-frontend plugin providing background task capabilities.
final class BackgroundTaskPlugin: CapabilityProvider {
    let id: String = "BackgroundTaskPlugin"
    let capabilities: Set<Capability> = [.heavyTask, .lightTask, .backgroundExecution]
    private var store: DynamicStore?

    init() {}

    func start(with store: DynamicStore) {
        self.store = store
        store.updateState(pluginId: id, newState: "BackgroundTaskPluginReady")
    }
}

/// Micro-frontend plugin providing network capabilities.
final class NetworkPlugin: CapabilityProvider {
    let id: String = "NetworkPlugin"
    let capabilities: Set<Capability> = [.networkAccess, .lightTask]
    private var store: DynamicStore?

    init() {}

    func start(with store: DynamicStore) {
        self.store = store
        store.updateState(pluginId: id, newState: "NetworkPluginReady")
    }
}

// MARK: - 3. Objective-C Plugin Integration Sample

/// Legacy Objective-C plugin interacting with the store via ObjcStoreBridge.
@objc(TPSampleObjcPlugin)
final class SampleObjcPlugin: NSObject, ObjcAppPlugin, @unchecked Sendable {
    @objc let id: String = "SampleObjcPlugin"
    private var subscriptionToken: ObjcCancellable?

    @objc func start(with store: ObjcStoreBridge) {
        // Push initial legacy ObjC state
        let initialState = ObjcUserProfileState(userId: "objc_101", userName: "ObjC User", isVIP: false)
        store.updateState(pluginId: id, newState: initialState)

        // Subscribe to state updates via ObjcStoreBridge
        subscriptionToken = store.subscribe(pluginId: id) { state in
            if let profile = state as? ObjcUserProfileState {
                print("[SampleObjcPlugin] Received profile update in ObjC: \(profile.userName)")
            }
        }
    }

    deinit {
        subscriptionToken?.cancel()
    }
}

// MARK: - 4. Demonstrative Usage Example

enum TPCapabilityKitSample {
    
    /// Demonstrates registering plugins, publishing state, and decoupled cross-plugin observation.
    static func runExample() {
        print("=== TPCapabilityKit Sample Usage Start ===")
        
        let store = DynamicStore.shared
        let bridge = ObjcStoreBridge.shared

        // Create plugins
        let profilePlugin = UserProfilePlugin()
        let chatPlugin = ChatPlugin()
        let objcPlugin = SampleObjcPlugin()
        let backgroundPlugin = BackgroundTaskPlugin()
        let networkPlugin = NetworkPlugin()

        // 1. Order-Agnostic: ChatPlugin starts and observes UserProfilePlugin BEFORE UserProfilePlugin starts
        store.register(plugin: chatPlugin)
        
        // 2. Register UserProfilePlugin
        store.register(plugin: profilePlugin)

        // 3. Register ObjC plugin via bridge
        bridge.register(plugin: objcPlugin)

        // 4. Register capability plugins - capabilities auto-registered
        store.register(plugin: backgroundPlugin)
        store.register(plugin: networkPlugin)

        // 5. Synchronous Read
        if let currentProfile = store.getState(pluginId: "UserProfilePlugin", type: UserProfileState.self) {
            print("[Synchronous Read] User Profile: \(currentProfile.userName)")
        }

        // 6. Update state on profile plugin -> triggers observers reactively
        profilePlugin.updateUserProfile(name: "Tran Van B", isVIP: false)

        // 7. Query capabilities
        let canRunHeavy = store.queryCapability(.heavyTask)
        let canRunLight = store.queryCapability(.lightTask)
        let canAccessNetwork = store.queryCapability(.networkAccess)
        print("[Capability Query] Heavy: \(canRunHeavy), Light: \(canRunLight), Network: \(canAccessNetwork)")

        // 8. Reactive capability observation
        var cancellables = Set<AnyCancellable>()
        store.observeCapability(.heavyTask)
            .sink { available in
                print("[Capability Observation] heavyTask available: \(available)")
            }
            .store(in: &cancellables)

        // 9. Unregister a capability plugin
        store.unregister(plugin: backgroundPlugin)

        // 10. Remove state and observe nil notification
        // Note: observeState uses compactMap which filters nil values,
        // so subscribers do NOT receive nil. Instead, removeState removes
        // the subject, stopping future emissions for that plugin.
        var receivedAfterRemove: String?
        store.observeState(pluginId: "TempPlugin", type: String.self)
            .sink { value in
                receivedAfterRemove = value
            }
            .store(in: &cancellables)
        store.updateState(pluginId: "TempPlugin", newState: "TempValue")
        print("[removeState] Current value after update: \(String(describing: receivedAfterRemove))")
        store.removeState(for: "TempPlugin")
        print("[removeState] Subject removed, future updates create fresh subject")

        // 13. ObjC subscription lifecycle
        var objcReceivedAfterCancel = false
        let objcCancellable = bridge.subscribe(pluginId: "SampleObjcPlugin") { state in
            if let profile = state as? ObjcUserProfileState, profile.userName == "AfterCancel" {
                objcReceivedAfterCancel = true
            }
        }
        bridge.updateState(pluginId: "SampleObjcPlugin", newState: NSString(string: "BeforeCancel"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        objcCancellable.cancel()
        bridge.updateState(pluginId: "SampleObjcPlugin", newState: NSString(string: "AfterCancel"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        print("[ObjC Cancel] Updates after cancel: \(objcReceivedAfterCancel)")

        // 14. runTask - fire-and-forget if capability available
        Task {
            let heavyResult = await store.runTask(requiring: .heavyTask) {
                return "HeavyTaskResult"
            }
            if let result = heavyResult {
                print("[runTask] heavyTask executed, result: \(result)")
            } else {
                print("[runTask] heavyTask not available, skipped")
            }

            // runTask on missing capability
            let gpuResult = await store.runTask(requiring: .custom("GPURender")) {
                return "GPURenderResult"
            }
            if let _ = gpuResult {
                print("[runTask] GPURender executed")
            } else {
                print("[runTask] GPURender not available, skipped")
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        // 15. runTaskWhenAvailable - wait for capability then execute
        Task {
            let result = await store.runTaskWhenAvailable(capability: .networkAccess, timeout: 2.0) {
                print("[runTaskWhenAvailable] networkAccess became available, fetching data...")
                return "NetworkData"
            }
            print("[runTaskWhenAvailable] result: \(String(describing: result))")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        // 16. ObjC Bridge - runTask
        if let objcResult = bridge.runTask(capability: "heavyTask", task: {
            return NSString(string: "ObjCHeavyResult")
        }) {
            print("[ObjC runTask] result: \(objcResult)")
        } else {
            print("[ObjC runTask] heavyTask not available")
        }

        // 17. ObjC Bridge - queryCapability
        let canHeavy = bridge.queryCapability("heavyTask")
        let canNetwork = bridge.queryCapability("networkAccess")
        print("[ObjC queryCapability] heavy: \(canHeavy), network: \(canNetwork)")

        // 18. ObjC Bridge - runTaskWhenAvailable with completion handler
        bridge.runTaskWhenAvailable(capability: "networkAccess", timeout: 2.0, task: {
            return NSString(string: "ObjCNetworkData")
        }, completion: { result in
            print("[ObjC runTaskWhenAvailable] result: \(String(describing: result))")
        })
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        // Cleanup
        store.unregister(plugin: profilePlugin)
        store.unregister(plugin: chatPlugin)
        store.unregister(plugin: networkPlugin)
        cancellables.removeAll()

        print("=== TPCapabilityKit Sample Usage End ===")
    }
}
