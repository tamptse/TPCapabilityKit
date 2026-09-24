import Testing
import Foundation
@testable import TPCapabilityKit
@testable import TPCapabilityKitBridge

struct ObjcMapperTimeoutResolverTests {
    @Test func omittedPinsCompatDefaultAsExplicit() {
        let plain = ObjcTaskDescriptor(capabilities: ["heavyTask"])
        #expect(plain.timeout == 30.0)
        #expect(plain.underlying.timeout == 30.0)
        #expect(plain.hasExplicitTimeout)

        let client = ObjcTaskDescriptor(clientId: "omitted-pin", capabilities: ["heavyTask"])
        #expect(client.timeout == 30.0)
        #expect(client.underlying.timeout == 30.0)
        #expect(client.hasExplicitTimeout)
    }

    @Test func wireNegativeMeansUnspecified() {
        for wire in [-1.0, -0.001] {
            let plain = ObjcTaskDescriptor(capabilities: ["heavyTask"], timeout: wire)
            #expect(plain.underlying.timeout == nil)
            #expect(!plain.hasExplicitTimeout)
            #expect(plain.timeout == 30.0)

            let client = ObjcTaskDescriptor(clientId: "neg-\(wire)", capabilities: ["heavyTask"], timeout: wire)
            #expect(client.underlying.timeout == nil)
            #expect(!client.hasExplicitTimeout)
            #expect(client.timeout == 30.0)
        }
    }

    @Test func explicitWirePreserved() {
        for wire in [60.0, 0.0, 30.0] {
            let plain = ObjcTaskDescriptor(capabilities: ["heavyTask"], timeout: wire)
            #expect(plain.underlying.timeout == wire)
            #expect(plain.hasExplicitTimeout)
            #expect(plain.timeout == wire)

            let client = ObjcTaskDescriptor(clientId: "exp-\(wire)", capabilities: ["heavyTask"], timeout: wire)
            #expect(client.underlying.timeout == wire)
            #expect(client.hasExplicitTimeout)
            #expect(client.timeout == wire)
        }
    }

    @Test func bothDescriptorPathsShareResolver() {
        let plain = ObjcTaskDescriptor(capabilities: ["heavyTask"])
        let client = ObjcTaskDescriptor(clientId: "resolver-home", capabilities: ["heavyTask"])
        #expect(plain.underlying.timeout == client.underlying.timeout)
        #expect(plain.timeout == client.timeout)
        #expect(plain.hasExplicitTimeout == client.hasExplicitTimeout)

        let plainNeg = ObjcTaskDescriptor(capabilities: ["heavyTask"], timeout: -1)
        let clientNeg = ObjcTaskDescriptor(clientId: "resolver-neg", capabilities: ["heavyTask"], timeout: -1)
        #expect(plainNeg.underlying.timeout == nil)
        #expect(clientNeg.underlying.timeout == nil)
        #expect(plainNeg.timeout == clientNeg.timeout)
        #expect(!plainNeg.hasExplicitTimeout && !clientNeg.hasExplicitTimeout)

        let plainExp = ObjcTaskDescriptor(capabilities: ["heavyTask"], timeout: 60.0)
        let clientExp = ObjcTaskDescriptor(clientId: "resolver-exp", capabilities: ["heavyTask"], timeout: 60.0)
        #expect(plainExp.underlying.timeout == 60.0)
        #expect(clientExp.underlying.timeout == 60.0)
        #expect(plainExp.timeout == clientExp.timeout)
    }

    @Test func waitThenRunPathSharesResolver() async {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let pluginId = "MapperWaitShare_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }

        await withCheckedContinuation { continuation in
            bridge.taskScheduler.runWhenAvailable(
                capability: "heavyTask", timeout: -1, queue: nil,
                task: { NSString(string: "NegativeUnspecified") },
                completion: { result in
                    #expect((result as? String) == "NegativeUnspecified")
                    continuation.resume()
                }
            )
        }

        await withCheckedContinuation { continuation in
            bridge.taskScheduler.runWhenAvailable(
                capability: "heavyTask", timeout: 60.0, queue: nil,
                task: { NSString(string: "Explicit") },
                completion: { result in
                    #expect((result as? String) == "Explicit")
                    continuation.resume()
                }
            )
        }
    }

    @Test func displayFallsBackToPinnedDefault() {
        let swiftNil = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: nil)
        let wrapped = ObjcTaskDescriptor(underlying: swiftNil)
        #expect(wrapped.timeout == 30.0)
        #expect(!wrapped.hasExplicitTimeout)

        let explicit = ObjcTaskDescriptor(capabilities: ["heavyTask"], timeout: 60.0)
        #expect(explicit.timeout == 60.0)
        #expect(explicit.hasExplicitTimeout)
    }

    @Test func descriptorRoundTripWithoutScheduler() {
        let descriptor = ObjcTaskDescriptor(
            capabilities: ["networkAccess", "backgroundExecution"],
            priority: 4,
            timeout: 60.0,
            maxRetries: 3,
            metadata: ["source": "test"]
        )
        #expect(Set(descriptor.capabilities) == Set(["networkAccess", "backgroundExecution"]))
        #expect(descriptor.priority == TaskPriority.critical.rawValue)
        #expect(descriptor.timeout == 60.0)
        #expect(descriptor.maxRetries == 3)
        #expect(descriptor.metadata == ["source": "test"])
        #expect(descriptor.id == descriptor.underlying.id)
        #expect(descriptor.hasExplicitTimeout)
    }

    @Test func clientIdSurvivesRoundTrip() {
        let descriptor = ObjcTaskDescriptor(clientId: "client-123", capabilities: ["heavyTask"])
        #expect(descriptor.id == "client-123")
        #expect(descriptor.underlying.id == "client-123")
    }

    @Test func makeDescriptorPathsAgree() {
        let auto = ObjcTaskDescriptor(
            capabilities: ["heavyTask"], priority: 4, timeout: 60.0,
            maxRetries: 2, metadata: ["source": "test"]
        )
        let explicit = ObjcTaskDescriptor(
            clientId: "fixed-id",
            capabilities: ["heavyTask"], priority: 4, timeout: 60.0,
            maxRetries: 2, metadata: ["source": "test"]
        )
        #expect(!auto.id.isEmpty)
        #expect(explicit.id == "fixed-id")
        #expect(Set(auto.capabilities) == Set(explicit.capabilities))
        #expect(auto.priority == explicit.priority)
        #expect(auto.underlying.timeout == explicit.underlying.timeout)
        #expect(auto.maxRetries == explicit.maxRetries)
        #expect(auto.metadata == explicit.metadata)
    }
}
