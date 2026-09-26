import Testing
import Foundation
@testable import TPCapabilityKit
@testable import TPCapabilityKitBridge

struct ObjcPriorityValidityTests {
    @Test func validRawsRoundTripThroughBothConstructors() {
        for rawValue in 0...4 {
            #expect(ObjcTaskDescriptor.isValidPriority(rawValue))

            let plain = ObjcTaskDescriptor(capabilities: ["heavyTask"], priority: rawValue)
            #expect(plain.priority == rawValue)
            #expect(plain.priority == plain.underlying.priority.rawValue)

            let client = ObjcTaskDescriptor(clientId: "valid-\(rawValue)", capabilities: ["heavyTask"], priority: rawValue)
            #expect(client.priority == rawValue)
            #expect(client.priority == client.underlying.priority.rawValue)
        }
    }

    @Test func invalidRawsRejectedByCheckButStillCoerceToNormal() {
        for rawValue in [-100, -1, 5, 99] {
            #expect(!ObjcTaskDescriptor.isValidPriority(rawValue))

            let plain = ObjcTaskDescriptor(capabilities: ["heavyTask"], priority: rawValue)
            #expect(plain.underlying.priority == .normal)
            #expect(plain.priority == TaskPriority.normal.rawValue)

            let client = ObjcTaskDescriptor(clientId: "invalid-\(rawValue)", capabilities: ["heavyTask"], priority: rawValue)
            #expect(client.underlying.priority == .normal)
            #expect(client.priority == TaskPriority.normal.rawValue)
        }
    }

    @Test func checkAgreesWithCoercionOutcome() {
        for rawValue in -10...10 {
            let descriptor = ObjcTaskDescriptor(capabilities: ["heavyTask"], priority: rawValue)
            if ObjcTaskDescriptor.isValidPriority(rawValue) {
                #expect(descriptor.priority == rawValue)
            } else {
                #expect(descriptor.underlying.priority == .normal)
            }
        }
    }
}
