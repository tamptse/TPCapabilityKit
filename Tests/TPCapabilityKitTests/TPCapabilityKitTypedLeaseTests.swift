import Testing
@testable import TPCapabilityKit

@Suite("TypedLease Tests")
struct TypedLeaseTests {
    @Test("typedResult returns nil when not completed")
    func typedResultNilWhenPending() async {
        let descriptor = TaskDescriptor(requiredCapabilities: [])
        let lease = Lease(task: descriptor)
        let typedLease = TypedLease<String>(lease: lease)
        #expect(typedLease.typedResult == nil)
    }
    
    @Test("typedResult returns value when completed")
    func typedResultValueWhenCompleted() async {
        let descriptor = TaskDescriptor(requiredCapabilities: [])
        let lease = Lease(task: descriptor)
        lease.activate()
        lease.complete(with: "hello")
        let typedLease = TypedLease<String>(lease: lease)
        #expect(typedLease.typedResult == "hello")
    }
    
    @Test("typedResult returns nil for type mismatch")
    func typedResultNilOnMismatch() async {
        let descriptor = TaskDescriptor(requiredCapabilities: [])
        let lease = Lease(task: descriptor)
        lease.activate()
        lease.complete(with: 42)
        let typedLease = TypedLease<String>(lease: lease)
        #expect(typedLease.typedResult == nil)
    }
    
    @Test("isTerminal reflects lease state")
    func isTerminalReflectsState() async {
        let descriptor = TaskDescriptor(requiredCapabilities: [])
        let lease = Lease(task: descriptor)
        let typedLease = TypedLease<String>(lease: lease)
        #expect(!typedLease.isTerminal)
        lease.activate()
        lease.complete(with: "done")
        #expect(typedLease.isTerminal)
    }
}
