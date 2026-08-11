# TaskScheduler ObjC Bridge & Protocol Extraction

**Date:** 2026-08-11
**Status:** Approved
**Approach:** Protocol + ObjC Wrapper Classes

## Objective

1. Extract `TaskSchedulerProtocol` to enable A/B testing of different scheduling implementations
2. Add full ObjC bridge for TaskScheduler, allowing both ObjC and Swift apps to use the module

## Architecture Overview

```
TPCapabilityKit (Swift):
  - TaskSchedulerProtocol (schedule, scheduleAndWait, cancel, pendingCount, activeCount, events)
  - TaskScheduler (concrete implementation, conforms to protocol)
  - DynamicStore.scheduler: any TaskSchedulerProtocol (protocol property)

TPCapabilityKitBridge (ObjC):
  - ObjcTaskDescriptor: NSObject wrapper for TaskDescriptor
  - ObjcLease: NSObject wrapper for Lease
  - ObjcTaskScheduler: NSObject wrapper for TaskSchedulerProtocol
  - ObjcStoreBridge: scheduler property + scheduling methods
```

## Design Details

### 1. TaskSchedulerProtocol

**Location:** `Sources/TPCapabilityKit/TaskSchedulerProtocol.swift`

```swift
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

**Key decisions:**
- Protocol inherits `AnyObject, Sendable` — reference type + thread-safe
- `schedule` has `autoProcess` parameter — backward compatible
- `events` publisher type reuses `TaskScheduler.SchedulerEvent` — no duplication

### 2. DynamicStore Integration

**Location:** `Sources/TPCapabilityKit/DynamicStore.swift`

```swift
extension DynamicStore {
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
}
```

**Key decisions:**
- `scheduler` property type is `any TaskSchedulerProtocol` — protocol-based access
- `_scheduler` backing store holds `any TaskSchedulerProtocol` — flexible
- Setter casts to `TaskScheduler` — backward compatible for internal usage
- Lazy initialization preserved — no breaking changes

**Backward compatibility:**
- `DynamicStore.shared.scheduler` works as before
- Can set custom implementation: `store.scheduler = MyCustomScheduler(store: store)`
- `scheduleTask` and `scheduleTaskAndWait` methods unchanged

### 3. ObjC Wrapper Classes

#### ObjcTaskDescriptor

**Location:** `Sources/TPCapabilityKitBridge/ObjcTaskDescriptor.swift`

```swift
@objc(TPTaskDescriptor)
public final class ObjcTaskDescriptor: NSObject {
    @objc public let id: String
    @objc public let priority: Int  // TaskPriority.rawValue
    @objc public let timeout: TimeInterval
    @objc public let maxRetries: Int
    @objc public let capabilities: [String]
    @objc public let metadata: [String: String]

    public let underlying: TaskDescriptor

    @objc public init(
        capabilities: [String],
        priority: Int = 2,  // .normal
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

#### ObjcLease

**Location:** `Sources/TPCapabilityKitBridge/ObjcLease.swift`

```swift
@objc(TPLease)
public final class ObjcLease: NSObject {
    @objc public enum State: Int {
        case pending = 0
        case active = 1
        case completed = 2
        case failed = 3
        case expired = 4
    }

    @objc public let taskId: String
    @objc public private(set) var state: State
    @objc public let createdAt: Date
    @objc public private(set) var activatedAt: Date?
    @objc public private(set) var completedAt: Date?
    @objc public private(set) var result: Any?
    @objc public private(set) var retryCount: Int

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

**Key decisions:**
- `ObjcTaskDescriptor` wraps `TaskDescriptor` — underlying property accesses Swift object
- `ObjcLease` wraps `Lease` — state is `Int` enum for ObjC compatibility
- Capabilities use `[String]` instead of `Set<Capability>` — ObjC doesn't support Set
- Priority uses `Int` instead of enum — ObjC enum support is limited

### 4. ObjcStoreBridge Additions

**Location:** `Sources/TPCapabilityKitBridge/ObjcStoreBridge.swift`

```swift
extension ObjcStoreBridge {
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
    private var _taskScheduler: ObjcTaskScheduler?

    // Add to existing class properties:
    private let lock = NSLock()
```

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
}
```

#### ObjcTaskScheduler (New class)

**Location:** `Sources/TPCapabilityKitBridge/ObjcTaskScheduler.swift`

```swift
@objc(TPTaskScheduler)
public final class ObjcTaskScheduler: NSObject, @unchecked Sendable {
    private let scheduler: any TaskSchedulerProtocol
    private let store: DynamicStore

    internal init(scheduler: any TaskSchedulerProtocol, store: DynamicStore) {
        self.scheduler = scheduler
        self.store = store
        super.init()
    }

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

    @objc public func cancel(taskId: String) {
        scheduler.cancel(taskId: taskId)
    }

    @objc public var pendingCount: Int { scheduler.pendingCount }
    @objc public var activeCount: Int { scheduler.activeCount }
}
```

**Key decisions:**
- `ObjcTaskScheduler` wraps protocol, not concrete class — A/B testing support
- Completion handlers run on main queue — standard ObjC pattern
- `scheduleAndWait` uses `Task {}` to bridge async → callback
- `ObjcStoreBridge.taskScheduler` caches wrapper for consistent reference
- `ObjcStoreBridge` needs `NSLock` property for thread-safe lazy initialization

### 5. Testing Strategy

#### New Test Files

**TPCapabilityKitObjCTaskSchedulerTests.swift:**
- ObjcTaskDescriptor: init with capabilities, priority, timeout
- ObjcLease: state transitions, underlying property
- ObjcTaskScheduler: schedule, cancel, pendingCount, activeCount
- ObjcStoreBridge scheduling APIs: scheduleTask, scheduleTaskAndWait, cancelTask
- pendingTaskCount/activeTaskCount: returns correct counts

**TPCapabilityKitProtocolTests.swift:**
- TaskScheduler conforms to TaskSchedulerProtocol
- DynamicStore.scheduler returns TaskSchedulerProtocol
- Custom scheduler implementation works via DynamicStore
- Replace scheduler with mock implementation
- Verify custom scheduler is used for scheduling
- Verify fallback to default scheduler

#### Test Patterns

```swift
// ObjC scheduling test pattern
@Test func objcScheduleAndComplete() async {
    let store = DynamicStore()
    let bridge = ObjcStoreBridge(store: store)
    let pluginId = "ObjcSchedCap_\(UUID().uuidString)"
    store.registerCapability(for: pluginId, capabilities: [.heavyTask])
    
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

// Protocol test pattern
@Test func customSchedulerImplementation() {
    let store = DynamicStore()
    let mockScheduler = MockTaskScheduler(store: store)
    store.scheduler = mockScheduler
    
    let descriptor = TaskDescriptor(requiredCapabilities: [.heavyTask])
    let lease = store.scheduleTask(descriptor) { }
    
    #expect(mockScheduler.wasScheduleCalled)
}
```

#### Existing Tests Updates

- `TPCapabilityKitSchedulerTests.swift` — unchanged, tests concrete implementation
- `TPCapabilityKitSchedulerIntegrationTests.swift` — add ObjC bridge integration tests
- `TPCapabilityKitObjCBridgeTests.swift` — add scheduling tests

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
| `ObjcStoreBridge.swift` | Add scheduling APIs |
| `TPCapabilityKitSchedulerIntegrationTests.swift` | Add ObjC integration tests |
| `TPCapabilityKitObjCBridgeTests.swift` | Add scheduling tests |

## Backward Compatibility

- All existing APIs remain unchanged
- `DynamicStore.scheduler` type change is source-compatible (any P vs concrete)
- `DynamicStore.scheduler` setter now accepts any `TaskSchedulerProtocol` conformance
- `scheduleTask` and `scheduleTaskAndWait` methods unchanged
- Existing tests pass without modification
