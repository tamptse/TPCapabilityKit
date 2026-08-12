# Code Quality Improvements Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve code quality across the codebase: thread safety, API completeness, naming consistency, test isolation, and test organization.

**Architecture:** 5 targeted improvements, each independently testable.

**Tech Stack:** Swift 6.1, Combine, Foundation, Objective-C interop

## Global Constraints

- Swift 6.1, strict concurrency enabled
- Single `NSLock` protects all mutable state in `DynamicStore`
- Tests use Swift Testing framework (not XCTest)
- No external dependencies

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `Sources/Bridge/ObjcStoreBridge.swift` | Modify | Fix ObserverBox, add hasPlugin/observeAllCapabilities, rename runTaskIfAvailable |
| `Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift` | Modify | Update tests for renamed API, fix benchmark isolation |
| `Tests/ZSharedStateStoreTests/ZSharedStateStoreCoreTests.swift` | Create | Core state management tests |
| `Tests/ZSharedStateStoreTests/ZSharedStateStoreCapabilityTests.swift` | Create | Capability registry tests |
| `Tests/ZSharedStateStoreTests/ZSharedStateStoreObjCBridgeTests.swift` | Create | ObjC bridge tests |
| `Tests/ZSharedStateStoreTests/ZSharedStateStoreTaskTests.swift` | Create | Task execution tests |
| `Tests/ZSharedStateStoreTests/ZSharedStateStorePerformanceTests.swift` | Create | Performance benchmarks |

---

### Task 1: Fix ObserverBox thread safety

**Files:**
- Modify: `Sources/Bridge/ObjcStoreBridge.swift:197-217`

**Interfaces:**
- Consumes: None
- Produces: Thread-safe `ObserverBox.deactivate()`

- [ ] **Step 1: Move cancellation inside lock**

```swift
// Sources/Bridge/ObjcStoreBridge.swift:197-217
/// Holds cancellable and timeout for runTaskWhenAvailable.
private final class ObserverBox {
    var cancellable: AnyCancellable?
    var timeoutItem: DispatchWorkItem?
    private let lock = NSLock()
    private var _active = true
    
    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _active
    }
    
    func deactivate() {
        lock.lock()
        let wasActive = _active
        _active = false
        let cancellableToCancel = cancellable
        let timeoutToCancel = timeoutItem
        cancellable = nil
        timeoutItem = nil
        lock.unlock()
        
        guard wasActive else { return }
        cancellableToCancel?.cancel()
        timeoutToCancel?.cancel()
    }
}
```

- [ ] **Step 2: Run tests to verify**

Run: `swift test`
Expected: All tests PASS

- [ ] **Step 3: Commit**

```bash
git add Sources/Bridge/ObjcStoreBridge.swift
git commit -m "fix: ObserverBox thread safety - move cancellation inside lock"
```

---

### Task 2: Add hasPlugin to ObjC bridge

**Files:**
- Modify: `Sources/Bridge/ObjcStoreBridge.swift:179`
- Modify: `Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift`

**Interfaces:**
- Consumes: `DynamicStore.hasPlugin(id:) -> Bool`
- Produces: `ObjcStoreBridge.hasPlugin(id:) -> Bool`

- [ ] **Step 1: Add hasPlugin method**

```swift
// Sources/Bridge/ObjcStoreBridge.swift (add after queryAllCapabilities)
/// Checks whether a plugin is registered (has state or capabilities).
/// - Parameter pluginId: Unique identifier of the plugin.
/// - Returns: `true` if the plugin has state or capabilities registered.
@objc public func hasPlugin(id pluginId: String) -> Bool {
    return store.hasPlugin(id: pluginId)
}
```

- [ ] **Step 2: Add test**

```swift
// Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift (add after objcQueryCapability)
@Test func objcHasPlugin() {
    let bridge = ObjcStoreBridge.shared
    let pluginId = "ObjcHasPlugin_\(UUID().uuidString)"
    
    #expect(bridge.hasPlugin(id: pluginId) == false)
    
    bridge.registerCapability(for: pluginId, capabilities: ["heavyTask"])
    #expect(bridge.hasPlugin(id: pluginId) == true)
    
    bridge.unregisterCapability(for: pluginId)
    #expect(bridge.hasPlugin(id: pluginId) == false)
}
```

- [ ] **Step 3: Run tests to verify**

Run: `swift test --filter objcHasPlugin`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add Sources/Bridge/ObjcStoreBridge.swift Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift
git commit -m "feat: add hasPlugin to ObjC bridge"
```

---

### Task 3: Add observeAllCapabilities to ObjC bridge

**Files:**
- Modify: `Sources/Bridge/ObjcStoreBridge.swift:179`
- Modify: `Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift`

**Interfaces:**
- Consumes: `DynamicStore.observeAllCapabilities() -> AnyPublisher<[String: Set<Capability>], Never>`
- Produces: `ObjcStoreBridge.observeAllCapabilities(queue:observer:) -> ObjcCancellable`

- [ ] **Step 1: Add observeAllCapabilities method**

```swift
// Sources/Bridge/ObjcStoreBridge.swift (add after queryAllCapabilities)
/// Reactively observes capabilities changes across all plugins, delivering callbacks on the specified queue.
/// - Parameters:
///   - queue: Queue for callback delivery. Pass `nil` for main queue.
///   - observer: Closure invoked with capabilities dictionary on specified queue.
/// - Returns: An `ObjcCancellable` token to manage subscription lifecycle.
@objc public func observeAllCapabilities(
    queue: DispatchQueue? = nil,
    observer: @escaping ([String: [String]]) -> Void
) -> ObjcCancellable {
    let targetQueue = queue ?? .main
    let cancellable = store.observeAllCapabilities()
        .map { allCaps in
            var result: [String: [String]] = [:]
            for (pluginId, caps) in allCaps {
                result[pluginId] = caps.map { $0.rawValue }
            }
            return result
        }
        .receive(on: targetQueue)
        .sink { observer($0) }
    return ObjcCancellable(cancellable)
}
```

- [ ] **Step 2: Add test**

```swift
// Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift (add after objcHasPlugin)
@Test func objcObserveAllCapabilities() {
    let bridge = ObjcStoreBridge.shared
    let pluginId = "ObjcObserveAllCap_\(UUID().uuidString)"
    var receivedCaps: [String: [String]]?
    let semaphore = DispatchSemaphore(value: 0)
    
    let cancellable = bridge.observeAllCapabilities { caps in
        receivedCaps = caps
        semaphore.signal()
    }
    
    bridge.registerCapability(for: pluginId, capabilities: ["heavyTask"])
    _ = semaphore.wait(timeout: .now() + 1.0)
    
    #expect(receivedCaps?[pluginId]?.contains("heavyTask") == true)
    
    cancellable.cancel()
    bridge.unregisterCapability(for: pluginId)
}
```

- [ ] **Step 3: Run tests to verify**

Run: `swift test --filter objcObserveAllCapabilities`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add Sources/Bridge/ObjcStoreBridge.swift Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift
git commit -m "feat: add observeAllCapabilities to ObjC bridge"
```

---

### Task 4: Rename runTaskIfAvailable to runTask

**Files:**
- Modify: `Sources/Bridge/ObjcStoreBridge.swift:127-139`
- Modify: `Sources/Bridge/ObjcStoreBridge.swift:166`
- Modify: `Sources/Sample/ZSharedStateStoreSample.swift`
- Modify: `Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift`

**Interfaces:**
- Consumes: None
- Produces: `ObjcStoreBridge.runTask(capability:task:) -> NSObject?`

- [ ] **Step 1: Rename method**

```swift
// Sources/Bridge/ObjcStoreBridge.swift:127-139
/// Runs a task immediately if the required capability is available.
/// - Parameters:
///   - capability: Capability string identifier required to run the task.
///   - task: The task closure to execute. Must return an NSObject.
/// - Returns: The task result, or nil if capability is not available.
@objc public func runTask(
    capability: String,
    task: () -> NSObject
) -> NSObject? {
    let cap = Capability(rawValue: capability)
    guard store.queryCapability(cap) else { return nil }
    return task()
}
```

- [ ] **Step 2: Update internal reference**

```swift
// Sources/Bridge/ObjcStoreBridge.swift:166
let result = self.runTask(capability: capability, task: task)
```

- [ ] **Step 3: Update sample**

```swift
// Sources/Sample/ZSharedStateStoreSample.swift
// Find and replace runTaskIfAvailable with runTask
```

- [ ] **Step 4: Update tests**

```swift
// Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift
// Find and replace runTaskIfAvailable with runTask
```

- [ ] **Step 5: Run tests to verify**

Run: `swift test`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/Bridge/ObjcStoreBridge.swift Sources/Sample/ZSharedStateStoreSample.swift Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift
git commit -m "refactor: rename runTaskIfAvailable to runTask for consistency"
```

---

### Task 5: Fix performance test isolation

**Files:**
- Modify: `Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift:721-933`

**Interfaces:**
- Consumes: None
- Produces: Isolated benchmark tests

- [ ] **Step 1: Update benchmark tests to use fresh instances**

```swift
// Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift
// Replace DynamicStore.shared with DynamicStore() in all benchmark tests
// Example:
@Test func benchmarkSwiftRegister() {
    let store = DynamicStore()  // Changed from DynamicStore.shared
    let iterations = 20_000
    // ... rest of test
}
```

- [ ] **Step 2: Run tests to verify**

Run: `swift test`
Expected: All tests PASS

- [ ] **Step 3: Commit**

```bash
git add Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift
git commit -m "fix: use fresh DynamicStore instances in benchmark tests"
```

---

### Task 6: Split test file

**Files:**
- Create: `Tests/ZSharedStateStoreTests/ZSharedStateStoreCoreTests.swift`
- Create: `Tests/ZSharedStateStoreTests/ZSharedStateStoreCapabilityTests.swift`
- Create: `Tests/ZSharedStateStoreTests/ZSharedStateStoreObjCBridgeTests.swift`
- Create: `Tests/ZSharedStateStoreTests/ZSharedStateStoreTaskTests.swift`
- Create: `Tests/ZSharedStateStoreTests/ZSharedStateStorePerformanceTests.swift`
- Delete: `Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift`

**Interfaces:**
- Consumes: None
- Produces: Organized test files

- [ ] **Step 1: Create core tests file**

```swift
// Tests/ZSharedStateStoreTests/ZSharedStateStoreCoreTests.swift
import Testing
@testable import ZSharedStateStore

struct ZSharedStateStoreCoreTests {
    // Move core state management tests here:
    // - swiftCoreRegisterAndUpdateState
    // - orderAgnosticSubscription
    // - typeCastingSafety
    // - emptyPluginIdHandling
    // - getStateNonExistentPlugin
    // - registeredPluginIdsAfterRegisterAndUnregister
    // - hasPluginIdTrueAndFalse
    // - removeStateStopsFutureObservations
    // - concurrentStateReadWrite
    // - unregisterPlugin
}
```

- [ ] **Step 2: Create capability tests file**

```swift
// Tests/ZSharedStateStoreTests/ZSharedStateStoreCapabilityTests.swift
import Testing
@testable import ZSharedStateStore

struct ZSharedStateStoreCapabilityTests {
    // Move capability tests here:
    // - capabilityAutoRegistration
    // - capabilityManualRegistration
    // - capabilityUnregistration
    // - capabilityQueryByPlugin
    // - capabilityQueryAll
    // - capabilityReactiveObservation
    // - capabilityConcurrentAccess
    // - capabilityInitFromRawValue
    // - observeAllCapabilitiesReactive
    // - unregisterCapabilitySoleProviderQueryReturnsFalse
    // - registerCapabilityReplacesOldCapabilities
}
```

- [ ] **Step 3: Create ObjC bridge tests file**

```swift
// Tests/ZSharedStateStoreTests/ZSharedStateStoreObjCBridgeTests.swift
import Testing
@testable import ZSharedStateStore
@testable import ZSharedStateStoreBridge

struct ZSharedStateStoreObjCBridgeTests {
    // Move ObjC bridge tests here:
    // - objcBridge
    // - objcSubscribeAndCancel
    // - objcSubscribeOnCustomQueue
    // - objcCapabilityBridge
    // - objcCapabilitySubscribe
    // - objcCapabilitySubscribeOnCustomQueue
    // - objcSubscribeCancelStopsDelivery
    // - objcRunTaskIfAvailableWhenAvailable
    // - objcRunTaskIfAvailableWhenNotAvailable
    // - objcRunTaskWhenAvailableAlreadyAvailable
    // - objcRunTaskWhenAvailableTimesOut
    // - objcQueryCapability
    // - objcHasPlugin
    // - objcObserveAllCapabilities
}
```

- [ ] **Step 4: Create task tests file**

```swift
// Tests/ZSharedStateStoreTests/ZSharedStateStoreTaskTests.swift
import Testing
@testable import ZSharedStateStore

struct ZSharedStateStoreTaskTests {
    // Move task execution tests here:
    // - runTaskWhenCapabilityAvailable
    // - runTaskWhenCapabilityNotAvailable
    // - runTaskPassesArgumentsAndReturnsValue
    // - runTaskWhenAvailableAlreadyAvailable
    // - runTaskWhenAvailableWaitsForCapability
    // - runTaskWhenAvailableTimesOut
    // - runTaskCapabilityRevokedAfterRegister
    // - runTaskMultipleCapabilities
    // - runTaskConcurrentAccess
}
```

- [ ] **Step 5: Create performance tests file**

```swift
// Tests/ZSharedStateStoreTests/ZSharedStateStorePerformanceTests.swift
import Testing
@testable import ZSharedStateStore
@testable import ZSharedStateStoreBridge

@Suite struct ZSharedStateStorePerformanceTests {
    // Move all benchmark tests here
}
```

- [ ] **Step 6: Delete original test file**

```bash
rm Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift
```

- [ ] **Step 7: Run tests to verify**

Run: `swift test`
Expected: All tests PASS

- [ ] **Step 8: Commit**

```bash
git add Tests/ZSharedStateStoreTests/
git commit -m "refactor: split test file into organized modules"
```

---

## Summary

| Task | Description | Impact |
|------|-------------|--------|
| 1 | Fix ObserverBox thread safety | Thread safety |
| 2 | Add hasPlugin to ObjC bridge | API completeness |
| 3 | Add observeAllCapabilities to ObjC bridge | API completeness |
| 4 | Rename runTaskIfAvailable to runTask | Naming consistency |
| 5 | Fix performance test isolation | Test reliability |
| 6 | Split test file | Code organization |

**Backward Compatibility:** Task 4 (rename) is a breaking change for ObjC callers. Consider deprecation if needed.
