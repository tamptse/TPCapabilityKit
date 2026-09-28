import Combine
import Foundation
import Testing
@testable import TPCapabilityKit

@Suite("Scheduler Generations (Store seam)")
struct TPCapabilityKitGenerationsTests {
    @Test("reconfigure preserves in-flight generations; counts aggregate; drained release")
    func generationsPreservedAggregatedReleased() async {
        let store = DynamicStore()
        let gateCap = Capability.custom("genGate_\(UUID().uuidString)")
        let gatePlugin = "GenGate_\(UUID().uuidString)"

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var completions = 0
            func checkDone() {
                completions += 1
                if completions == 2 { done.resume() }
            }

            store.scheduleTask(
                TaskDescriptor(requiredCapabilities: [gateCap], timeout: 30.0),
                task: {},
                completion: { _ in checkDone() }
            )
            #expect(store.pendingTaskCount == 1)

            store.configureScheduler(.init(defaultTimeout: 30.0, maxPerCapability: 5, maxGlobal: 20))
            #expect(store.pendingTaskCount == 1)

            store.scheduleTask(
                TaskDescriptor(requiredCapabilities: [gateCap], timeout: 30.0),
                task: {},
                completion: { _ in checkDone() }
            )
            #expect(store.pendingTaskCount == 2)

            store.registerCapability(for: gatePlugin, capabilities: [gateCap])
        }

        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
        for _ in 0..<1000 {
            if store.pendingTaskCount == 0 && store.activeTaskCount == 0 { break }
            await Task.yield()
        }
        let missing = Capability.custom("genFollowOn_\(UUID().uuidString)")
        let followOnDone = AsyncGate()
        let followOn = store.scheduleTask(
            TaskDescriptor(requiredCapabilities: [missing], timeout: 30.0),
            task: {},
            completion: { _ in followOnDone.signal() }
        )
        #expect(store.pendingTaskCount == 1)
        store.cancelTask(taskId: followOn.task.id)
        await followOnDone.wait()
        for _ in 0..<1000 {
            if store.pendingTaskCount == 0 && store.activeTaskCount == 0 { break }
            await Task.yield()
        }
        #expect(store.pendingTaskCount == 0)
        #expect(store.activeTaskCount == 0)
        store.unregisterCapability(for: gatePlugin)
    }
}
