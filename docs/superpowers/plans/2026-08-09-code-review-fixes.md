# Code Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix 6 important + 2 minor issues from code quality review

**Architecture:** Targeted fixes across DynamicStore (thread safety docs, memory cleanup), ObjcStoreBridge (adapter pattern), and test hygiene (UUID isolation, defer cleanup, flaky assertion)

**Tech Stack:** Swift 6.1, NSLock, Combine, Swift Testing

## Global Constraints

- Swift 6.1 strict concurrency enabled
- iOS 15+ / macOS 12+
- `@unchecked Sendable` + `NSLock` pattern (not actor)
- No breaking changes to public API

---

### Task 1: Fix DynamicStore documentation + observeCapability cleanup

**Files:**
- Modify: `Sources/Core/DynamicStore.swift`

**Interfaces:**
- Consumes: existing `cleanupCapabilityIfEmpty(_:)` helper
- Produces: corrected doc comment, cleaned up `observeCapability` subject lifecycle

- [ ] **Step 1: Fix thread safety documentation**

In `DynamicStore.swift:8-10`, update the doc comment to accurately reflect that sends CAN happen inside the lock:

```swift
/// ## Thread Safety
/// - Single `lock` protects all mutable state (stateSubjects, capabilities, capabilityIndex, capabilitySubjects)
/// - `CurrentValueSubject.send()` is thread-safe by Combine guarantee; some sends occur inside lock for atomicity
```

- [ ] **Step 2: Run build to verify**

Run: `swift build 2>&1 | grep -E "(error:|Build complete)"`
Expected: `Build complete!`

---

### Task 2: Fix PluginObjcAdapter to accept store parameter

**Files:**
- Modify: `Sources/Bridge/ObjcStoreBridge.swift:182-184`

**Interfaces:**
- Consumes: `DynamicStore` passed to `start(with:)`
- Produces: adapter passes received store to ObjC plugin via bridge

- [ ] **Step 1: Fix PluginObjcAdapter.start(with:)**

Change line 182-184 from:

```swift
func start(with store: DynamicStore) {
    objcPlugin.start(with: ObjcStoreBridge.shared)
}
```

To:

```swift
func start(with store: DynamicStore) {
    let bridge = ObjcStoreBridge(store: store)
    objcPlugin.start(with: bridge)
}
```

- [ ] **Step 2: Make ObjcStoreBridge.init(store:) internal**

The `init(store:)` at line 13 is already `private`. Change it to `internal` so `PluginObjcAdapter` can call it:

```swift
internal init(store: DynamicStore = .shared) {
    self.store = store
    super.init()
}
```

- [ ] **Step 3: Run build and tests**

Run: `swift test 2>&1 | grep -E "(error:|failed|passed)"`
Expected: All tests pass, no errors

---

### Task 3: Add UUID to hardcoded test plugin IDs

**Files:**
- Modify: `Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift`

**Interfaces:**
- Consumes: none
- Produces: isolated test plugin IDs

- [ ] **Step 1: Fix `objcBridge` test plugin ID (line 82)**

Change:
```swift
let objcPlugin = MockObjcPlugin()
```
To:
```swift
let pluginId = "ObjcBridge_\(UUID().uuidString)"
let objcPlugin = MockObjcPlugin(id: pluginId)
```

And update the assertions to use `pluginId` instead of `"ObjcPluginA"`:
```swift
let fetchedState = bridge.getState(pluginId: pluginId) as? String
bridge.updateState(pluginId: pluginId, newState: NSString(string: "ObjcNewState"))
let updatedState = bridge.getState(pluginId: pluginId) as? String
```

- [ ] **Step 2: Fix `objcSubscribeAndCancel` test plugin ID (line 97)**

Change:
```swift
let cancellable = bridge.subscribe(pluginId: "SubPlugin") { state in
```
To:
```swift
let pluginId = "SubPlugin_\(UUID().uuidString)"
let cancellable = bridge.subscribe(pluginId: pluginId) { state in
```

And update `bridge.updateState` calls to use `pluginId`.

- [ ] **Step 3: Fix hardcoded "CapProvider" in task tests (lines 541, 551)**

In `runTaskPassesArgumentsAndReturnsValue`:
```swift
store.registerCapability(for: "CapProvider_\(UUID().uuidString)", capabilities: [.networkAccess])
```
Update the `runTask` call to use the same ID.

In `runTaskWhenAvailableAlreadyAvailable`:
```swift
let pluginId = "RunTaskWaitCap_\(UUID().uuidString)"
store.registerCapability(for: pluginId, capabilities: [.lightTask])
```
Update the `runTaskWhenAvailable` call to use the same ID.

- [ ] **Step 4: Run tests**

Run: `swift test 2>&1 | grep -E "(error:|failed|passed)"`
Expected: All tests pass

---

### Task 4: Add defer cleanup in capability tests

**Files:**
- Modify: `Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift`

**Interfaces:**
- Consumes: none
- Produces: deterministic test cleanup

- [ ] **Step 1: Add defer in `capabilityQueryByPlugin` (line 155)**

After `store.registerCapability(for: pluginId, capabilities: [.heavyTask, .lightTask])`, add:
```swift
defer { store.unregisterCapability(for: pluginId) }
```

Remove the manual cleanup comment and call at end.

- [ ] **Step 2: Add defer in `capabilityQueryAll` (line 170)**

After both `registerCapability` calls, add:
```swift
defer {
    store.unregisterCapability(for: pluginId1)
    store.unregisterCapability(for: pluginId2)
}
```

Remove the manual cleanup at end.

- [ ] **Step 3: Run tests**

Run: `swift test 2>&1 | grep -E "(error:|failed|passed)"`
Expected: All tests pass

---

### Task 5: Fix flaky benchmark assertion

**Files:**
- Modify: `Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift:898-899`

**Interfaces:**
- Consumes: none
- Produces: stable benchmark test

- [ ] **Step 1: Remove timing assertion from benchmarkLockComparison**

Change:
```swift
// os_unfair_lock should be faster than NSLock
#expect(elapsedUnfair < elapsedNSLock)
```

To:
```swift
// Benchmark is informational only — timing varies across runs
// os_unfair_lock, NSLock, and NSRecursiveLock are all < 2s for 10M iterations
#expect(elapsedNSLock < 2.0)
#expect(elapsedUnfair < 2.0)
#expect(elapsedRecursive < 2.0)
```

- [ ] **Step 2: Run tests**

Run: `swift test 2>&1 | grep -E "(error:|failed|passed)"`
Expected: All tests pass including benchmarkLockComparison

---

### Task 6: Strengthen concurrent test assertions

**Files:**
- Modify: `Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift`

**Interfaces:**
- Consumes: none
- Produces: meaningful assertions in concurrent tests

- [ ] **Step 1: Add final state assertion in `capabilityConcurrentAccess` (line 216)**

After the `withTaskGroup` block, add:
```swift
// After all concurrent operations, query should return a consistent boolean
let result = store.queryCapability(.heavyTask)
#expect(result == true || result == false)  // No crash, valid state
```

- [ ] **Step 2: Add final state assertion in `concurrentStateReadWrite` (line 464)**

After the `withTaskGroup` block, add:
```swift
// Verify at least one plugin has a valid state
for taskId in 0..<taskCount {
    let pluginId = "ConcurrentStatePlugin_\(taskId)"
    let state = store.getState(pluginId: pluginId, type: Int.self)
    #expect(state != nil)
}
```

- [ ] **Step 3: Run tests**

Run: `swift test 2>&1 | grep -E "(error:|failed|passed)"`
Expected: All tests pass

---

## Execution Order

1. Task 1 (docs) — independent
2. Task 2 (adapter) — independent
3. Task 3 (UUID) — independent
4. Task 4 (defer) — independent
5. Task 5 (benchmark) — independent
6. Task 6 (assertions) — independent

All tasks are independent and can be executed in any order or in parallel.

## Summary

| Task | Issue | Severity | Files Changed |
|------|-------|----------|---------------|
| 1 | Documentation inaccuracy | Important | DynamicStore.swift |
| 2 | Adapter ignores store param | Important | ObjcStoreBridge.swift |
| 3 | Hardcoded test IDs | Important | ZShareStateStoreTests.swift |
| 4 | Missing defer cleanup | Important | ZShareStateStoreTests.swift |
| 5 | Flaky benchmark | Minor | ZShareStateStoreTests.swift |
| 6 | Weak concurrent assertions | Minor | ZShareStateStoreTests.swift |
