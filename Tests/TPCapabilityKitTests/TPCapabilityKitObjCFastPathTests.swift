import Testing
import Foundation
@testable import TPCapabilityKit
@testable import TPCapabilityKitBridge

struct ObjcFastPathAgreementTests {
    @Test func runIfAvailableAndWaitAgreeWhenAvailable() async {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let pluginId = "ObjcFastPathAvail_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }

        let syncResult = bridge.taskScheduler.runIfAvailable(capability: "heavyTask") {
            NSString(string: "SyncFast")
        }
        #expect((syncResult as? String) == "SyncFast")

        await withCheckedContinuation { continuation in
            bridge.taskScheduler.runWhenAvailable(
                capability: "heavyTask",
                timeout: 1.0,
                queue: nil,
                task: { NSString(string: "WaitRun") },
                completion: { result in
                    #expect((result as? String) == "WaitRun")
                    continuation.resume()
                }
            )
        }
    }

    @Test func runIfAvailableNilExactlyWhenWaitTimesOut() async {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let uniqueCap = "fastPathMissing_\(UUID().uuidString)"
        var syncTaskRan = false

        let syncResult = bridge.taskScheduler.runIfAvailable(capability: uniqueCap) {
            syncTaskRan = true
            return NSString(string: "ShouldNotRun")
        }
        #expect(syncResult == nil)
        #expect(!syncTaskRan)

        await withCheckedContinuation { continuation in
            bridge.taskScheduler.runWhenAvailable(
                capability: uniqueCap,
                timeout: 0.1,
                queue: nil,
                task: { NSString(string: "ShouldNotRun") },
                completion: { result in
                    #expect(result == nil)
                    continuation.resume()
                }
            )
        }
    }

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

    @Test func timeoutCompatPinnedThroughDescriptor() {
        let omitted = ObjcTaskDescriptor(capabilities: ["heavyTask"])
        #expect(omitted.underlying.timeout == ObjcMapper.omittedTimeout)
        #expect(omitted.underlying.timeout == ObjcMapper.resolveTimeout(wire: nil))

        let negative = ObjcTaskDescriptor(capabilities: ["heavyTask"], timeout: -1)
        #expect(negative.underlying.timeout == nil)
        #expect(negative.underlying.timeout == ObjcMapper.resolveTimeout(wire: -1))
        #expect(!negative.hasExplicitTimeout)

        let explicit = ObjcTaskDescriptor(capabilities: ["heavyTask"], timeout: 60.0)
        #expect(explicit.underlying.timeout == 60.0)
        #expect(explicit.underlying.timeout == ObjcMapper.resolveTimeout(wire: 60.0))
        #expect(explicit.hasExplicitTimeout)
    }
}
