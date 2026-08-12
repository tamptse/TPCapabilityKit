import Foundation

/// Actor that tracks unstructured tasks for lifecycle management.
/// Prevents task leaks by maintaining strong references until completion.
actor TaskStore {
    private var tasks: [String: Task<Void, Never>] = [:]
    private var counter: Int = 0
    
    /// Stores a task with an auto-generated identifier.
    /// - Parameter task: The unstructured task to track.
    /// - Returns: A unique identifier for the stored task.
    @discardableResult
    func store(_ task: Task<Void, Never>) -> String {
        let id = "task-\(counter)"
        counter += 1
        tasks[id] = task
        
        // Auto-remove when complete
        Task { [weak self] in
            _ = await task.result
            await self?.remove(id: id)
        }
        
        return id
    }
    
    /// Removes a task by identifier.
    func remove(id: String) {
        tasks.removeValue(forKey: id)
    }
    
    /// Cancels all tracked tasks.
    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }
    
    /// Number of active tracked tasks.
    var count: Int {
        tasks.count
    }
}
