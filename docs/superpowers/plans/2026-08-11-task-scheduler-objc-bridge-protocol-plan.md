# TaskScheduler ObjC Bridge & Protocol Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract `TaskSchedulerProtocol` for A/B testing and add full ObjC bridge for TaskScheduler.

**Architecture:** Protocol-based design with `TaskSchedulerProtocol` enabling swappable implementations. ObjC wrapper classes (`ObjcTaskDescriptor`, `ObjcLease`, `ObjcTaskScheduler`) bridge Swift concurrency to completion-handler patterns for ObjC consumers.

**Tech Stack:** Swift 6.1, Combine, Swift Testing framework, `@unchecked Sendable` for ObjC wrappers.

## Global Constraints

- Swift 6.1 with `StrictConcurrency=complete`
- Platforms: iOS 15+ / macOS 12+
- No external dependencies
- All new types must be `Sendable`
- Tests use Swift Testing framework (NOT XCTest)
- Fresh `DynamicStore()` instances for each test
- UUID-based plugin IDs for isolation

---

### Task 1: TaskSchedulerProtocol

**Files:**
- Create: `Sources/TPCapabilityKit/TaskSchedulerProtocol.swift`

**Interfaces:**
- Produces: `TaskSchedulerProtocol` — protocol that `TaskScheduler` and future implementations conform to

- [ ] **Step 1: Create TaskSchedulerProtocol.swift**

```swift
import Combine

/// Protocol defining the interface for task scheduling.
/// Enables A/B testing of different scheduling implementations.
public protocol TaskSchedulerProtocol: AnyObject, Sendable {
    /// Schedules a task for execution.
    func schedule(
        _ task: TaskDescriptor,
        taskExecution: @escaping @Sendable () async -> Void,
        completion: ((Lease) -> Void)?,
        autoProcess: Bool
    ) -> Lease

    /// Schedules a task and waits for its result.
    func scheduleAndWait<T: Sendable>(
        _ task: TaskDescriptor,
        taskExecution: @escaping @Sendable () async throws -> T
    ) async -> T?

    /// Cancels a pending task.
    func cancel(taskId: String)

    /// Number of pending tasks.
    var pendingCount: Int { get }

    /// Number of active tasks.
    var activeCount: Int { get }

    /// Publisher for scheduler events.
    var events: AnyPublisher<TaskScheduler.SchedulerEvent, Never> { get }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build`
Expected: BUILD SUCCEEDS

- [ ] **Step 3: Commit**

```bash
git add Sources/TPCapabilityKit/TaskSchedulerProtocol.swift
git commit -m "feat: add TaskSchedulerProtocol for A/B testing"
```

---

### Task 2: TaskScheduler Conformance

**Files:**
- Modify: `Sources/TPCapabilityKit/TaskScheduler.swift:17`

**Interfaces:**
- Consumes: `TaskSchedulerProtocol` from Task 1
- Produces: `TaskScheduler` conforming to `TaskSchedulerProtocol`

- [ ] **Step 1: Add protocol conformance**

In `TaskScheduler.swift`, change line 17 from:
```swift
public final class TaskScheduler: @unchecked Sendable {
```
to:
```swift
public final class TaskScheduler: TaskSchedulerProtocol {
```

- [ ] **Step 2: Add @discardableResult to schedule method**

In `TaskScheduler.swift:91`, add `@discardableResult` before `public func schedule`:
```swift
@discardableResult
public func schedule(
```

- [ ] **Step 3: Build to verify compilation**

Run: `swift build`
Expected: BUILD SUCCEEDS

- [ ] **Step 4: Commit**

```bash
git add Sources/TPCapabilityKit/TaskScheduler.swift
git commit -m "feat: make TaskScheduler conform to TaskSchedulerProtocol"
```

---

### Task 3: DynamicStore Protocol Property

**Files:**
- Modify: `Sources/TPCapabilityKit/DynamicStore.swift:340-378`

**Interfaces:**
- Consumes: `TaskSchedulerProtocol` from Task 1
- Produces: `DynamicStore.scheduler: any TaskSchedulerProtocol`

- [ ] **Step 1: Update scheduler property type**

In `DynamicStore.swift`, replace lines 340-350 with:
```swift
// MARK: - Task Scheduling

/// Task scheduler instance. Can be replaced for A/B testing.
public var scheduler: any TaskSchedulerProtocol {
    get {
        if let existing = _scheduler { return existing }
        let new = TaskScheduler(store: self)
        _scheduler = new
        return new
    }
    set { _scheduler = newValue }
}
private var _scheduler: (any TaskSchedulerProtocol)?
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build`
Expected: BUILD SUCCEEDS

- [ ] **Step 3: Run existing tests to verify backward compatibility**

Run: `swift test`
Expected: ALL TESTS PASS

- [ ] **Step 4: Commit**

```bash
git add Sources/TPCapabilityKit/DynamicStore.swift
git commit -m "feat: change DynamicStore.scheduler to protocol-based property"
```

---

### Task 4: ObjcTaskDescriptor

**Files:**
- Create: `Sources/TPCapabilityKitBridge/ObjcTaskDescriptor.swift`

**Interfaces:**
- Consumes: `TaskDescriptor`, `Capability`, `TaskPriority` from TPCapabilityKit
- Produces: `ObjcTaskDescriptor` — ObjC wrapper for TaskDescriptor

- [ ] **Step 1: Create ObjcTaskDescriptor.swift**

```swift
import Foundation
import TPCapabilityKit

/// Objective-C wrapper for TaskDescriptor.
@objc(TPTaskDescriptor)
public final class ObjcTaskDescriptor: NSObject, @unchecked Sendable {
    /// Unique identifier for this task.
    @objc public let id: String

    /// Priority level (TaskPriority.rawValue).
    @objc public let priority: Int

    /// Maximum time in seconds the task can run.
    @objc public let timeout: TimeInterval

    /// Maximum number of retry attempts.
    @objc public let maxRetries: Int

    /// Capabilities required to execute this task.
    @objc public let capabilities: [String]

    /// Metadata for debugging or custom logic.
    @objc public let metadata: [String: String]

    /// The underlying Swift TaskDescriptor.
    public let underlying: TaskDescriptor

    /// Creates a new task descriptor.
    /// - Parameters:
    ///   - capabilities: Array of capability strings required.
    ///   - priority: Priority level (0=background, 4=critical). Default is 2 (normal).
    ///   - timeout: Maximum execution time in seconds. Default is 30.0.
    ///   - maxRetries: Maximum retry attempts. Default is 0.
    ///   - metadata: Optional metadata dictionary.
    @objc public init(
        capabilities: [String],
        priority: Int = 2,
        timeout: TimeInterval = 30.0,
        maxRetries: Int = 0,
        metadata: [String: String] = [:]
    ) {
        let caps = capabilities.map { Capability(rawValue: $0) }
        self.underlying = TaskDescriptor(
            requiredCapabilities: Set(caps),
            priority: TaskPriority(rawValue: priority) ?? .normal,
            timeout: timeout,
            maxRetries: maxRetries,
            metadata: metadata
        )
        self.id = underlying.id
        self.priority = priority
        self.timeout = timeout
        self.maxRetries = maxRetries
        self.capabilities = capabilities
        self.metadata = metadata
        super.init()
    }

    internal init(underlying: TaskDescriptor) {
        self.underlying = underlying
        self.id = underlying.id
        self.priority = underlying.priority.rawValue
        self.timeout = underlying.timeout
        self.maxRetries = underlying.maxRetries
        self.capabilities = underlying.requiredCapabilities.map { $0.rawValue }
        self.metadata = underlying.metadata
        super.init()
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build`
Expected: BUILD SUCCEEDS

- [ ] **Step 3: Commit**

```bash
git add Sources/TPCapabilityKitBridge/ObjcTaskDescriptor.swift
git commit -m "feat: add ObjcTaskDescriptor wrapper for TaskDescriptor"
```

---

### Task 5: ObjcLease

**Files:**
- Create: `Sources/TPCapabilityKitBridge/ObjcLease.swift`

**Interfaces:**
- Consumes: `Lease`, `Lease.State` from TPCapabilityKit
- Produces: `ObjcLease` — ObjC wrapper for Lease

- [ ] **Step 1: Add rawValue to Lease.State**

In `Lease.swift`, add rawValue conversion to the State enum:
```swift
extension Lease.State {
    var rawValue: Int {
        switch self {
        case .pending: return 0
        case .active: return 1
        case .completed: return 2
        case .failed: return 3
        case .expired: return 4
        }
    }
}
```

- [ ] **Step 2: Create ObjcLease.swift**

```swift
import Foundation
import TPCapabilityKit

/// Objective-C wrapper for Lease.
@objc(TPLease)
public final class ObjcLease: NSObject, @unchecked Sendable {
    /// Lease state for ObjC consumers.
    @objc public enum State: Int {
        case pending = 0
        case active = 1
        case completed = 2
        case failed = 3
        case expired = 4
    }

    /// Task identifier this lease is for.
    @objc public let taskId: String

    /// Current state of the lease.
    @objc public private(set) var state: State

    /// When the lease was created.
    @objc public let createdAt: Date

    /// When the lease was activated (task started executing).
    @objc public private(set) var activatedAt: Date?

    /// When the lease completed (success or failure).
    @objc public private(set) var completedAt: Date?

    /// The result of the task execution, if completed successfully.
    @objc public private(set) var result: Any?

    /// Number of times this task has been retried.
    @objc public private(set) var retryCount: Int

    /// The underlying Swift Lease.
    public let underlying: Lease

    internal init(underlying: Lease) {
        self.underlying = underlying
        self.taskId = underlying.task.id
        self.state = State(rawValue: underlying.state.rawValue) ?? .pending
        self.createdAt = underlying.createdAt
        self.activatedAt = underlying.activatedAt
        self.completedAt = underlying.completedAt
        self.result = underlying.result
        self.retryCount = underlying.retryCount
        super.init()
    }
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `swift build`
Expected: BUILD SUCCEEDS

- [ ] **Step 4: Commit**

```bash
git add Sources/TPCapabilityKit/Lease.swift Sources/TPCapabilityKitBridge/ObjcLease.swift
git commit -m "feat: add ObjcLease wrapper for Lease"
```

---

### Task 6: ObjcTaskScheduler

**Files:**
- Create: `Sources/TPCapabilityKitBridge/ObjcTaskScheduler.swift`

**Interfaces:**
- Consumes: `TaskSchedulerProtocol`, `ObjcTaskDescriptor`, `ObjcLease`
- Produces: `ObjcTaskScheduler` — ObjC wrapper for TaskSchedulerProtocol

- [ ] **Step 1: Create ObjcTaskScheduler.swift**

```swift
import Foundation
import TPCapabilityKit

/// Objective-C wrapper for TaskSchedulerProtocol.
@objc(TPTaskScheduler)
public final class ObjcTaskScheduler: NSObject, @unchecked Sendable {
    private let scheduler: any TaskSchedulerProtocol
    private let store: DynamicStore

    internal init(scheduler: any TaskSchedulerProtocol, store: DynamicStore) {
        self.scheduler = scheduler
        self.store = store
        super.init()
    }

    /// Schedules a task for execution.
    @objc public func schedule(
        _ descriptor: ObjcTaskDescriptor,
        task: @escaping () -> Void,
        completion: ((ObjcLease) -> Void)? = nil
    ) -> ObjcLease {
        let lease = scheduler.schedule(
            descriptor.underlying,
            taskExecution: { task() },
            completion: completion.map { handler in
                { lease in handler(ObjcLease(underlying: lease)) }
            },
            autoProcess: true
        )
        return ObjcLease(underlying: lease)
    }

    /// Schedules a task and waits for result via completion handler.
    @objc public func scheduleAndWait(
        _ descriptor: ObjcTaskDescriptor,
        task: @escaping () -> NSObject,
        completion: @escaping (NSObject?) -> Void
    ) {
        Task {
            let result: NSObject? = await scheduler.scheduleAndWait(
                descriptor.underlying
            ) {
                task() as NSObject
            }
            completion(result)
        }
    }

    /// Cancels a pending task.
    @objc public func cancel(taskId: String) {
        scheduler.cancel(taskId: taskId)
    }

    /// Number of pending tasks.
    @objc public var pendingCount: Int { scheduler.pendingCount }

    /// Number of active tasks.
    @objc public var activeCount: Int { scheduler.activeCount }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build`
Expected: BUILD SUCCEEDS

- [ ] **Step 3: Commit**

```bash
git add Sources/TPCapabilityKitBridge/ObjcTaskScheduler.swift
git commit -m "feat: add ObjcTaskScheduler wrapper for TaskSchedulerProtocol"
```

---

### Task 7: ObjcStoreBridge Additions

**Files:**
- Modify: `Sources/TPCapabilityKitBridge/ObjcStoreBridge.swift`

**Interfaces:**
- Consumes: `ObjcTaskDescriptor`, `ObjcLease`, `ObjcTaskScheduler`
- Produces: Updated `ObjcStoreBridge` with scheduling APIs

- [ ] **Step 1: Add lock and cached scheduler properties**

In `ObjcStoreBridge.swift`, add after line 11 (`private let store: DynamicStore`):
```swift
private let lock = NSLock()
private var _taskScheduler: ObjcTaskScheduler?
```

- [ ] **Step 2: Add taskScheduler property**

In `ObjcStoreBridge.swift`, add after the `init` (line 16):
```swift
// MARK: - Task Scheduling APIs

/// Shared task scheduler instance. Cached for consistent reference.
@objc public var taskScheduler: ObjcTaskScheduler {
    lock.lock()
    defer { lock.unlock() }
    if let existing = _taskScheduler { return existing }
    let new = ObjcTaskScheduler(scheduler: store.scheduler, store: store)
    _taskScheduler = new
    return new
}
```

- [ ] **Step 3: Add scheduleTask method**

In `ObjcStoreBridge.swift`, add after `taskScheduler`:
```swift
/// Schedules a task for execution.
@objc public func scheduleTask(
    _ descriptor: ObjcTaskDescriptor,
    task: @escaping () -> Void,
    completion: ((ObjcLease) -> Void)? = nil
) -> ObjcLease {
    let lease = store.scheduleTask(
        descriptor.underlying,
        task: { task() },
        completion: completion.map { handler in
            { lease in handler(ObjcLease(underlying: lease)) }
        }
    )
    return ObjcLease(underlying: lease)
}
```

- [ ] **Step 4: Add scheduleTaskAndWait method**

In `ObjcStoreBridge.swift`, add after `scheduleTask`:
```swift
/// Schedules a task and waits for result via completion handler.
@objc public func scheduleTaskAndWait(
    _ descriptor: ObjcTaskDescriptor,
    task: @escaping () -> NSObject,
    completion: @escaping (NSObject?) -> Void
) {
    Task {
        let result = await store.scheduleTaskAndWait(
            descriptor.underlying
        ) {
            task() as NSObject
        }
        completion(result)
    }
}
```

- [ ] **Step 5: Add cancelTask and count properties**

In `ObjcStoreBridge.swift`, add after `scheduleTaskAndWait`:
```swift
/// Cancels a pending task.
@objc public func cancelTask(taskId: String) {
    store.scheduler.cancel(taskId: taskId)
}

/// Returns number of pending tasks.
@objc public var pendingTaskCount: Int {
    store.scheduler.pendingCount
}

/// Returns number of active tasks.
@objc public var activeTaskCount: Int {
    store.scheduler.activeCount
}
```

- [ ] **Step 6: Build to verify compilation**

Run: `swift build`
Expected: BUILD SUCCEEDS

- [ ] **Step 7: Commit**

```bash
git add Sources/TPCapabilityKitBridge/ObjcStoreBridge.swift
git commit -m "feat: add scheduling APIs to ObjcStoreBridge"
```

---

### Task 8: ObjC Bridge Tests

**Files:**
- Create: `Tests/TPCapabilityKitTests/TPCapabilityKitObjCTaskSchedulerTests.swift`

**Interfaces:**
- Consumes: `ObjcTaskDescriptor`, `ObjcLease`, `ObjcTaskScheduler`, `ObjcStoreBridge`
- Produces: Tests verifying ObjC bridge functionality

- [ ] **Step 1: Create test file with ObjcTaskDescriptor tests**

```swift
import Testing
import Foundation
@testable import TPCapabilityKit
@testable import TPCapabilityKitBridge

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
        
        #expect(descriptor.capabilities == ["networkAccess", "backgroundExecution"])
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
}
```

- [ ] **Step 2: Add ObjcLease tests**

```swift
struct ObjcLeaseTests {
    @Test func stateTransitions() {
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask])
        let lease = Lease(task: task)
        let objcLease = ObjcLease(underlying: lease)
        
        #expect(objcLease.state == .pending)
        
        lease.activate()
        #expect(objcLease.state == .active)
        #expect(objcLease.activatedAt != nil)
        
        lease.complete(with: "result")
        #expect(objcLease.state == .completed)
        #expect(objcLease.completedAt != nil)
        #expect(objcLease.result as? String == "result")
    }

    @Test func failureState() {
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask])
        let lease = Lease(task: task)
        let objcLease = ObjcLease(underlying: lease)
        
        lease.activate()
        struct TestError: Error {}
        lease.fail(with: TestError())
        
        #expect(objcLease.state == .failed)
    }

    @Test func underlyingProperty() {
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask])
        let lease = Lease(task: task)
        let objcLease = ObjcLease(underlying: lease)
        
        #expect(objcLease.underlying === lease)
    }
}
```

- [ ] **Step 3: Add ObjcStoreBridge scheduling tests**

```swift
struct ObjcStoreBridgeSchedulingTests {
    @Test func objcScheduleAndComplete() async {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let pluginId = "ObjcSchedCap_\(UUID().uuidString)"
        store.registerCapability(for: pluginId, capabilities: [.heavyTask])
        defer { store.unregisterCapability(for: pluginId) }
        
        let descriptor = ObjcTaskDescriptor(capabilities: ["heavyTask"])
        
        await withCheckedContinuation { continuation in
            bridge.scheduleTaskAndWait(descriptor, task: {
                NSString(string: "Result")
            }, completion: { result in
                #expect((result as? String) == "Result")
                continuation.resume()
            })
        }
    }

    @Test func objcScheduleWithoutCapability() async {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let uniqueCap = "missingCap_\(UUID().uuidString)"
        
        let descriptor = ObjcTaskDescriptor(capabilities: [uniqueCap], timeout: 0.1)
        
        await withCheckedContinuation { continuation in
            bridge.scheduleTaskAndWait(descriptor, task: {
                NSString(string: "ShouldNotRun")
            }, completion: { result in
                #expect(result == nil)
                continuation.resume()
            })
        }
    }

    @Test func objcCancelTask() async {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        let uniqueCap = "cancelCap_\(UUID().uuidString)"
        
        let descriptor = ObjcTaskDescriptor(capabilities: [uniqueCap], timeout: 5.0)
        let lease = bridge.scheduleTask(descriptor) {
            // Should not execute
        }
        
        bridge.cancelTask(taskId: descriptor.id)
        
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(lease.underlying.isTerminal)
    }

    @Test func objcPendingAndActiveCounts() {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        
        #expect(bridge.pendingTaskCount == 0)
        #expect(bridge.activeTaskCount == 0)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter ObjcTaskDescriptorTests`
Expected: ALL TESTS PASS

Run: `swift test --filter ObjcLeaseTests`
Expected: ALL TESTS PASS

Run: `swift test --filter ObjcStoreBridgeSchedulingTests`
Expected: ALL TESTS PASS

- [ ] **Step 5: Commit**

```bash
git add Tests/TPCapabilityKitTests/TPCapabilityKitObjCTaskSchedulerTests.swift
git commit -m "test: add ObjC bridge tests for TaskScheduler"
```

---

### Task 9: Protocol Tests

**Files:**
- Create: `Tests/TPCapabilityKitTests/TPCapabilityKitProtocolTests.swift`

**Interfaces:**
- Consumes: `TaskSchedulerProtocol`, `TaskScheduler`, `DynamicStore`
- Produces: Tests verifying protocol extraction and A/B testing capability

- [ ] **Step 1: Create test file with protocol conformance tests**

```swift
import Testing
import Foundation
@testable import TPCapabilityKit

struct TaskSchedulerProtocolTests {
    @Test func taskSchedulerConformsToProtocol() {
        let store = DynamicStore()
        let scheduler = TaskScheduler(store: store)
        
        // Verify TaskScheduler conforms to TaskSchedulerProtocol
        let protocolRef: any TaskSchedulerProtocol = scheduler
        #expect(protocolRef.pendingCount == 0)
    }

    @Test func dynamicStoreReturnsProtocol() {
        let store = DynamicStore()
        let scheduler: any TaskSchedulerProtocol = store.scheduler
        
        #expect(scheduler.pendingCount == 0)
    }

    @Test func customSchedulerImplementation() async {
        let store = DynamicStore()
        let mockScheduler = MockTaskScheduler(store: store)
        store.scheduler = mockScheduler
        
        let descriptor = TaskDescriptor(requiredCapabilities: [.heavyTask])
        let lease = store.scheduleTask(descriptor) { }
        
        #expect(mockScheduler.wasScheduleCalled)
        #expect(mockScheduler.lastDescriptor?.id == descriptor.id)
    }

    @Test func customSchedulerScheduleAndWait() async {
        let store = DynamicStore()
        let mockScheduler = MockTaskScheduler(store: store)
        store.scheduler = mockScheduler
        
        let descriptor = TaskDescriptor(requiredCapabilities: [.heavyTask])
        let result: String? = await store.scheduleTaskAndWait(descriptor) {
            "MockResult"
        }
        
        #expect(result == "MockResult")
        #expect(mockScheduler.wasScheduleAndWaitCalled)
    }

    @Test func customSchedulerCancel() {
        let store = DynamicStore()
        let mockScheduler = MockTaskScheduler(store: store)
        store.scheduler = mockScheduler
        
        store.scheduler.cancel(taskId: "test-id")
        
        #expect(mockScheduler.wasCancelCalled)
        #expect(mockScheduler.lastCancelledTaskId == "test-id")
    }
}

// Mock scheduler for testing
private final class MockTaskScheduler: TaskSchedulerProtocol, @unchecked Sendable {
    private let store: DynamicStore
    private let eventSubject = PassthroughSubject<TaskScheduler.SchedulerEvent, Never>()
    
    var wasScheduleCalled = false
    var wasScheduleAndWaitCalled = false
    var wasCancelCalled = false
    var lastDescriptor: TaskDescriptor?
    var lastCancelledTaskId: String?
    
    init(store: DynamicStore) {
        self.store = store
    }
    
    func schedule(
        _ task: TaskDescriptor,
        taskExecution: @escaping @Sendable () async -> Void,
        completion: ((Lease) -> Void)?,
        autoProcess: Bool
    ) -> Lease {
        wasScheduleCalled = true
        lastDescriptor = task
        let lease = Lease(task: task)
        lease.activate()
        lease.complete(with: nil)
        completion?(lease)
        return lease
    }
    
    func scheduleAndWait<T: Sendable>(
        _ task: TaskDescriptor,
        taskExecution: @escaping @Sendable () async throws -> T
    ) async -> T? {
        wasScheduleAndWaitCalled = true
        lastDescriptor = task
        return try? await taskExecution()
    }
    
    func cancel(taskId: String) {
        wasCancelCalled = true
        lastCancelledTaskId = taskId
    }
    
    var pendingCount: Int { 0 }
    var activeCount: Int { 0 }
    var events: AnyPublisher<TaskScheduler.SchedulerEvent, Never> {
        eventSubject.eraseToAnyPublisher()
    }
}
```

- [ ] **Step 2: Run tests**

Run: `swift test --filter TaskSchedulerProtocolTests`
Expected: ALL TESTS PASS

- [ ] **Step 3: Commit**

```bash
git add Tests/TPCapabilityKitTests/TPCapabilityKitProtocolTests.swift
git commit -m "test: add protocol extraction tests for TaskScheduler"
```

---

### Task 10: Final Verification

**Files:**
- None (verification only)

- [ ] **Step 1: Build project**

Run: `swift build`
Expected: BUILD SUCCEEDS

- [ ] **Step 2: Run all tests**

Run: `swift test`
Expected: ALL TESTS PASS (no failures, no timeouts)

- [ ] **Step 3: Verify no regressions**

Check that existing tests in `TPCapabilityKitSchedulerTests.swift` still pass:
Run: `swift test --filter TaskSchedulerTests`
Expected: ALL TESTS PASS

- [ ] **Step 4: Commit all changes**

```bash
git add -A
git commit -m "chore: final verification for ObjC bridge and protocol extraction"
```

- [ ] **Step 5: Push to remote**

```bash
git push
```

---

## File Changes Summary

### New Files
| File | Module | Description |
|------|--------|-------------|
| `TaskSchedulerProtocol.swift` | TPCapabilityKit | Protocol definition |
| `ObjcTaskDescriptor.swift` | TPCapabilityKitBridge | ObjC wrapper for TaskDescriptor |
| `ObjcLease.swift` | TPCapabilityKitBridge | ObjC wrapper for Lease |
| `ObjcTaskScheduler.swift` | TPCapabilityKitBridge | ObjC wrapper for TaskSchedulerProtocol |
| `TPCapabilityKitObjCTaskSchedulerTests.swift` | Tests | ObjC bridge tests |
| `TPCapabilityKitProtocolTests.swift` | Tests | Protocol extraction tests |

### Modified Files
| File | Changes |
|------|---------|
| `DynamicStore.swift` | Scheduler property type changed to `any TaskSchedulerProtocol` |
| `TaskScheduler.swift` | Add `TaskSchedulerProtocol` conformance |
| `Lease.swift` | Add `rawValue` extension to `Lease.State` |
| `ObjcStoreBridge.swift` | Add scheduling APIs |

## Backward Compatibility

- All existing APIs remain unchanged
- `DynamicStore.scheduler` type change is source-compatible (any P vs concrete)
- `DynamicStore.scheduler` setter now accepts any `TaskSchedulerProtocol` conformance
- `scheduleTask` and `scheduleTaskAndWait` methods unchanged
- Existing tests pass without modification
