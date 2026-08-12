# Rename ZSharedStateStore → TPCapabilityKit

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename all modules, folders, files, and references from `ZSharedStateStore` to `TPCapabilityKit`.

**Architecture:** Find-and-replace across Package.swift, all Swift source files, all test files. Rename directories and files last.

**Tech Stack:** Swift 6.1, SPM

## Global Constraints

- Swift 6.1 with strict concurrency enabled
- `NSLock` for thread safety
- Tests use `@testable import` for internal API access
- All tests must pass: `swift test`
- No external dependencies
- Swift prefix: `TP`
- ObjC prefix: `TP` (replaces `ZSS`)

---

## File Structure

| Current | New |
|---------|-----|
| `Sources/Core/` | `Sources/Core/` (unchanged) |
| `Sources/Bridge/` | `Sources/Bridge/` (unchanged) |
| `Sources/Sample/ZSharedStateStoreSample.swift` | `Sources/Sample/TPCapabilityKitSample.swift` |
| `Tests/ZSharedStateStoreTests/` | `Tests/TPCapabilityKitTests/` |
| `Tests/ZSharedStateStoreTests/ZSharedStateStoreCoreTests.swift` | `Tests/TPCapabilityKitTests/TPCapabilityKitCoreTests.swift` |
| `Tests/ZSharedStateStoreTests/ZSharedStateStoreCapabilityTests.swift` | `Tests/TPCapabilityKitTests/TPCapabilityKitCapabilityTests.swift` |
| `Tests/ZSharedStateStoreTests/ZSharedStateStoreObjCBridgeTests.swift` | `Tests/TPCapabilityKitTests/TPCapabilityKitObjCBridgeTests.swift` |
| `Tests/ZSharedStateStoreTests/ZSharedStateStoreTaskTests.swift` | `Tests/TPCapabilityKitTests/TPCapabilityKitTaskTests.swift` |
| `Tests/ZSharedStateStoreTests/ZSharedStateStorePerformanceTests.swift` | `Tests/TPCapabilityKitTests/TPCapabilityKitPerformanceTests.swift` |

---

### Task 1: Update Package.swift

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Replace all target and package names**

Replace the entire `Package.swift` content:

```swift
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "TPCapabilityKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "TPCapabilityKit",
            targets: ["TPCapabilityKit"],
        )
    ],
    targets: [
        .target(
            name: "TPCapabilityKit",
            path: "Sources/Core",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "TPCapabilityKitBridge",
            dependencies: ["TPCapabilityKit"],
            path: "Sources/Bridge",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "TPCapabilityKitSample",
            dependencies: ["TPCapabilityKit", "TPCapabilityKitBridge"],
            path: "Sources/Sample",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "TPCapabilityKitTests",
            dependencies: ["TPCapabilityKit", "TPCapabilityKitBridge", "TPCapabilityKitSample"],
            path: "Tests/TPCapabilityKitTests",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
```

- [ ] **Step 2: Verify SPM can resolve**

Run: `swift package describe 2>&1 | head -20`
Expected: Shows `TPCapabilityKit` package with correct targets

---

### Task 2: Update import statements in all Swift files

**Files:**
- Modify: `Sources/Bridge/ObjcStoreBridge.swift`
- Modify: `Sources/Sample/ZSharedStateStoreSample.swift`
- Modify: All 5 test files under `Tests/`

- [ ] **Step 1: Update imports in ObjcStoreBridge.swift**

In `Sources/Bridge/ObjcStoreBridge.swift`, replace line 3:

```swift
// Before:
import ZSharedStateStore

// After:
import TPCapabilityKit
```

- [ ] **Step 2: Update imports in Sample file**

In `Sources/Sample/ZSharedStateStoreSample.swift`, replace lines 3-4:

```swift
// Before:
import ZSharedStateStore
import ZSharedStateStoreBridge

// After:
import TPCapabilityKit
import TPCapabilityKitBridge
```

- [ ] **Step 3: Update imports in ZSharedStateStoreCoreTests.swift**

In `Tests/ZSharedStateStoreTests/ZSharedStateStoreCoreTests.swift`, replace lines 4-5:

```swift
// Before:
@testable import ZSharedStateStore
@testable import ZSharedStateStoreSample

// After:
@testable import TPCapabilityKit
@testable import TPCapabilityKitSample
```

- [ ] **Step 4: Update imports in ZSharedStateStoreCapabilityTests.swift**

In `Tests/ZSharedStateStoreTests/ZSharedStateStoreCapabilityTests.swift`, replace line 4:

```swift
// Before:
@testable import ZSharedStateStore

// After:
@testable import TPCapabilityKit
```

- [ ] **Step 5: Update imports in ZSharedStateStoreObjCBridgeTests.swift**

In `Tests/ZSharedStateStoreTests/ZSharedStateStoreObjCBridgeTests.swift`, replace lines 4-5:

```swift
// Before:
@testable import ZSharedStateStore
@testable import ZSharedStateStoreBridge

// After:
@testable import TPCapabilityKit
@testable import TPCapabilityKitBridge
```

- [ ] **Step 6: Update imports in ZSharedStateStoreTaskTests.swift**

In `Tests/ZSharedStateStoreTests/ZSharedStateStoreTaskTests.swift`, replace line 4:

```swift
// Before:
@testable import ZSharedStateStore

// After:
@testable import TPCapabilityKit
```

- [ ] **Step 7: Update imports in ZSharedStateStorePerformanceTests.swift**

In `Tests/ZSharedStateStoreTests/ZSharedStateStorePerformanceTests.swift`, replace lines 4-5:

```swift
// Before:
@testable import ZSharedStateStore
@testable import ZSharedStateStoreBridge

// After:
@testable import TPCapabilityKit
@testable import TPCapabilityKitBridge
```

- [ ] **Step 8: Verify no remaining ZSharedStateStore imports**

Run: `grep -rn "ZSharedStateStore" Sources/ Tests/ --include="*.swift"`
Expected: No output (all imports updated)

---

### Task 3: Update ObjC bridge names (ZSS → TP)

**Files:**
- Modify: `Sources/Bridge/ObjcStoreBridge.swift`
- Modify: `Sources/Bridge/ObjcAppPlugin.swift`
- Modify: `Sources/Bridge/ObjcCancellable.swift`
- Modify: `Sources/Sample/ZSharedStateStoreSample.swift`

- [ ] **Step 1: Update ObjcStoreBridge ObjC name**

In `Sources/Bridge/ObjcStoreBridge.swift`, replace line 6:

```swift
// Before:
@objc(ZSSStoreBridge)

// After:
@objc(TPStoreBridge)
```

- [ ] **Step 2: Update ObjcAppPlugin ObjC name**

In `Sources/Bridge/ObjcAppPlugin.swift`, replace line 4:

```swift
// Before:
@objc(ZSSAppPlugin)

// After:
@objc(TPAppPlugin)
```

- [ ] **Step 3: Update ObjcCancellable ObjC name**

In `Sources/Bridge/ObjcCancellable.swift`, replace line 5:

```swift
// Before:
@objc(ZSSCancellable)

// After:
@objc(TPCancellable)
```

- [ ] **Step 4: Update Sample ObjC names**

In `Sources/Sample/ZSharedStateStoreSample.swift`, replace lines 22 and 108:

```swift
// Before (line 22):
@objc(ZSSUserProfileState)

// After:
@objc(TPUserProfileState)


// Before (line 108):
@objc(ZSSSampleObjcPlugin)

// After:
@objc(TPSampleObjcPlugin)
```

- [ ] **Step 5: Verify no remaining ZSS references**

Run: `grep -rn "ZSS" Sources/ --include="*.swift"`
Expected: No output

---

### Task 4: Rename directories and files

**Files:**
- Rename: `Tests/ZSharedStateStoreTests/` → `Tests/TPCapabilityKitTests/`
- Rename: `Sources/Sample/ZSharedStateStoreSample.swift` → `Sources/Sample/TPCapabilityKitSample.swift`

- [ ] **Step 1: Create new test directory**

Run: `mkdir -p Tests/TPCapabilityKitTests`

- [ ] **Step 2: Move test files to new directory**

Run:
```bash
mv Tests/ZSharedStateStoreTests/ZSharedStateStoreCoreTests.swift Tests/TPCapabilityKitTests/TPCapabilityKitCoreTests.swift
mv Tests/ZSharedStateStoreTests/ZSharedStateStoreCapabilityTests.swift Tests/TPCapabilityKitTests/TPCapabilityKitCapabilityTests.swift
mv Tests/ZSharedStateStoreTests/ZSharedStateStoreObjCBridgeTests.swift Tests/TPCapabilityKitTests/TPCapabilityKitObjCBridgeTests.swift
mv Tests/ZSharedStateStoreTests/ZSharedStateStoreTaskTests.swift Tests/TPCapabilityKitTests/TPCapabilityKitTaskTests.swift
mv Tests/ZSharedStateStoreTests/ZSharedStateStorePerformanceTests.swift Tests/TPCapabilityKitTests/TPCapabilityKitPerformanceTests.swift
```

- [ ] **Step 3: Remove old test directory**

Run: `rmdir Tests/ZSharedStateStoreTests`

- [ ] **Step 4: Rename sample file**

Run: `mv Sources/Sample/ZSharedStateStoreSample.swift Sources/Sample/TPCapabilityKitSample.swift`

- [ ] **Step 5: Update struct name in sample file**

In `Sources/Sample/TPCapabilityKitSample.swift`, replace line 133:

```swift
// Before:
enum ZSharedStateStoreSample {

// After:
enum TPCapabilityKitSample {
```

- [ ] **Step 6: Update reference in test file**

In `Tests/TPCapabilityKitTests/TPCapabilityKitCoreTests.swift`, replace line 239:

```swift
// Before:
ZSharedStateStoreSample.runExample()

// After:
TPCapabilityKitSample.runExample()
```

- [ ] **Step 7: Verify directory structure**

Run: `find Sources Tests -type f -name "*.swift" | sort`
Expected: All files at new paths

---

### Task 5: Final verification

- [ ] **Step 1: Run full test suite**

Run: `swift test`
Expected: All 52 tests pass

- [ ] **Step 2: Verify no stale references**

Run: `grep -rn "ZSharedStateStore\|ZSS" Sources/ Tests/ Package.swift --include="*.swift"`
Expected: No output

---

## Summary

| Task | Change | Risk |
|------|--------|------|
| 1 | Package.swift target names | None |
| 2 | Import statements (7 files) | None |
| 3 | ObjC names ZSS → TP (4 files) | None |
| 4 | Directory/file renames + struct rename | None |
| 5 | Final verification | None |

**Total files modified:** ~13
**Total files renamed:** 6
**Total directories renamed:** 1
