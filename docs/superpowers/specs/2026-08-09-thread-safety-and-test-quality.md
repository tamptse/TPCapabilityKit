# Plan: Thread Safety Fix + Test Quality Improvement

## Scope

5 changes to DynamicStore + tests:

| # | Change | Priority | Breaking? |
|---|--------|----------|-----------|
| 1 | Merge 2 locks into 1 lock | Critical | No |
| 2 | Cleanup `capabilitySubjects` on full unregister | Moderate | No |
| 3 | Extract reverse-index helper to remove duplication | Moderate | No |
| 4 | Test isolation: fresh `DynamicStore()` instead of `shared` | Moderate | No |
| 5 | Add `defer` cleanup in tests | Low | No |

---

## Task 1: Merge 2 locks into 1 lock

### Problem

DynamicStore uses 2 separate locks:
- `lock` for `stateSubjects`
- `capabilityLock` for `capabilities`, `capabilityIndex`, `capabilitySubjects`

Cross-layer operations (`registeredPluginIds`, `hasPlugin`) acquire both locks non-atomically, creating TOCTOU races.

### Solution

Replace both locks with a single `NSLock`.

### Changes in `Sources/Core/DynamicStore.swift`

**1.1 Replace lock declarations (lines 22-31)**

Before:
```swift
private var stateSubjects: [String: CurrentValueSubject<Any?, Never>] = [:]
private let lock = NSLock()

private var capabilities: [String: Set<Capability>] = [:]
private var capabilityIndex: [Capability: Set<String>] = [:]
private var capabilitySubjects: [Capability: CurrentValueSubject<Bool, Never>] = [:]
private let capabilityLock = NSLock()
private let capabilitySubject = CurrentValueSubject<[String: Set<Capability>], Never>([:])
```

After:
```swift
// MARK: - Mutable State (all protected by single `lock`)
private var stateSubjects: [String: CurrentValueSubject<Any?, Never>] = [:]
private var capabilities: [String: Set<Capability>] = [:]
private var capabilityIndex: [Capability: Set<String>] = [:]
private var capabilitySubjects: [Capability: CurrentValueSubject<Bool, Never>] = [:]
private let lock = NSLock()
private let capabilitySubject = CurrentValueSubject<[String: Set<Capability>], Never>([:])
```

**1.2 Update all `capabilityLock` references to `lock`**

Methods to update:
- `registerCapability(for:capabilities:)` (line 185): `capabilityLock.lock()` → `lock.lock()`
- `unregisterCapability(for:)` (line 215): `capabilityLock.lock()` → `lock.lock()`
- `queryCapability(_:)` (line 238): `capabilityLock.lock()` → `lock.lock()`
- `queryCapabilities(for:)` (line 248): `capabilityLock.lock()` → `lock.lock()`
- `queryAllCapabilities()` (line 256): `capabilityLock.lock()` → `lock.lock()`
- `observeCapability(_:)` (line 265): `capabilityLock.lock()` → `lock.lock()`
- `observeCapability(_:)` (line 274): `capabilityLock.unlock()` → `lock.unlock()`

**1.3 Simplify `registeredPluginIds` (lines 134-144)**

Before:
```swift
public var registeredPluginIds: [String] {
    lock.lock()
    let stateIds = Set(stateSubjects.keys)
    lock.unlock()
    
    capabilityLock.lock()
    let capabilityIds = Set(capabilities.keys)
    capabilityLock.unlock()
    
    return Array(stateIds.union(capabilityIds))
}
```

After:
```swift
public var registeredPluginIds: [String] {
    lock.lock()
    defer { lock.unlock() }
    let stateIds = Set(stateSubjects.keys)
    let capabilityIds = Set(capabilities.keys)
    return Array(stateIds.union(capabilityIds))
}
```

**1.4 Simplify `hasPlugin(id:)` (lines 149-161)**

Before:
```swift
public func hasPlugin(id pluginId: String) -> Bool {
    guard validatePluginId(pluginId) else { return false }
    
    lock.lock()
    let hasState = stateSubjects[pluginId] != nil
    lock.unlock()
    
    capabilityLock.lock()
    let hasCapabilities = capabilities[pluginId] != nil
    capabilityLock.unlock()
    
    return hasState || hasCapabilities
}
```

After:
```swift
public func hasPlugin(id pluginId: String) -> Bool {
    guard validatePluginId(pluginId) else { return false }
    lock.lock()
    defer { lock.unlock() }
    return stateSubjects[pluginId] != nil || capabilities[pluginId] != nil
}
```

**1.5 Update lock comments (line 7-11)**

Remove the dual-lock documentation, update to single-lock.

---

## Task 2: Cleanup `capabilitySubjects` on full unregister

### Problem

When all providers for a capability are unregistered, the per-capability `CurrentValueSubject` in `capabilitySubjects` is never removed. This causes memory leak over time.

### Solution

After removing a capability from `capabilityIndex`, if the set becomes empty, also remove from `capabilitySubjects`.

### Changes in `Sources/Core/DynamicStore.swift`

**2.1 Add private helper method (after `ensureSubject`)**

```swift
/// Removes a capability from the reverse index and cleans up the subject if no providers remain.
/// Must be called while holding `lock`.
private func cleanupCapabilityFromIndex(_ cap: Capability) {
    capabilityIndex[cap]?.remove(allContains: [])  // no-op, just checking
    if capabilityIndex[cap]?.isEmpty == true {
        capabilityIndex.removeValue(forKey: cap)
        capabilitySubjects[cap]?.send(false)
        capabilitySubjects.removeValue(forKey: cap)  // ← NEW: cleanup subject
    }
}
```

Wait, `Set` doesn't have `remove(allContains:)`. Let me simplify:

```swift
/// Removes a capability from the reverse index and cleans up the subject if no providers remain.
/// Must be called while holding `lock`.
private func cleanupCapabilityFromIndex(_ cap: Capability) {
    guard let providers = capabilityIndex[cap] else { return }
    if providers.isEmpty {
        capabilityIndex.removeValue(forKey: cap)
        capabilitySubjects[cap]?.send(false)
        capabilitySubjects.removeValue(forKey: cap)
    }
}
```

Hmm, the issue is we remove from `providers` first, then check. Let me look at the existing code pattern:

```swift
capabilityIndex[cap]?.remove(pluginId)
if capabilityIndex[cap]?.isEmpty == true {
    capabilityIndex.removeValue(forKey: cap)
    capabilitySubjects[cap]?.send(false)
}
```

So the helper should be called AFTER `remove(pluginId)`. The helper just checks if empty and cleans up:

```swift
/// Cleans up reverse index entry and subject if no providers remain.
/// Must be called after removing a pluginId from capabilityIndex[cap], while holding `lock`.
private func cleanupCapabilityIfEmpty(_ cap: Capability) {
    if capabilityIndex[cap]?.isEmpty == true {
        capabilityIndex.removeValue(forKey: cap)
        capabilitySubjects[cap]?.send(false)
        capabilitySubjects.removeValue(forKey: cap)  // ← NEW
    }
}
```

**2.2 Apply in `registerCapability` (lines 189-198)**

Replace:
```swift
if let oldCapabilities = self.capabilities[pluginId] {
    for cap in oldCapabilities {
        capabilityIndex[cap]?.remove(pluginId)
        if capabilityIndex[cap]?.isEmpty == true {
            capabilityIndex.removeValue(forKey: cap)
            capabilitySubjects[cap]?.send(false)
        }
    }
}
```

With:
```swift
if let oldCapabilities = self.capabilities[pluginId] {
    for cap in oldCapabilities {
        capabilityIndex[cap]?.remove(pluginId)
        cleanupCapabilityIfEmpty(cap)
    }
}
```

**2.3 Apply in `unregisterCapability` (lines 219-228)**

Same replacement as above.

---

## Task 3: Extract reverse-index cleanup helper

### Problem

The reverse-index cleanup logic is duplicated verbatim between `registerCapability` (lines 189-198) and `unregisterCapability` (lines 219-228).

### Solution

Already addressed in Task 2 by creating `cleanupCapabilityIfEmpty(_:)` helper.

This task is merged with Task 2.

---

## Task 4: Test isolation - fresh `DynamicStore()` instead of `shared`

### Problem

13 functional tests + 6 performance tests use `DynamicStore.shared`, polluting shared state. Tests run concurrently in Swift Testing, causing interference.

### Solution

Change functional tests to use `DynamicStore()`. Keep performance benchmarks on `shared` (they need high throughput, isolation less critical).

### Changes in `Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift`

**4.1 Tests to migrate from `shared` to `DynamicStore()`**

| Line | Test | Change |
|------|------|--------|
| 122 | `capabilityAutoRegistration()` | `DynamicStore.shared` → `DynamicStore()` |
| 136 | `capabilityManualRegistration()` | `DynamicStore.shared` → `DynamicStore()` |
| 149 | `capabilityUnregistration()` | `DynamicStore.shared` → `DynamicStore()` |

Note: These 3 tests already have cleanup calls. After migration to fresh instances, cleanup is still good practice but not critical.

**4.2 ObjC bridge tests - CANNOT migrate**

Tests at lines 82, 97, 246, 259, 494, 660, 673, 683, 699, 714 use `ObjcStoreBridge.shared` because `ObjcStoreBridge` has no public initializer accepting a custom store. These tests CANNOT be isolated without changing the bridge's init access.

Decision: Keep ObjC bridge tests on shared singleton. They use UUID-suffixed plugin IDs to avoid collisions.

**4.3 Performance benchmarks - keep on `shared`**

Lines 733, 748, 762, 777, 802, 817, 831, 848: Benchmarks intentionally stress the shared singleton. Keep as-is.

---

## Task 5: Add `defer` cleanup in tests

### Problem

Tests that use `DynamicStore.shared` (or even fresh instances with shared bridge) clean up manually at the end of the test body. If an assertion fails before cleanup, stale state remains.

### Solution

Add `defer` blocks after setup in tests that register capabilities.

### Changes in `Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift`

**5.1 Tests requiring `defer` cleanup**

For each test that registers capabilities on `DynamicStore.shared` or `ObjcStoreBridge.shared`, add `defer` block after registration.

Example - `capabilityAutoRegistration()` (line 121):

Before:
```swift
@Test func capabilityAutoRegistration() {
    let store = DynamicStore.shared
    let pluginId = "CapPluginA_\(UUID().uuidString)"
    let plugin = TestCapabilityPlugin(id: pluginId, capabilities: [.heavyTask, .lightTask])
    
    store.register(plugin: plugin)
    
    #expect(store.queryCapability(.heavyTask) == true)
    #expect(store.queryCapability(.lightTask) == true)
    
    // Clean up
    store.unregisterCapability(for: pluginId)
}
```

After:
```swift
@Test func capabilityAutoRegistration() {
    let store = DynamicStore()
    let pluginId = "CapPluginA_\(UUID().uuidString)"
    let plugin = TestCapabilityPlugin(id: pluginId, capabilities: [.heavyTask, .lightTask])
    
    store.register(plugin: plugin)
    defer { store.unregisterCapability(for: pluginId) }
    
    #expect(store.queryCapability(.heavyTask) == true)
    #expect(store.queryCapability(.lightTask) == true)
}
```

**5.2 Full list of tests to add `defer`**

Tests on `DynamicStore()` (fresh) - cleanup not critical but good practice:
- `capabilityQueryByPlugin` (line 161)
- `capabilityQueryAll` (line 176)
- `capabilityReactiveObservation` (line 193)
- `observeAllCapabilitiesReactive` (line 309)
- `registeredPluginIdsAfterRegisterAndUnregister` (line 363)
- `hasPluginIdTrueAndFalse` (line 389)
- `unregisterCapabilitySoleProviderQueryReturnsFalse` (line 411)
- `registerCapabilityReplacesOldCapabilities` (line 423)
- `runTaskWhenCapabilityAvailable` (line 527)
- `runTaskPassesArgumentsAndReturnsValue` (line 549)
- `runTaskWhenAvailableAlreadyAvailable` (line 559)
- `runTaskWhenAvailableWaitsForCapability` (line 569)
- `runTaskCapabilityRevokedAfterRegister` (line 607)
- `runTaskMultipleCapabilities` (line 626)
- `runTaskConcurrentAccess` (line 641)

Tests on `ObjcStoreBridge.shared` - cleanup IS critical:
- `objcCapabilityBridge` (line 246)
- `objcCapabilitySubscribe` (line 259)
- `objcRunTaskIfAvailableWhenAvailable` (line 660)
- `objcRunTaskWhenAvailableAlreadyAvailable` (line 683)
- `objcIsCapabilityAvailable` (line 714)

---

## Execution Order

1. Task 1 (merge locks) - foundation, must be first
2. Task 2+3 (cleanup helper + memory leak fix) - depends on Task 1
3. Task 4 (test isolation) - independent
4. Task 5 (defer cleanup) - depends on Task 4

## Verification

After all changes:
```bash
swift test
```

All 50 tests must pass. No regressions in performance benchmarks.
