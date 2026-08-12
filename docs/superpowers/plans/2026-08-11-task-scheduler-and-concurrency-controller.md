# Task Scheduler & Concurrency Controller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add centralized task scheduling with capability-based routing, priority queues, and concurrency limiting to TPCapabilityKit — inspired by Meta's Jupiter (capability matching) and AsyncLimiter (concurrency control).

**Architecture:** Introduce a `TaskScheduler` that acts as a centralized decision engine. Tasks are described via `TaskDescriptor` (capabilities, priority, timeout). A `ConcurrencyController` actor limits concurrent executions per capability. A `Lease` mechanism provides timeout + ACK/NACK lifecycle. `DynamicStore` gains new `scheduleTask` methods that delegate to the scheduler.

**Tech Stack:** Swift 6.1, Combine, Swift Concurrency (async/await, actors, TaskGroup), NSLock for fast critical sections, Swift Testing framework.

## Global Constraints

- Swift 6.1 with strict concurrency (`StrictConcurrency=complete`)
- Platforms: iOS 15+, macOS 12+
- No external dependencies
- All new types must be `Sendable`
- Tests use Swift Testing framework (NOT XCTest)
- Tests create fresh `DynamicStore()` instances (not `.shared`)
- UUID-based plugin IDs to prevent cross-test contamination
- Follow existing code patterns (NSLock for fast paths, Combine for reactivity)

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `Sources/TPCapabilityKit/TaskPriority.swift` | Priority enum (.critical, .high, .normal, .low, .background) |
| Create | `Sources/TPCapabilityKit/TaskDescriptor.swift` | Task description: id, requiredCapabilities, priority, timeout, maxRetries |
| Create | `Sources/TPCapabilityKit/Lease.swift` | Lease lifecycle: active/expired/completed states, ACK/NACK |
| Create | `Sources/TPCapabilityKit/ConcurrencyController.swift` | Actor-based concurrency limiter per capability + global |
| Create | `Sources/TPCapabilityKit/TaskScheduler.swift` | Centralized scheduler: capability matching, priority queue, lease management |
| Modify | `Sources/TPCapabilityKit/DynamicStore.swift:278-337` | Add `scheduleTask` methods that delegate to TaskScheduler |
| Create | `Tests/TPCapabilityKitTests/TPCapabilityKitSchedulerTests.swift` | Tests for TaskScheduler, ConcurrencyController, Lease |
| Create | `Tests/TPCapabilityKitTests/TPCapabilityKitSchedulerIntegrationTests.swift` | Integration tests with DynamicStore |

---

### Task 1: TaskPriority Enum

**Files:**
- Create: `Sources/TPCapabilityKit/TaskPriority.swift`
- Test: `Tests/TPCapabilityKitTests/TPCapabilityKitSchedulerTests.swift`

**Interfaces:**
- Produces: `TaskPriority` enum with `.critical`, `.high`, `.normal`, `.low`, `.background`

- [ ] **Step 1: Create TaskPriority.swift**

```swift
import Foundation

/// Priority levels for scheduled tasks.
/// Higher priority tasks are dequeued before lower priority tasks.
/// Within the same priority, tasks are processed FIFO.
public enum TaskPriority: Int, Comparable, Sendable, CustomStringConvertible {
    case background = 0
    case low = 1
    case normal = 2
    case high = 3
    case critical = 4

    public var description: String {
        switch self {
        case .background: return "background"
        case .low: return "low"
        case .normal: return "normal"
        case .high: return "high"
        case .critical: return "critical"
        }
    }

    public static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
```

- [ ] **Step 2: Write test for TaskPriority**

Add to `Tests/TPCapabilityKitTests/TPCapabilityKitSchedulerTests.swift`:

```swift
import Testing
@testable import TPCapabilityKit

struct TaskPriorityTests {
    @Test func priorityOrdering() {
        #expect(TaskPriority.background < TaskPriority.low)
        #expect(TaskPriority.low < TaskPriority.normal)
        #expect(TaskPriority.normal < TaskPriority.high)
        #expect(TaskPriority.high < TaskPriority.critical)
    }

    @Test func priorityDescription() {
        #expect(TaskPriority.normal.description == "normal")
        #expect(TaskPriority.critical.description == "critical")
    }
}
```

- [ ] **Step 3: Run test to verify it passes**

Run: `swift test --filter TaskPriorityTests`
Expected: 2 tests pass

- [ ] **Step 4: Commit**

```bash
git add Sources/TPCapabilityKit/TaskPriority.swift Tests/TPCapabilityKitTests/TPCapabilityKitSchedulerTests.swift
git commit -m "feat: add TaskPriority enum for task scheduling"
```

---

### Task 2: TaskDescriptor

**Files:**
- Create: `Sources/TPCapabilityKit/TaskDescriptor.swift`
- Test: `Tests/TPCapabilityKitTests/TPCapabilityKitSchedulerTests.swift`

**Interfaces:**
- Consumes: `TaskPriority` (Task 1)
- Produces: `TaskDescriptor` struct

- [ ] **Step 1: Create TaskDescriptor.swift**

```swift
import Foundation

/// Describes a task to be scheduled by the TaskScheduler.
/// Contains all metadata needed for capability matching, prioritization, and lifecycle management.
public struct TaskDescriptor: Sendable, Identifiable {
    /// Unique identifier for this task instance.
    public let id: String

    /// Capabilities required to execute this task. All must be available.
    public let requiredCapabilities: Set<Capability>

    /// Priority level. Higher priority tasks are dequeued first.
    public let priority: TaskPriority

    /// Maximum time in seconds the task can run before lease expires.
    /// Default is 30.0 seconds.
    public let timeout: TimeInterval

    /// Maximum number of retry attempts on failure. Default is 0 (no retries).
    public let maxRetries: Int

    /// Metadata for debugging or custom logic. Optional.
    public let metadata: [String: String]

    /// Creates a new TaskDescriptor.
    public init(
        id: String = UUID().uuidString,
        requiredCapabilities: Set<Capability>,
        priority: TaskPriority = .normal,
        timeout: TimeInterval = 30.0,
        maxRetries: Int = 0,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.requiredCapabilities = requiredCapabilities
        self.priority = priority
        self.timeout = timeout
        self.maxRetries = maxRetries
        self.metadata = metadata
    }
}
```

- [ ] **Step 2: Write test for TaskDescriptor**

Add to `Tests/TPCapabilityKitTests/TPCapabilityKitSchedulerTests.swift`:

```swift
struct TaskDescriptorTests {
    @Test func defaultValues() {
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask])
        #expect(task.requiredCapabilities == [.heavyTask])
        #expect(task.priority == .normal)
        #expect(task.timeout == 30.0)
        #expect(task.maxRetries == 0)
        #expect(task.metadata.isEmpty)
    }

    @Test func customValues() {
        let task = TaskDescriptor(
            id: "custom-id",
            requiredCapabilities: [.networkAccess, .backgroundExecution],
            priority: .critical,
            timeout: 60.0,
            maxRetries: 3,
            metadata: ["source": "test"]
        )
        #expect(task.id == "custom-id")
        #expect(task.priority == .critical)
        #expect(task.timeout == 60.0)
        #expect(task.maxRetries == 3)
        #expect(task.metadata["source"] == "test")
    }
}
```

- [ ] **Step 3: Run test to verify it passes**

Run: `swift test --filter TaskDescriptorTests`
Expected: 2 tests pass

- [ ] **Step 4: Commit**

```bash
git add Sources/TPCapabilityKit/TaskDescriptor.swift
git commit -m "feat: add TaskDescriptor for task metadata"
```

---

### Task 3: Lease

**Files:**
- Create: `Sources/TPCapabilityKit/Lease.swift`
- Test: `Tests/TPCapabilityKitTests/TPCapabilityKitSchedulerTests.swift`

**Interfaces:**
- Consumes: `TaskDescriptor` (Task 2)
- Produces: `Lease` class with state management

- [ ] **Step 1: Create Lease.swift**

```swift
import Foundation

/// Represents the lifecycle of a scheduled task execution.
/// A lease tracks the task from scheduling through completion or failure.
public final class Lease: Sendable {
    /// State of the lease.
    public enum State: Sendable {
        case pending
        case active
        case completed
        case failed(Error)
        case expired
    }

    /// The task descriptor this lease is for.
    public let task: TaskDescriptor

    /// Current state of the lease.
    public private(set) var state: State

    /// When the lease was created.
    public let createdAt: Date

    /// When the lease was activated (task started executing).
    public private(set) var activatedAt: Date?

    /// When the lease completed (success or failure).
    public private(set) var completedAt: Date?

    /// The result of the task execution, if completed successfully.
    public private(set) var result: Any?

    /// Number of times this task has been retried.
    public private(set) var retryCount: Int

    /// Creates a new lease for a task.
    public init(task: TaskDescriptor) {
        self.task = task
        self.state = .pending
        self.createdAt = Date()
        self.retryCount = 0
    }

    /// Marks the lease as active (task started executing).
    public func activate() {
        guard state == .pending else { return }
        state = .active
        activatedAt = Date()
    }

    /// Marks the lease as completed with a result.
    public func complete(with result: Any?) {
        guard state == .active else { return }
        self.result = result
        state = .completed
        completedAt = Date()
    }

    /// Marks the lease as failed with an error.
    public func fail(with error: Error) {
        guard state == .active else { return }
        state = .failed(error)
        completedAt = Date()
    }

    /// Marks the lease as expired (timeout reached).
    public func expire() {
        state = .expired
        completedAt = Date()
    }

    /// Increments retry count and resets to pending state.
    /// Returns true if retries remain, false if max retries exceeded.
    @discardableResult
    public func retry() -> Bool {
        guard retryCount < task.maxRetries else { return false }
        retryCount += 1
        state = .pending
        activatedAt = nil
        completedAt = nil
        result = nil
        return true
    }

    /// Whether the lease is in a terminal state (completed, failed, or expired).
    public var isTerminal: Bool {
        switch state {
        case .completed, .failed, .expired:
            return true
        case .pending, .active:
            return false
        }
    }

    /// Whether the lease has exceeded its timeout.
    public var hasExpired: Bool {
        let deadline = activatedAt ?? createdAt
        return Date().timeIntervalSince(deadline) > task.timeout
    }
}
```

- [ ] **Step 2: Write test for Lease**

Add to `Tests/TPCapabilityKitTests/TPCapabilityKitSchedulerTests.swift`:

```swift
struct LeaseTests {
    @Test func leaseLifecycle() {
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 1.0)
        let lease = Lease(task: task)

        #expect(lease.state == .pending)
        #expect(lease.isTerminal == false)

        lease.activate()
        #expect(lease.state == .active)
        #expect(lease.activatedAt != nil)

        lease.complete(with: "result")
        #expect(lease.state == .completed)
        #expect(lease.isTerminal == true)
        #expect(lease.completedAt != nil)
    }

    @Test func leaseFailure() {
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask])
        let lease = Lease(task: task)
        lease.activate()

        struct TestError: Error {}
        lease.fail(with: TestError())

        if case .failed(let error) = lease.state {
            #expect(error is TestError)
        } else {
            Issue.record("Expected failed state")
        }
    }

    @Test func leaseRetry() {
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], maxRetries: 2)
        let lease = Lease(task: task)

        lease.activate()
        #expect(lease.retry() == true)
        #expect(lease.retryCount == 1)
        #expect(lease.state == .pending)

        lease.activate()
        #expect(lease.retry() == true)
        #expect(lease.retryCount == 2)

        lease.activate()
        #expect(lease.retry() == false)
    }

    @Test func leaseExpiration() {
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask], timeout: 0.01)
        let lease = Lease(task: task)
        lease.activate()

        // Wait for timeout
        Thread.sleep(forTimeInterval: 0.02)
        #expect(lease.hasExpired == true)
    }
}
```

- [ ] **Step 3: Run test to verify it passes**

Run: `swift test --filter LeaseTests`
Expected: 4 tests pass

- [ ] **Step 4: Commit**

```bash
git add Sources/TPCapabilityKit/Lease.swift
git commit -m "feat: add Lease for task lifecycle management"
```

---

### Task 4: ConcurrencyController

**Files:**
- Create: `Sources/TPCapabilityKit/ConcurrencyController.swift`
- Test: `Tests/TPCapabilityKitTests/TPCapabilityKitSchedulerTests.swift`

**Interfaces:**
- Consumes: `Capability` (existing), `TaskDescriptor` (Task 2)
- Produces: `ConcurrencyController` actor

- [ ] **Step 1: Create ConcurrencyController.swift**

```swift
import Foundation

/// Actor-based concurrency limiter that controls how many tasks can execute
/// concurrently per capability and globally.
///
/// Inspired by Meta's AsyncLimiter and Swift's AsyncSemaphore.
/// Uses structured concurrency for safe slot management.
public actor ConcurrencyController {
    /// Configuration for concurrency limits.
    public struct Configuration: Sendable {
        /// Maximum concurrent tasks per capability. Nil means no per-capability limit.
        public let maxPerCapability: Int?

        /// Maximum concurrent tasks globally. Nil means no global limit.
        public let maxGlobal: Int?

        public init(maxPerCapability: Int? = nil, maxGlobal: Int? = nil) {
            self.maxPerCapability = maxPerCapability
            self.maxGlobal = maxGlobal
        }

        /// Default configuration: 5 per capability, 20 global.
        public static let `default` = Configuration(maxPerCapability: 5, maxGlobal: 20)
    }

    private let configuration: Configuration
    private var capabilitySlots: [Capability: Int] = [:]
    private var globalSlots: Int = 0
    private var waitingContinuations: [CheckedContinuation<Void, Never>] = []

    /// Creates a new ConcurrencyController.
    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// Acquires a slot for the given task. Suspends if no slots available.
    /// - Parameter task: The task descriptor to acquire a slot for.
    public func acquire(for task: TaskDescriptor) async {
        // Check if we can acquire immediately
        if canAcquire(for: task) {
            incrementSlots(for: task)
            return
        }

        // Wait for a slot to become available
        await withCheckedContinuation { continuation in
            waitingContinuations.append(continuation)
        }

        // After suspension, acquire the slot
        incrementSlots(for: task)
    }

    /// Releases the slot for the given task.
    /// - Parameter task: The task descriptor to release the slot for.
    public func release(for task: TaskDescriptor) {
        decrementSlots(for: task)

        // Wake up waiting continuations if possible
        var toResume: [CheckedContinuation<Void, Never>] = []
        var remaining: [CheckedContinuation<Void, Never>] = []

        for continuation in waitingContinuations {
            // We can't check canAcquire here without knowing which task,
            // so we resume all waiting continuations and let them re-check
            toResume.append(continuation)
        }
        waitingContinuations = []

        for continuation in toResume {
            continuation.resume()
        }
    }

    /// Returns current utilization stats.
    public func stats() -> Stats {
        Stats(
            globalActive: globalSlots,
            globalMax: configuration.maxGlobal,
            perCapability: capabilitySlots
        )
    }

    // MARK: - Private Helpers

    private func canAcquire(for task: TaskDescriptor) -> Bool {
        // Check global limit
        if let maxGlobal = configuration.maxGlobal {
            guard globalSlots < maxGlobal else { return false }
        }

        // Check per-capability limits
        if let maxPerCap = configuration.maxPerCapability {
            for cap in task.requiredCapabilities {
                guard (capabilitySlots[cap] ?? 0) < maxPerCap else { return false }
            }
        }

        return true
    }

    private func incrementSlots(for task: TaskDescriptor) {
        globalSlots += 1
        for cap in task.requiredCapabilities {
            capabilitySlots[cap, default: 0] += 1
        }
    }

    private func decrementSlots(for task: TaskDescriptor) {
        globalSlots = max(0, globalSlots - 1)
        for cap in task.requiredCapabilities {
            capabilitySlots[cap] = max(0, (capabilitySlots[cap] ?? 1) - 1)
        }
    }

    /// Statistics about current concurrency utilization.
    public struct Stats: Sendable {
        public let globalActive: Int
        public let globalMax: Int?
        public let perCapability: [Capability: Int]
    }
}
```

- [ ] **Step 2: Write test for ConcurrencyController**

Add to `Tests/TPCapabilityKitTests/TPCapabilityKitSchedulerTests.swift`:

```swift
struct ConcurrencyControllerTests {
    @Test func acquireAndRelease() async {
        let controller = ConcurrencyController(configuration: .init(maxPerCapability: 2, maxGlobal: 5))
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask])

        await controller.acquire(for: task)
        let stats = await controller.stats()
        #expect(stats.globalActive == 1)

        await controller.release(for: task)
        let statsAfter = await controller.stats()
        #expect(statsAfter.globalActive == 0)
    }

    @Test func respectsGlobalLimit() async {
        let controller = ConcurrencyController(configuration: .init(maxGlobal: 2))

        let task1 = TaskDescriptor(requiredCapabilities: [.heavyTask])
        let task2 = TaskDescriptor(requiredCapabilities: [.lightTask])
        let task3 = TaskDescriptor(requiredCapabilities: [.networkAccess])

        await controller.acquire(for: task1)
        await controller.acquire(for: task2)

        // Third acquire should suspend (we don't await it to avoid blocking the test)
        let task3Task = Task {
            await controller.acquire(for: task3)
            let stats = await controller.stats()
            return stats.globalActive
        }

        // Give task3 a moment to suspend
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Release one slot
        await controller.release(for: task1)

        let result = await task3Task.value
        #expect(result == 2)
    }

    @Test func respectsPerCapabilityLimit() async {
        let controller = ConcurrencyController(configuration: .init(maxPerCapability: 1))

        let task1 = TaskDescriptor(requiredCapabilities: [.heavyTask])
        let task2 = TaskDescriptor(requiredCapabilities: [.heavyTask])

        await controller.acquire(for: task1)

        let task2Task = Task {
            await controller.acquire(for: task2)
            return true
        }

        try? await Task.sleep(nanoseconds: 100_000_000)

        await controller.release(for: task1)
        let result = await task2Task.value
        #expect(result == true)
    }
}
```

- [ ] **Step 3: Run test to verify it passes**

Run: `swift test --filter ConcurrencyControllerTests`
Expected: 3 tests pass

- [ ] **Step 4: Commit**

```bash
git add Sources/TPCapabilityKit/ConcurrencyController.swift
git commit -m "feat: add actor-based ConcurrencyController for task limiting"
```

---

### Task 5: TaskScheduler

**Files:**
- Create: `Sources/TPCapabilityKit/TaskScheduler.swift`
- Test: `Tests/TPCapabilityKitTests/TPCapabilityKitSchedulerTests.swift`

**Interfaces:**
- Consumes: `TaskDescriptor` (Task 2), `Lease` (Task 3), `ConcurrencyController` (Task 4), `DynamicStore` (existing)
- Produces: `TaskScheduler` class

- [ ] **Step 1: Create TaskScheduler.swift**

```swift
import Foundation
import Combine

/// Centralized task scheduler that manages capability-based routing,
/// priority queuing, and lease lifecycle.
///
/// Inspired by Meta's Jupiter (capability matching) and Async (priority dispatching).
public final class TaskScheduler: @unchecked Sendable {
    /// Configuration for the scheduler.
    public struct Configuration: Sendable {
        /// Default timeout for tasks if not specified in TaskDescriptor.
        public let defaultTimeout: TimeInterval

        /// Maximum number of tasks to process concurrently.
        public let concurrency: ConcurrencyController.Configuration

        public init(
            defaultTimeout: TimeInterval = 30.0,
            concurrency: ConcurrencyController.Configuration = .default
        ) {
            self.defaultTimeout = defaultTimeout
            self.concurrency = concurrency
        }
    }

    private let store: DynamicStore
    private let configuration: Configuration
    private let concurrencyController: ConcurrencyController
    private let lock = NSLock()

    // Priority queues: one per priority level
    private var pendingTasks: [TaskPriority: [Lease]] = [
        .critical: [],
        .high: [],
        .normal: [],
        .low: [],
        .background: []
    ]

    // Active leases by task ID
    private var activeLeases: [String: Lease] = [:]

    // Completion handlers by task ID
    private var completionHandlers: [String: (Lease) -> Void] = [:]

    // Subject for scheduler events
    private let eventSubject = PassthroughSubject<SchedulerEvent, Never>()

    /// Events emitted by the scheduler.
    public enum SchedulerEvent: Sendable {
        case taskScheduled(lease: Lease)
        case taskStarted(lease: Lease)
        case taskCompleted(lease: Lease)
        case taskFailed(lease: Lease, error: Error)
        case taskExpired(lease: Lease)
        case taskRetried(lease: Lease, attempt: Int)
    }

    /// Creates a new TaskScheduler.
    public init(store: DynamicStore = .shared, configuration: Configuration = .init()) {
        self.store = store
        self.configuration = configuration
        self.concurrencyController = ConcurrencyController(configuration: configuration.concurrency)
    }

    /// Publisher for scheduler events.
    public var events: AnyPublisher<SchedulerEvent, Never> {
        eventSubject.eraseToAnyPublisher()
    }

    /// Schedules a task for execution.
    /// - Parameters:
    ///   - task: The task descriptor to schedule.
    ///   - completion: Optional completion handler called when task reaches a terminal state.
    /// - Returns: The lease for tracking the task.
    @discardableResult
    public func schedule(
        _ task: TaskDescriptor,
        completion: ((Lease) -> Void)? = nil
    ) -> Lease {
        let lease = Lease(task: task)

        lock.lock()
        pendingTasks[task.priority]?.append(lease)
        if let completion = completion {
            completionHandlers[task.id] = completion
        }
        lock.unlock()

        eventSubject.send(.taskScheduled(lease: lease))

        // Trigger processing
        Task { await processNext() }

        return lease
    }

    /// Schedules a task and waits for its result.
    /// - Parameter task: The task descriptor to schedule.
    /// - Returns: The result of the task, or nil if timeout/error.
    public func scheduleAndWait<T: Sendable>(
        _ task: TaskDescriptor,
        taskExecution: @escaping @Sendable () async throws -> T
    ) async -> T? {
        await withCheckedContinuation { continuation in
            let lease = schedule(task) { lease in
                switch lease.state {
                case .completed:
                    continuation.resume(returning: lease.result as? T)
                case .failed:
                    continuation.resume(returning: nil)
                case .expired:
                    continuation.resume(returning: nil)
                default:
                    continuation.resume(returning: nil)
                }
            }

            // Start execution
            Task {
                await executeLease(lease, taskExecution: taskExecution)
            }
        }
    }

    /// Cancels a pending task.
    /// - Parameter taskId: The ID of the task to cancel.
    public func cancel(taskId: String) {
        lock.lock()
        defer { lock.unlock() }

        for priority in TaskPriority.allCases {
            pendingTasks[priority]?.removeAll { $0.task.id == taskId }
        }

        if let lease = activeLeases[taskId] {
            lease.expire()
            eventSubject.send(.taskExpired(lease: lease))
        }
    }

    /// Returns the number of pending tasks.
    public var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingTasks.values.reduce(0) { $0 + $1.count }
    }

    /// Returns the number of active tasks.
    public var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeLeases.count
    }

    // MARK: - Private Methods

    private func processNext() async {
        guard let nextLease = dequeueNext() else { return }

        // Check capability availability
        guard checkCapabilities(for: nextLease.task) else {
            // Re-queue and wait for capabilities
            lock.lock()
            pendingTasks[nextLease.task.priority]?.append(nextLease)
            lock.unlock()

            // Wait for capabilities then retry
            Task { await waitForCapabilitiesAndProcess(nextLease) }
            return
        }

        // Execute the task
        await executeLease(nextLease) { [self] in
            // Default execution: just run the task closure
            // In practice, this is overridden by scheduleAndWait
            return nil as Any?
        }
    }

    private func dequeueNext() -> Lease? {
        lock.lock()
        defer { lock.unlock() }

        // Find highest priority non-empty queue
        for priority in [TaskPriority.critical, .high, .normal, .low, .background] {
            if var queue = pendingTasks[priority], !queue.isEmpty {
                let lease = queue.removeFirst()
                pendingTasks[priority] = queue
                return lease
            }
        }

        return nil
    }

    private func checkCapabilities(for task: TaskDescriptor) -> Bool {
        for cap in task.requiredCapabilities {
            guard store.queryCapability(cap) else { return false }
        }
        return true
    }

    private func waitForCapabilitiesAndProcess(_ lease: Lease) async {
        // Wait for all required capabilities
        for cap in lease.task.requiredCapabilities {
            for await isAvailable in store.observeCapability(cap).values {
                if isAvailable { break }
            }
        }

        // Re-check and execute
        guard checkCapabilities(for: lease.task) else { return }
        await executeLease(lease) { nil as Any? }
    }

    private func executeLease<T: Sendable>(
        _ lease: Lease,
        taskExecution: @escaping @Sendable () async throws -> T
    ) async {
        // Acquire concurrency slot
        await concurrencyController.acquire(for: lease.task)

        // Activate lease
        lease.activate()
        lock.lock()
        activeLeases[lease.task.id] = lease
        lock.unlock()

        eventSubject.send(.taskStarted(lease: lease))

        // Execute with timeout
        let result = await withTaskGroup(of: T?.self) { group in
            // Task: actual execution
            group.addTask {
                try? await taskExecution()
            }

            // Task: timeout monitor
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(lease.task.timeout * 1_000_000_000))
                return nil
            }

            guard let result = await group.next() else {
                group.cancelAll()
                return nil
            }
            group.cancelAll()
            return result
        }

        // Complete lease
        lock.lock()
        activeLeases.removeValue(forKey: lease.task.id)
        let completion = completionHandlers.removeValue(forKey: lease.task.id)
        lock.unlock()

        await concurrencyController.release(for: lease.task)

        if let result = result {
            lease.complete(with: result)
            eventSubject.send(.taskCompleted(lease: lease))
        } else {
            // Check if it was a timeout or retryable failure
            if lease.hasExpired {
                lease.expire()
                eventSubject.send(.taskExpired(lease: lease))
            } else if lease.retry() {
                eventSubject.send(.taskRetried(lease: lease, attempt: lease.retryCount))
                lock.lock()
                pendingTasks[lease.task.priority]?.append(lease)
                lock.unlock()
                Task { await processNext() }
                return
            } else {
                struct TaskFailedError: Error {}
                lease.fail(with: TaskFailedError())
                eventSubject.send(.taskFailed(lease: lease, error: TaskFailedError()))
            }
        }

        completion?(lease)
    }
}

extension TaskPriority: CaseIterable {
    public static var allCases: [TaskPriority] {
        [.background, .low, .normal, .high, .critical]
    }
}
```

- [ ] **Step 2: Write test for TaskScheduler**

Add to `Tests/TPCapabilityKitTests/TPCapabilityKitSchedulerTests.swift`:

```swift
struct TaskSchedulerTests {
    @Test func scheduleAndComplete() async {
        let store = DynamicStore()
        let pluginId = "SchedulerPlugin_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])

        let scheduler = TaskScheduler(store: store)

        let task = TaskDescriptor(requiredCapabilities: [.heavyTask])
        let result = await scheduler.scheduleAndWait(task) {
            return "ScheduledResult"
        }

        #expect(result == "ScheduledResult")
    }

    @Test func scheduleWithoutCapabilityReturnsNil() async {
        let store = DynamicStore()
        let scheduler = TaskScheduler(store: store)

        let task = TaskDescriptor(
            requiredCapabilities: [.custom("NonExistent_\(UUID().uuidString)")],
            timeout: 0.5
        )
        let result = await scheduler.scheduleAndWait(task) {
            return "ShouldNotRun"
        }

        #expect(result == nil)
    }

    @Test func priorityOrdering() async {
        let store = DynamicStore()
        let pluginId = "PriorityPlugin_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])

        let scheduler = TaskScheduler(store: store)
        var executionOrder: [String] = []

        let task1 = TaskDescriptor(
            id: "low",
            requiredCapabilities: [.heavyTask],
            priority: .low
        )
        let task2 = TaskDescriptor(
            id: "high",
            requiredCapabilities: [.heavyTask],
            priority: .high
        )

        // Schedule low first, then high
        scheduler.schedule(task1) { _ in executionOrder.append("low") }
        scheduler.schedule(task2) { _ in executionOrder.append("high") }

        // Wait for both to complete
        try? await Task.sleep(nanoseconds: 500_000_000)

        // High should execute first
        #expect(executionOrder.first == "high")
    }

    @Test func cancelTask() async {
        let store = DynamicStore()
        let scheduler = TaskScheduler(store: store)

        let task = TaskDescriptor(
            id: "cancelable",
            requiredCapabilities: [.custom("NeverAvailable_\(UUID().uuidString)")],
            timeout: 5.0
        )

        let lease = scheduler.schedule(task)
        scheduler.cancel(taskId: task.id)

        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(lease.isTerminal)
    }
}
```

- [ ] **Step 3: Run test to verify it passes**

Run: `swift test --filter TaskSchedulerTests`
Expected: 4 tests pass

- [ ] **Step 4: Commit**

```bash
git add Sources/TPCapabilityKit/TaskScheduler.swift
git commit -m "feat: add TaskScheduler with capability matching and priority queues"
```

---

### Task 6: Integration with DynamicStore

**Files:**
- Modify: `Sources/TPCapabilityKit/DynamicStore.swift:278-337`
- Test: `Tests/TPCapabilityKitTests/TPCapabilityKitSchedulerIntegrationTests.swift`

**Interfaces:**
- Consumes: `TaskScheduler` (Task 5), `TaskDescriptor` (Task 2)
- Produces: New methods on `DynamicStore`

- [ ] **Step 1: Add scheduleTask methods to DynamicStore**

Add after line 337 in `Sources/TPCapabilityKit/DynamicStore.swift`:

```swift
    // MARK: - Task Scheduling

    /// Shared task scheduler instance. Lazily created on first access.
    public private(set) lazy var scheduler: TaskScheduler = TaskScheduler(store: self)

    /// Schedules a task for centralized execution with capability matching and priority.
    /// - Parameters:
    ///   - descriptor: The task descriptor.
    ///   - task: The async closure to execute.
    ///   - completion: Optional completion handler.
    /// - Returns: The lease for tracking.
    @discardableResult
    public func scheduleTask<T: Sendable>(
        _ descriptor: TaskDescriptor,
        task: @escaping @Sendable () async throws -> T,
        completion: ((Lease) -> Void)? = nil
    ) -> Lease {
        scheduler.schedule(descriptor, completion: completion)
    }

    /// Schedules a task and waits for its result.
    /// - Parameters:
    ///   - descriptor: The task descriptor.
    ///   - task: The async closure to execute.
    /// - Returns: The result, or nil if timeout/error.
    public func scheduleTaskAndWait<T: Sendable>(
        _ descriptor: TaskDescriptor,
        task: @escaping @Sendable () async throws -> T
    ) async -> T? {
        await scheduler.scheduleAndWait(descriptor, taskExecution: task)
    }
```

- [ ] **Step 2: Write integration test**

Create `Tests/TPCapabilityKitTests/TPCapabilityKitSchedulerIntegrationTests.swift`:

```swift
import Foundation
import Testing
@testable import TPCapabilityKit

struct DynamicStoreSchedulerIntegrationTests {
    @Test func scheduleTaskWithCapability() async {
        let store = DynamicStore()
        let pluginId = "IntegPlugin_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])

        let result = await store.scheduleTaskAndWait(
            TaskDescriptor(requiredCapabilities: [.heavyTask])
        ) {
            return "IntegrationResult"
        }

        #expect(result == "IntegrationResult")
    }

    @Test func scheduleTaskWithoutCapability() async {
        let store = DynamicStore()

        let result = await store.scheduleTaskAndWait(
            TaskDescriptor(
                requiredCapabilities: [.custom("Missing_\(UUID().uuidString)")],
                timeout: 0.5
            )
        ) {
            return "ShouldNotRun"
        }

        #expect(result == nil)
    }

    @Test func scheduleMultipleTasksWithConcurrencyLimit() async {
        let store = DynamicStore()
        let pluginId = "ConcurrencyInteg_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])

        store.scheduler = TaskScheduler(
            store: store,
            configuration: .init(concurrency: .init(maxPerCapability: 2))
        )

        var activeCount = 0
        var maxActive = 0
        let lock = NSLock()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    await store.scheduleTaskAndWait(
                        TaskDescriptor(requiredCapabilities: [.heavyTask])
                    ) {
                        lock.lock()
                        activeCount += 1
                        maxActive = Swift.max(maxActive, activeCount)
                        lock.unlock()

                        try? await Task.sleep(nanoseconds: 10_000_000)

                        lock.lock()
                        activeCount -= 1
                        lock.unlock()

                        return i
                    }
                }
            }
        }

        #expect(maxActive <= 2)
    }
}
```

- [ ] **Step 3: Run test to verify it passes**

Run: `swift test --filter DynamicStoreSchedulerIntegrationTests`
Expected: 3 tests pass

- [ ] **Step 4: Commit**

```bash
git add Sources/TPCapabilityKit/DynamicStore.swift Tests/TPCapabilityKitTests/TPCapabilityKitSchedulerIntegrationTests.swift
git commit -m "feat: integrate TaskScheduler with DynamicStore"
```

---

### Task 7: Final Verification

**Files:** None (verification only)

- [ ] **Step 1: Run full test suite**

Run: `swift test`
Expected: All tests pass (existing + new)

- [ ] **Step 2: Run build**

Run: `swift build`
Expected: Clean build, no warnings

- [ ] **Step 3: Verify no regressions**

Check that existing `runTask` and `runTaskWhenAvailable` methods still work unchanged.

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "chore: final verification and cleanup"
```

---

## Summary

| Task | Component | Lines (est.) | Tests |
|------|-----------|--------------|-------|
| 1 | TaskPriority | ~30 | 2 |
| 2 | TaskDescriptor | ~50 | 2 |
| 3 | Lease | ~120 | 4 |
| 4 | ConcurrencyController | ~130 | 3 |
| 5 | TaskScheduler | ~250 | 4 |
| 6 | DynamicStore integration | ~30 | 3 |
| 7 | Final verification | - | - |
| **Total** | | **~610** | **18** |

## Key Design Decisions

1. **Actor-based ConcurrencyController**: Uses Swift actors for safe state management without manual locking. Continuations provide structured waiting.

2. **NSLock for TaskScheduler**: Fast critical sections for queue operations. Actor overhead not needed for simple queue manipulation.

3. **Lease pattern**: Provides timeout + retry lifecycle. Inspired by Meta's FOQS lease mechanism.

4. **Priority queues**: Simple array-based queues per priority level. FIFO within same priority.

5. **Capability-first routing**: Tasks only execute when ALL required capabilities are available. No partial matching.

6. **Backward compatible**: Existing `runTask` and `runTaskWhenAvailable` methods unchanged. New methods are additive.
