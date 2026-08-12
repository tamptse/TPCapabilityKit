import Testing
@testable import TPCapabilityKit

@Suite("TaskStore Tests")
struct TaskStoreTests {
    @Test("store and track task")
    func storeAndTrack() async {
        let store = TaskStore()
        let task = Task<Void, Never> { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        let id = await store.store(task)
        #expect(!id.isEmpty)
        let count = await store.count
        #expect(count == 1)
        task.cancel()
    }
    
    @Test("cancelAll clears tasks")
    func cancelAllClears() async {
        let store = TaskStore()
        let task1 = Task<Void, Never> { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        let task2 = Task<Void, Never> { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        await store.store(task1)
        await store.store(task2)
        await store.cancelAll()
        let count = await store.count
        #expect(count == 0)
    }
    
    @Test("task auto-removes on completion")
    func autoRemoveOnCompletion() async {
        let store = TaskStore()
        let task = Task { }
        await store.store(task)
        _ = await task.result
        try? await Task.sleep(nanoseconds: 100_000_000)
        let count = await store.count
        #expect(count == 0)
    }
}
