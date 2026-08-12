# ObjC Bridge Queue Parameter & Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add configurable queue parameter to ObjC bridge observer/task APIs (default: main queue) and remove duplicate `isCapabilityAvailable` method.

**Architecture:** ObjC bridge APIs that currently hardcode `DispatchQueue.main` will accept an optional `queue` parameter. Passing `nil` or omitting the parameter defaults to main queue. The duplicate `isCapabilityAvailable` method is removed in favor of `queryCapability`.

**Tech Stack:** Swift 6.1, Combine, Foundation, Objective-C interop

## Global Constraints

- Swift 6.1, strict concurrency enabled
- Single `NSLock` protects all mutable state in `DynamicStore`
- `CurrentValueSubject.send()` is thread-safe by Combine guarantee
- Tests use Swift Testing framework (not XCTest)
- No external dependencies

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `Sources/Bridge/ObjcStoreBridge.swift` | Modify | Add queue parameter to 3 APIs, remove `isCapabilityAvailable` |
| `Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift` | Modify | Update tests for new API signatures, add queue-specific tests |

---

### Task 1: Add queue parameter to `subscribe(pluginId:observer:)`

**Files:**
- Modify: `Sources/Bridge/ObjcStoreBridge.swift:42-54`
- Modify: `Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift:97-115`

**Interfaces:**
- Consumes: `DynamicStore.observeState(pluginId:type:) -> AnyPublisher<T, Never>`
- Produces: `ObjcStoreBridge.subscribe(pluginId:queue:observer:) -> ObjcCancellable`

- [ ] **Step 1: Update `subscribe` method signature and implementation**

```swift
// Sources/Bridge/ObjcStoreBridge.swift:42-54
/// Subscribes to state updates for a plugin, delivering callbacks on the specified queue.
/// - Parameters:
///   - pluginId: Unique identifier of the plugin.
///   - queue: Queue for callback delivery. Pass `nil` for main queue.
///   - observer: Closure invoked with updated state on specified queue.
/// - Returns: An `ObjcCancellable` token to manage subscription lifecycle.
@objc public func subscribe(
    pluginId: String,
    queue: DispatchQueue? = nil,
    observer: @escaping (NSObject?) -> Void
) -> ObjcCancellable {
    let targetQueue = queue ?? .main
    let cancellable = store.observeState(pluginId: pluginId, type: NSObject.self)
        .receive(on: targetQueue)
        .sink { state in
            observer(state)
        }
    return ObjcCancellable(cancellable)
}
```

- [ ] **Step 2: Update existing test to use new signature**

```swift
// Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift:97-115
@Test func objcSubscribeAndCancel() {
    let bridge = ObjcStoreBridge.shared
    let pluginId = "SubPlugin_\(UUID().uuidString)"
    var receivedState: NSObject?
    
    let cancellable = bridge.subscribe(pluginId: pluginId, queue: nil) { state in
        receivedState = state
    }
    
    bridge.updateState(pluginId: pluginId, newState: NSString(string: "SubValue"))
    
    let deadline = Date().addingTimeInterval(0.2)
    while receivedState == nil && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    
    #expect(receivedState as? String == "SubValue")
    cancellable.cancel()
}
```

- [ ] **Step 3: Run tests to verify**

Run: `swift test --filter objcSubscribeAndCancel`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add Sources/Bridge/ObjcStoreBridge.swift Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift
git commit -m "feat: add queue parameter to ObjC subscribe API"
```

---

### Task 2: Add queue parameter to `subscribeCapability(_:observer:)`

**Files:**
- Modify: `Sources/Bridge/ObjcStoreBridge.swift:81-92`
- Modify: `Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift:252-272`

**Interfaces:**
- Consumes: `DynamicStore.observeCapability(_:) -> AnyPublisher<Bool, Never>`
- Produces: `ObjcStoreBridge.subscribeCapability(_:queue:observer:) -> ObjcCancellable`

- [ ] **Step 1: Update `subscribeCapability` method signature and implementation**

```swift
// Sources/Bridge/ObjcStoreBridge.swift:81-92
/// Subscribes to capability availability updates, delivering callbacks on the specified queue.
/// - Parameters:
///   - capability: Capability string identifier to observe.
///   - queue: Queue for callback delivery. Pass `nil` for main queue.
///   - observer: Closure invoked with capability availability on specified queue.
/// - Returns: An `ObjcCancellable` token to manage subscription lifecycle.
@objc public func subscribeCapability(
    _ capability: String,
    queue: DispatchQueue? = nil,
    observer: @escaping (Bool) -> Void
) -> ObjcCancellable {
    let targetQueue = queue ?? .main
    let cap = Capability(rawValue: capability)
    let cancellable = store.observeCapability(cap)
        .receive(on: targetQueue)
        .sink { observer($0) }
    return ObjcCancellable(cancellable)
}
```

- [ ] **Step 2: Update existing test to use new signature**

```swift
// Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift:252-272
@Test func objcCapabilitySubscribe() {
    let bridge = ObjcStoreBridge.shared
    let pluginId = "ObjcCapSubscribePlugin_\(UUID().uuidString)"
    let uniqueCap = "uniqueCap_\(UUID().uuidString)"
    var receivedValue: Bool?
    
    bridge.registerCapability(for: pluginId, capabilities: [uniqueCap])
    defer { bridge.unregisterCapability(for: pluginId) }
    
    let cancellable = bridge.subscribeCapability(uniqueCap, queue: nil) { value in
        receivedValue = value
    }
    
    let deadline = Date().addingTimeInterval(0.2)
    while receivedValue != true && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    
    #expect(receivedValue == true)
    cancellable.cancel()
}
```

- [ ] **Step 3: Run tests to verify**

Run: `swift test --filter objcCapabilitySubscribe`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add Sources/Bridge/ObjcStoreBridge.swift Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift
git commit -m "feat: add queue parameter to ObjC subscribeCapability API"
```

---

### Task 3: Add queue parameter to `runTaskWhenAvailable(capability:timeout:task:completion:)`

**Files:**
- Modify: `Sources/Bridge/ObjcStoreBridge.swift:129-162`
- Modify: `Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift:679-707`

**Interfaces:**
- Consumes: `DynamicStore.observeCapability(_:) -> AnyPublisher<Bool, Never>`, `ObjcStoreBridge.runTaskIfAvailable(capability:task:) -> NSObject?`
- Produces: `ObjcStoreBridge.runTaskWhenAvailable(capability:timeout:queue:task:completion:)`

- [ ] **Step 1: Update `runTaskWhenAvailable` method signature and implementation**

```swift
// Sources/Bridge/ObjcStoreBridge.swift:129-162
/// Runs a task when the required capability becomes available, with a timeout.
/// Delivers the result on the specified queue.
/// - Parameters:
///   - capability: Capability string identifier required to run the task.
///   - timeout: Maximum seconds to wait for the capability.
///   - queue: Queue for callback delivery. Pass `nil` for main queue.
///   - task: The task closure to execute. Must return an NSObject.
///   - completion: Called on specified queue with the result, or nil if timeout.
@objc public func runTaskWhenAvailable(
    capability: String,
    timeout: TimeInterval,
    queue: DispatchQueue? = nil,
    task: @escaping () -> NSObject,
    completion: @escaping (NSObject?) -> Void
) {
    let targetQueue = queue ?? .main
    let cap = Capability(rawValue: capability)
    let box = ObserverBox()
    
    // Subscribe to capability, run task when available
    box.cancellable = store.observeCapability(cap)
        .receive(on: targetQueue)
        .sink { [weak self] isAvailable in
            guard isAvailable, let self = self, box.isActive else { return }
            box.deactivate()
            let result = self.runTaskIfAvailable(capability: capability, task: task)
            completion(result)
        }
    
    // Timeout
    box.timeoutItem = DispatchWorkItem {
        guard box.isActive else { return }
        box.deactivate()
        completion(nil)
    }
    targetQueue.asyncAfter(deadline: .now() + timeout, execute: box.timeoutItem!)
}
```

- [ ] **Step 2: Update existing tests to use new signature**

```swift
// Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift:679-707
@Test func objcRunTaskWhenAvailableAlreadyAvailable() async {
    let bridge = ObjcStoreBridge.shared
    let pluginId = "ObjcWaitCap_\(UUID().uuidString)"
    bridge.registerCapability(for: pluginId, capabilities: ["networkAccess"])
    defer { bridge.unregisterCapability(for: pluginId) }

    await withCheckedContinuation { continuation in
        bridge.runTaskWhenAvailable(capability: "networkAccess", timeout: 1.0, queue: nil, task: {
            return NSString(string: "ImmediateObjC")
        }, completion: { result in
            #expect((result as? String) == "ImmediateObjC")
            continuation.resume()
        })
    }
}

@Test func objcRunTaskWhenAvailableTimesOut() async {
    let bridge = ObjcStoreBridge.shared
    let uniqueCap = "timeoutCapObjc_\(UUID().uuidString)"

    await withCheckedContinuation { continuation in
        bridge.runTaskWhenAvailable(capability: uniqueCap, timeout: 0.1, queue: nil, task: {
            NSString(string: "ShouldNotRun")
        }, completion: { result in
            #expect(result == nil)
            continuation.resume()
        })
    }
}
```

- [ ] **Step 3: Run tests to verify**

Run: `swift test --filter objcRunTaskWhenAvailable`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add Sources/Bridge/ObjcStoreBridge.swift Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift
git commit -m "feat: add queue parameter to ObjC runTaskWhenAvailable API"
```

---

### Task 4: Remove duplicate `isCapabilityAvailable` method

**Files:**
- Modify: `Sources/Bridge/ObjcStoreBridge.swift:164-170`
- Modify: `Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift:709-718`

**Interfaces:**
- Consumes: `ObjcStoreBridge.queryCapability(_:) -> Bool`
- Produces: Removes `ObjcStoreBridge.isCapabilityAvailable(_:) -> Bool`

- [ ] **Step 1: Remove `isCapabilityAvailable` method**

Delete from `Sources/Bridge/ObjcStoreBridge.swift:164-170`:

```swift
// DELETE THIS METHOD:
/// Checks whether a capability is currently available.
/// - Parameter capability: Capability string identifier.
/// - Returns: true if the capability is registered.
@objc public func isCapabilityAvailable(_ capability: String) -> Bool {
    let cap = Capability(rawValue: capability)
    return store.queryCapability(cap)
}
```

- [ ] **Step 2: Update test to use `queryCapability` instead**

```swift
// Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift:709-718
@Test func objcQueryCapability() {
    let bridge = ObjcStoreBridge.shared
    let pluginId = "ObjcQueryCap_\(UUID().uuidString)"
    let uniqueCap = "queryCap_\(UUID().uuidString)"

    bridge.registerCapability(for: pluginId, capabilities: [uniqueCap])
    defer { bridge.unregisterCapability(for: pluginId) }

    #expect(bridge.queryCapability(uniqueCap) == true)
}
```

- [ ] **Step 3: Run tests to verify**

Run: `swift test --filter objcQueryCapability`
Expected: PASS

- [ ] **Step 4: Run full test suite**

Run: `swift test`
Expected: All 50 tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/Bridge/ObjcStoreBridge.swift Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift
git commit -m "refactor: remove duplicate isCapabilityAvailable, use queryCapability"
```

---

### Task 5: Add tests for non-default queue delivery

**Files:**
- Modify: `Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift`

**Interfaces:**
- Consumes: `ObjcStoreBridge.subscribe(pluginId:queue:observer:)`, `ObjcStoreBridge.subscribeCapability(_:queue:observer:)`
- Produces: New test methods verifying background queue delivery

- [ ] **Step 1: Add test for subscribe with custom queue**

```swift
// Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift (add after objcSubscribeAndCancel)
@Test func objcSubscribeOnCustomQueue() {
    let bridge = ObjcStoreBridge.shared
    let pluginId = "CustomQueuePlugin_\(UUID().uuidString)"
    var receivedState: NSObject?
    let expectation = expectation(description: "Receive on custom queue")
    
    let customQueue = DispatchQueue(label: "test.custom.queue")
    let cancellable = bridge.subscribe(pluginId: pluginId, queue: customQueue) { state in
        receivedState = state
        expectation.fulfill()
    }
    
    bridge.updateState(pluginId: pluginId, newState: NSString(string: "CustomQueueValue"))
    
    wait(for: [expectation], timeout: 1.0)
    #expect(receivedState as? String == "CustomQueueValue")
    
    // Verify callback ran on custom queue (not main)
    // The expectation.fulfill() was called from the custom queue
    
    cancellable.cancel()
}
```

- [ ] **Step 2: Add test for subscribeCapability with custom queue**

```swift
// Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift (add after objcCapabilitySubscribe)
@Test func objcCapabilitySubscribeOnCustomQueue() {
    let bridge = ObjcStoreBridge.shared
    let pluginId = "CustomQueueCapPlugin_\(UUID().uuidString)"
    let uniqueCap = "customQueueCap_\(UUID().uuidString)"
    var receivedValue: Bool?
    let expectation = expectation(description: "Receive capability on custom queue")
    
    bridge.registerCapability(for: pluginId, capabilities: [uniqueCap])
    defer { bridge.unregisterCapability(for: pluginId) }
    
    let customQueue = DispatchQueue(label: "test.custom.cap.queue")
    let cancellable = bridge.subscribeCapability(uniqueCap, queue: customQueue) { value in
        receivedValue = value
        expectation.fulfill()
    }
    
    wait(for: [expectation], timeout: 1.0)
    #expect(receivedValue == true)
    
    cancellable.cancel()
}
```

- [ ] **Step 3: Run new tests to verify**

Run: `swift test --filter objcSubscribeOnCustomQueue`
Run: `swift test --filter objcCapabilitySubscribeOnCustomQueue`
Expected: Both PASS

- [ ] **Step 4: Run full test suite**

Run: `swift test`
Expected: All 52 tests PASS (50 existing + 2 new)

- [ ] **Step 5: Commit**

```bash
git add Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift
git commit -m "test: add queue-specific tests for ObjC bridge observer APIs"
```

---

## Summary

| Task | Description | APIs Changed |
|------|-------------|--------------|
| 1 | Add queue to subscribe | `subscribe(pluginId:queue:observer:)` |
| 2 | Add queue to subscribeCapability | `subscribeCapability(_:queue:observer:)` |
| 3 | Add queue to runTaskWhenAvailable | `runTaskWhenAvailable(capability:timeout:queue:task:completion:)` |
| 4 | Remove duplicate | Delete `isCapabilityAvailable` |
| 5 | Add queue tests | New test methods |

**Backward Compatibility:** All new queue parameters have default value `nil` (which defaults to main queue), so existing callers continue to work without changes.
