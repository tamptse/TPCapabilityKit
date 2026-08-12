import Testing
@testable import TPCapabilityKit

@Suite("SendableBox Thread Safety")
struct SendableBoxTests {
    @Test("concurrent writes do not crash")
    func concurrentWrites() async {
        let box = SendableBox<Int>(0)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<1000 {
                group.addTask {
                    box.setValue(i)
                }
            }
        }
        let value = box.value
        #expect(value >= 0 && value < 1000)
    }
}
