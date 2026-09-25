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

struct ObjcTaskDescriptorTests {
    @Test func initWithDefaults() {
        let descriptor = ObjcTaskDescriptor(capabilities: ["heavyTask"])

        #expect(descriptor.capabilities == ["heavyTask"])
        #expect(descriptor.priority == 2)
        #expect(descriptor.timeout == 30.0)
        #expect(descriptor.maxRetries == 0)
        #expect(descriptor.metadata.isEmpty)
        #expect(!descriptor.id.isEmpty)
    }

    @Test func initWithCustomValues() {
        let descriptor = ObjcTaskDescriptor(
            capabilities: ["networkAccess", "backgroundExecution"],
            priority: 4,
            timeout: 60.0,
            maxRetries: 3,
            metadata: ["source": "test"]
        )

        #expect(Set(descriptor.capabilities) == Set(["networkAccess", "backgroundExecution"]))
        #expect(descriptor.priority == 4)
        #expect(descriptor.timeout == 60.0)
        #expect(descriptor.maxRetries == 3)
        #expect(descriptor.metadata["source"] == "test")
    }

    @Test func underlyingProperty() {
        let descriptor = ObjcTaskDescriptor(capabilities: ["heavyTask"])
        let underlying = descriptor.underlying

        #expect(underlying.id == descriptor.id)
        #expect(underlying.requiredCapabilities == [.heavyTask])
    }

    @Test func outOfRangePriorityCoercesToNormal() {
        let tooHigh = ObjcTaskDescriptor(capabilities: ["heavyTask"], priority: 99)
        #expect(tooHigh.underlying.priority == .normal)

        let negative = ObjcTaskDescriptor(capabilities: ["heavyTask"], priority: -1)
        #expect(negative.underlying.priority == .normal)
    }

    @Test func outOfRangePriorityReadBackIsCoerced() {
        let tooHigh = ObjcTaskDescriptor(capabilities: ["heavyTask"], priority: 99)
        #expect(tooHigh.priority == TaskPriority.normal.rawValue)
        #expect(tooHigh.priority == tooHigh.underlying.priority.rawValue)

        let negative = ObjcTaskDescriptor(capabilities: ["heavyTask"], priority: -1)
        #expect(negative.priority == TaskPriority.normal.rawValue)
        #expect(negative.priority == negative.underlying.priority.rawValue)
    }

    @Test func omittedTimeoutPinnedRegardlessOfDefault() {
        let descriptor = ObjcTaskDescriptor(capabilities: ["heavyTask"])
        #expect(descriptor.timeout == 30.0)
        #expect(descriptor.timeout == (descriptor.underlying.timeout ?? 30.0))

        let nilTimeout = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: nil)
        let wrapped = ObjcTaskDescriptor(underlying: nilTimeout)
        #expect(wrapped.timeout == 30.0)
    }

    @Test func explicitValuesRoundTrip() {
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
        #expect(descriptor.priority == descriptor.underlying.priority.rawValue)
    }

    @Test func negativeTimeoutMeansUnspecified() {
        let descriptor = ObjcTaskDescriptor(capabilities: ["heavyTask"], timeout: -1)

        #expect(descriptor.underlying.timeout == nil)
        #expect(!descriptor.hasExplicitTimeout)
        #expect(descriptor.timeout == 30.0)
    }

    @Test func explicitTimeoutPreserved() {
        let explicit = ObjcTaskDescriptor(capabilities: ["heavyTask"], timeout: 60.0)
        #expect(explicit.underlying.timeout == 60.0)
        #expect(explicit.hasExplicitTimeout)
        #expect(explicit.timeout == 60.0)

        let explicitDefault = ObjcTaskDescriptor(
            capabilities: ["heavyTask"],
            timeout: 30.0
        )
        #expect(explicitDefault.underlying.timeout == 30.0)
        #expect(explicitDefault.hasExplicitTimeout)
    }

    @Test func omittedPinnedVsNegativeFollowsNonDefaultConfig() {
        let store = DynamicStore()
        let scheduler = makeScheduler(
            store: store,
            configuration: .init(defaultTimeout: 0.3, maxPerCapability: 5, maxGlobal: 20)
        )

        let swiftNil = TaskDescriptor(
            requiredCapabilities: [.custom("ForkSwiftNil_\(UUID().uuidString)")]
        )
        #expect(swiftNil.timeout == nil)
        let swiftLease = scheduler.schedule(swiftNil, taskExecution: {})
        #expect(swiftLease.task.timeout == nil)
        scheduler.cancel(taskId: swiftNil.id)

        let omitted = ObjcTaskDescriptor(capabilities: ["heavyTask"])
        #expect(omitted.underlying.timeout == 30.0)
        #expect(omitted.underlying.timeout != 0.3)
        let omittedLease = scheduler.schedule(omitted.underlying, taskExecution: {})
        #expect(omittedLease.task.timeout == 30.0)
        scheduler.cancel(taskId: omitted.id)

        let negative = ObjcTaskDescriptor(capabilities: ["heavyTask"], timeout: -1)
        #expect(negative.underlying.timeout == nil)
        let negativeLease = scheduler.schedule(negative.underlying, taskExecution: {})
        #expect(negativeLease.task.timeout == nil)
        scheduler.cancel(taskId: negative.id)
    }

    @Test func descriptorConstructionIsOneSharedPath() {
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

    @Test func clientIdInitPreservesIdentity() {
        let descriptor = ObjcTaskDescriptor(clientId: "client-123", capabilities: ["heavyTask"])

        #expect(descriptor.id == "client-123")
        #expect(descriptor.underlying.id == "client-123")
    }

    @Test func clientIdInitWithNegativeTimeoutIsUnspecified() {
        let descriptor = ObjcTaskDescriptor(clientId: "client-456", capabilities: ["heavyTask"], timeout: -1)

        #expect(descriptor.id == "client-456")
        #expect(descriptor.underlying.timeout == nil)
        #expect(!descriptor.hasExplicitTimeout)
    }

    @Test func liveViewInitPreservesIdentity() {
        let swift = TaskDescriptor(id: "swift-id-789", requiredCapabilities: [.heavyTask], timeout: nil)
        let wrapped = ObjcTaskDescriptor(underlying: swift)

        #expect(wrapped.id == "swift-id-789")
        #expect(wrapped.underlying.id == "swift-id-789")
        #expect(!wrapped.hasExplicitTimeout)
    }
}

struct ObjcTimeoutRoundTripTests {
    @Test func lossyDisplayPromotesWithoutFlagButPreservesWithFlag() {
        let pin = ObjcTimeout.pinnedDefault
        let wrapped = ObjcTaskDescriptor(
            underlying: TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: nil)
        )
        #expect(wrapped.underlying.timeout == nil)
        #expect(wrapped.timeout == pin)
        #expect(!wrapped.hasExplicitTimeout)

        let fromDisplayAlone = ObjcTaskDescriptor(capabilities: ["heavyTask"], timeout: wrapped.timeout)
        #expect(fromDisplayAlone.underlying.timeout == pin)
        #expect(fromDisplayAlone.hasExplicitTimeout)
        #expect(fromDisplayAlone.timeout == pin)

        let preservingWire = wrapped.hasExplicitTimeout ? wrapped.timeout : -1
        let fromFlag = ObjcTaskDescriptor(capabilities: ["heavyTask"], timeout: preservingWire)
        #expect(fromFlag.underlying.timeout == nil)
        #expect(!fromFlag.hasExplicitTimeout)
        #expect(fromFlag.timeout == pin)

        for wire in [60.0, pin] {
            let explicit = ObjcTaskDescriptor(capabilities: ["heavyTask"], timeout: wire)
            #expect(explicit.underlying.timeout == wire)
            #expect(explicit.hasExplicitTimeout)
            let rebuilt = ObjcTaskDescriptor(capabilities: ["heavyTask"], timeout: explicit.timeout)
            #expect(rebuilt.underlying.timeout == wire)
            #expect(rebuilt.hasExplicitTimeout)
            let rebuiltFlagged = ObjcTaskDescriptor(
                capabilities: ["heavyTask"],
                timeout: explicit.hasExplicitTimeout ? explicit.timeout : -1
            )
            #expect(rebuiltFlagged.underlying.timeout == wire)
            #expect(rebuiltFlagged.hasExplicitTimeout)
        }
    }

    @Test func singleStoredTimeoutTruthAtRest() {
        let pin = ObjcTimeout.pinnedDefault
        let cases = [
            ObjcTaskDescriptor(capabilities: ["heavyTask"]),
            ObjcTaskDescriptor(capabilities: ["heavyTask"], timeout: -1),
            ObjcTaskDescriptor(capabilities: ["heavyTask"], timeout: 60.0),
            ObjcTaskDescriptor(
                underlying: TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: nil)
            ),
        ]
        for descriptor in cases {
            #expect(descriptor.timeout == (descriptor.underlying.timeout ?? pin))
            #expect(descriptor.hasExplicitTimeout == (descriptor.underlying.timeout != nil))
        }
        let mirror = Mirror(reflecting: cases[0])
        #expect(!mirror.children.contains(where: { $0.label == "storedTimeout" }))
    }
}
