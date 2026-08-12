# ObjC Bridge Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three issues identified in code review: ObjcLease snapshot behavior, ObjcStoreBridge caching, and missing @Sendable annotation.

**Architecture:** Add refresh method to ObjcLease, invalidate cache in ObjcStoreBridge, and add @Sendable annotation to completion closures.

**Tech Stack:** Swift 6.1, `@preconcurrency import Foundation`, Swift Testing framework

## Global Constraints

- Swift 6.1 with `StrictConcurrency=complete`
- Platforms: iOS 15+ / macOS 12+
- No external dependencies
- All new types must be `Sendable`
- Tests use Swift Testing framework (NOT XCTest)
- Fresh `DynamicStore()` instances for each test
- UUID-based plugin IDs for isolation

---

### Task 1: Add @Sendable to ObjcStoreBridge Completion Closures

**Files:**
- Modify: `Sources/TPCapabilityKitBridge/ObjcStoreBridge.swift:160-173`

**Interfaces:**
- Consumes: `ObjcLease`, `ObjcTaskDescriptor`
- Produces: Updated `ObjcStoreBridge.scheduleTask` with @Sendable completion

- [ ] **Step 1: Add @Sendable annotation to scheduleTask completion**

In `ObjcStoreBridge.swift`, update the `scheduleTask` method signature:

```swift
/// Schedules a task for execution.
@objc public func scheduleTask(
    _ descriptor: ObjcTaskDescriptor,
    task: @escaping @Sendable () -> Void,
    completion: (@Sendable (ObjcLease) -> Void)? = nil
) -> ObjcLease {
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build`
Expected: BUILD SUCCEEDS

- [ ] **Step 3: Commit**

```bash
git add Sources/TPCapabilityKitBridge/ObjcStoreBridge.swift
git commit -m "fix: add @Sendable annotation to scheduleTask completion closure"
```

---

### Task 2: Add refresh() Method to ObjcLease

**Files:**
- Modify: `Sources/TPCapabilityKitBridge/ObjcLease.swift`
- Modify: `Tests/TPCapabilityKitTests/TPCapabilityKitObjCTaskSchedulerTests.swift`

**Interfaces:**
- Consumes: `Lease`, `Lease.State`
- Produces: `ObjcLease.refresh()` method

- [ ] **Step 1: Add refresh method to ObjcLease**

In `ObjcLease.swift`, add after the `init` method:

```swift
    /// Refreshes cached state from the underlying lease.
    /// Call this after the underlying lease may have changed state.
    @objc public func refresh() {
        state = State(rawValue: underlying.state.rawValue) ?? .pending
        activatedAt = underlying.activatedAt
        completedAt = underlying.completedAt
        result = underlying.result
        retryCount = underlying.retryCount
    }
```

- [ ] **Step 2: Add test for refresh method**

In `TPCapabilityKitObjCTaskSchedulerTests.swift`, add to `ObjcLeaseTests`:

```swift
    @Test func refreshUpdatesState() {
        let task = TaskDescriptor(requiredCapabilities: [.heavyTask])
        let lease = Lease(task: task)
        let objcLease = ObjcLease(underlying: lease)
        
        // Initial state
        #expect(objcLease.state == .pending)
        
        // Activate underlying lease
        lease.activate()
        
        // ObjcLease still shows pending (snapshot)
        #expect(objcLease.state == .pending)
        
        // Refresh from underlying
        objcLease.refresh()
        
        // Now shows active
        #expect(objcLease.state == .active)
        #expect(objcLease.activatedAt != nil)
    }
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter ObjcLeaseTests`
Expected: ALL TESTS PASS

- [ ] **Step 4: Commit**

```bash
git add Sources/TPCapabilityKitBridge/ObjcLease.swift Tests/TPCapabilityKitTests/TPCapabilityKitObjCTaskSchedulerTests.swift
git commit -m "feat: add refresh() method to ObjcLease for state sync"
```

---

### Task 3: Invalidate ObjcTaskScheduler Cache

**Files:**
- Modify: `Sources/TPCapabilityKitBridge/ObjcStoreBridge.swift`
- Modify: `Tests/TPCapabilityKitTests/TPCapabilityKitObjCTaskSchedulerTests.swift`

**Interfaces:**
- Consumes: `ObjcTaskScheduler`, `DynamicStore`
- Produces: Updated `ObjcStoreBridge.taskScheduler` with cache invalidation

- [ ] **Step 1: Update taskScheduler property to check for scheduler changes**

In `ObjcStoreBridge.swift`, update the `taskScheduler` property:

```swift
/// Shared task scheduler instance. Cached for consistent reference.
/// Automatically invalidates cache when the underlying scheduler changes.
@objc public var taskScheduler: ObjcTaskScheduler {
    lock.lock()
    defer { lock.unlock() }
    
    // Check if cached scheduler is still valid
    if let existing = _taskScheduler {
        // Invalidate if the underlying scheduler has changed
        if let currentScheduler = existing.value(forKey: "_scheduler") as? (any TaskSchedulerProtocol),
           currentScheduler === store.scheduler {
            return existing
        }
    }
    
    let new = ObjcTaskScheduler(scheduler: store.scheduler, store: store)
    _taskScheduler = new
    return new
}
```

- [ ] **Step 2: Alternative approach - Don't cache, create on each access**

Actually, let me reconsider. The simplest approach is to not cache at all:

```swift
/// Shared task scheduler instance. Created on each access for consistency.
@objc public var taskScheduler: ObjcTaskScheduler {
    ObjcTaskScheduler(scheduler: store.scheduler, store: store)
}
```

And remove the `_taskScheduler` property.

- [ ] **Step 3: Update implementation to not cache**

In `ObjcStoreBridge.swift`, replace the `taskScheduler` property and remove `_taskScheduler`:

```swift
/// Shared task scheduler instance. Created on each access for consistency.
@objc public var taskScheduler: ObjcTaskScheduler {
    ObjcTaskScheduler(scheduler: store.scheduler, store: store)
}
```

Remove:
```swift
private var _taskScheduler: ObjcTaskScheduler?
```

- [ ] **Step 4: Add test for scheduler replacement**

In `TPCapabilityKitObjCTaskSchedulerTests.swift`, add to `ObjcStoreBridgeSchedulingTests`:

```swift
    @Test func taskSchedulerReflectsReplacement() {
        let store = DynamicStore()
        let bridge = ObjcStoreBridge(store: store)
        
        // Get initial scheduler
        let scheduler1 = bridge.taskScheduler
        
        // Replace scheduler
        let mockScheduler = MockTaskScheduler(store: store)
        store.scheduler = mockScheduler
        
        // Get new scheduler wrapper
        let scheduler2 = bridge.taskScheduler
        
        // Should use the new mock scheduler
        #expect(scheduler2.pendingCount == 0)  // Mock returns 0
    }
```

- [ ] **Step 5: Build to verify compilation**

Run: `swift build`
Expected: BUILD SUCCEEDS

- [ ] **Step 6: Run tests**

Run: `swift test --filter ObjcStoreBridgeSchedulingTests`
Expected: ALL TESTS PASS

- [ ] **Step 7: Commit**

```bash
git add Sources/TPCapabilityKitBridge/ObjcStoreBridge.swift Tests/TPCapabilityKitTests/TPCapabilityKitObjCTaskSchedulerTests.swift
git commit -m "fix: remove ObjcTaskScheduler caching to reflect scheduler changes"
```

---

### Task 4: Add Documentation for ObjcLease Snapshot Behavior

**Files:**
- Modify: `Sources/TPCapabilityKitBridge/ObjcLease.swift`

**Interfaces:**
- Consumes: `ObjcLease`
- Produces: Updated documentation

- [ ] **Step 1: Add doc comment for snapshot behavior**

In `ObjcLease.swift`, update the class documentation:

```swift
/// Objective-C wrapper for Lease.
///
/// - Important: This wrapper captures a snapshot of the lease state at creation time.
///   If the underlying lease changes state after creation, call `refresh()` to sync.
///   Alternatively, access the `underlying` property for the live lease object.
@objc(TPLease)
public final class ObjcLease: NSObject, @unchecked Sendable {
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build`
Expected: BUILD SUCCEEDS

- [ ] **Step 3: Commit**

```bash
git add Sources/TPCapabilityKitBridge/ObjcLease.swift
git commit -m "docs: add snapshot behavior documentation to ObjcLease"
```

---

### Task 5: Final Verification

**Files:**
- None (verification only)

- [ ] **Step 1: Build project**

Run: `swift build`
Expected: BUILD SUCCEEDS

- [ ] **Step 2: Run all tests**

Run: `swift test`
Expected: ALL TESTS PASS (no failures, no timeouts)

- [ ] **Step 3: Verify no regressions**

Check that existing tests still pass:
Run: `swift test --filter TaskSchedulerTests`
Expected: ALL TESTS PASS

- [ ] **Step 4: Commit all changes**

```bash
git add -A
git commit -m "chore: final verification for ObjC bridge fixes"
```

- [ ] **Step 5: Push to remote**

```bash
git push
```

---

## File Changes Summary

### Modified Files
| File | Changes |
|------|---------|
| `ObjcStoreBridge.swift` | Add @Sendable to completion, remove taskScheduler caching |
| `ObjcLease.swift` | Add refresh() method, add snapshot documentation |
| `TPCapabilityKitObjCTaskSchedulerTests.swift` | Add tests for refresh, cache invalidation |

## Backward Compatibility

- All existing APIs remain unchanged
- New `refresh()` method is additive
- Cache removal is transparent to consumers
- @Sendable annotation is source-compatible
