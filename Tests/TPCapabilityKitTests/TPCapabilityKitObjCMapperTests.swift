import Testing
import Foundation
@testable import TPCapabilityKit
@testable import TPCapabilityKitBridge

struct ObjcMapperTimeoutResolverTests {
    @Test func omittedPinsCompatDefaultAsExplicit() {
        let resolved = ObjcMapper.resolveTimeout(wire: nil)
        #expect(resolved == 30.0)
        #expect(resolved == ObjcMapper.omittedTimeout)
    }

    @Test func wireNegativeMeansUnspecified() {
        #expect(ObjcMapper.resolveTimeout(wire: -1) == nil)
        #expect(ObjcMapper.resolveTimeout(wire: -0.001) == nil)
    }

    @Test func explicitWirePreserved() {
        #expect(ObjcMapper.resolveTimeout(wire: 60.0) == 60.0)
        #expect(ObjcMapper.resolveTimeout(wire: 0) == 0)
        #expect(ObjcMapper.resolveTimeout(wire: 30.0) == 30.0)
    }

    @Test func bothDescriptorPathsShareResolver() {
        let plain = ObjcTaskDescriptor(capabilities: ["heavyTask"])
        let client = ObjcTaskDescriptor(clientId: "resolver-home", capabilities: ["heavyTask"])
        #expect(plain.underlying.timeout == ObjcMapper.resolveTimeout(wire: nil))
        #expect(client.underlying.timeout == ObjcMapper.resolveTimeout(wire: nil))

        let plainNeg = ObjcTaskDescriptor(capabilities: ["heavyTask"], timeout: -1)
        let clientNeg = ObjcTaskDescriptor(clientId: "resolver-neg", capabilities: ["heavyTask"], timeout: -1)
        #expect(plainNeg.underlying.timeout == nil)
        #expect(clientNeg.underlying.timeout == nil)
        #expect(plainNeg.underlying.timeout == ObjcMapper.resolveTimeout(wire: -1))

        let plainExp = ObjcTaskDescriptor(capabilities: ["heavyTask"], timeout: 60.0)
        let clientExp = ObjcTaskDescriptor(clientId: "resolver-exp", capabilities: ["heavyTask"], timeout: 60.0)
        #expect(plainExp.underlying.timeout == 60.0)
        #expect(clientExp.underlying.timeout == 60.0)
        #expect(plainExp.underlying.timeout == ObjcMapper.resolveTimeout(wire: 60.0))
    }

    @Test func waitThenRunPathSharesResolver() {
        let descriptor = ObjcMapper.makeDescriptor(
            capabilities: ["heavyTask"],
            priority: TaskPriority.normal.rawValue,
            timeout: -1,
            maxRetries: 0,
            metadata: [:]
        )
        #expect(descriptor.timeout == nil)
        #expect(descriptor.timeout == ObjcMapper.resolveTimeout(wire: -1))

        let explicit = ObjcMapper.makeDescriptor(
            capabilities: ["heavyTask"],
            priority: TaskPriority.normal.rawValue,
            timeout: 60.0,
            maxRetries: 0,
            metadata: [:]
        )
        #expect(explicit.timeout == 60.0)
    }

    @Test func displayFallsBackToPinnedDefault() {
        let swiftNil = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: nil)
        #expect(ObjcMapper.displayTimeout(for: swiftNil) == 30.0)
        let wrapped = ObjcTaskDescriptor(underlying: swiftNil)
        #expect(wrapped.timeout == ObjcMapper.displayTimeout(for: swiftNil))
        #expect(!wrapped.hasExplicitTimeout)

        let explicit = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 60.0)
        #expect(ObjcMapper.displayTimeout(for: explicit) == 60.0)
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
        let auto = ObjcMapper.makeDescriptor(
            capabilities: ["heavyTask"], priority: 4, timeout: 60.0,
            maxRetries: 2, metadata: ["source": "test"]
        )
        let explicit = ObjcMapper.makeDescriptor(
            id: "fixed-id",
            capabilities: ["heavyTask"], priority: 4, timeout: 60.0,
            maxRetries: 2, metadata: ["source": "test"]
        )
        #expect(!auto.id.isEmpty)
        #expect(explicit.id == "fixed-id")
        #expect(auto.requiredCapabilities == explicit.requiredCapabilities)
        #expect(auto.priority == explicit.priority)
        #expect(auto.timeout == explicit.timeout)
        #expect(auto.maxRetries == explicit.maxRetries)
        #expect(auto.metadata == explicit.metadata)
    }
}
