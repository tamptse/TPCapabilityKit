# Code Quality Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix 5 identified code quality issues in ZSharedStateStore

**Architecture:** Add plugin lifecycle management, fix thread safety primitives, correct documentation, improve type safety, and isolate sample code

**Tech Stack:** Swift 6.1, Combine, Swift Testing framework

## Global Constraints

- Swift 6.1 with strict concurrency enabled
- Platforms: iOS 15+, macOS 12+
- No external dependencies (only Foundation + Combine)
- All changes must pass `swift test`

---

## Task 1: Add `unregister(plugin:)` + State Cleanup

**Files:**
- Modify: `Sources/Core/DynamicStore.swift`
- Test: `Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift`

**Interfaces:**
- Consumes: Existing `DynamicStore` API
- Produces: `unregister(plugin:)` method, `removeState(for:)` method

- [ ] **Step 1: Add `removeState(for:)` method to DynamicStore**

Add after line 65 (after `getState` method):

```swift
/// Removes the state subject for a plugin identifier.
/// - Parameter pluginId: Unique identifier of the target plugin.
public func removeState(for pluginId: String) {
    lock.lock()
    defer { lock.unlock() }
    stateSubjects.removeValue(forKey: pluginId)
}
```

- [ ] **Step 2: Add `unregister(plugin:)` method to DynamicStore**

Add after `register(plugin:)` method (after line 35):

```swift
/// Unregisters a plugin and cleans up its state and capabilities.
/// - Parameter plugin: The plugin to unregister.
public func unregister(plugin: AppPlugin) {
    removeState(for: plugin.id)
    unregisterCapability(for: plugin.id)
}
```

- [ ] **Step 3: Write test for unregister**

Add to test file after existing capability tests:

```swift
@Test func unregisterPlugin() {
    let store = DynamicStore.shared
    let pluginId = "UnregisterPlugin_\(UUID().uuidString)"
    let plugin = TestPlugin(id: pluginId)
    
    store.register(plugin: plugin)
    store.updateState(pluginId: pluginId, newState: "TestState")
    #expect(store.getState(pluginId: pluginId, type: String.self) == "TestState")
    
    store.unregister(plugin: plugin)
    #expect(store.getState(pluginId: pluginId, type: String.self) == nil)
    #expect(store.queryCapabilities(for: pluginId).isEmpty)
}
```

- [ ] **Step 4: Run tests to verify**

Run: `swift test --filter unregisterPlugin`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/DynamicStore.swift Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift
git commit -m "feat: add unregister(plugin:) and state cleanup"
```

---

## Task 2: Change `NSRecursiveLock` → `NSLock`

**Files:**
- Modify: `Sources/Core/DynamicStore.swift:12`

**Interfaces:**
- Consumes: None
- Produces: Same API, different lock implementation

- [ ] **Step 1: Change lock type**

Replace line 12:
```swift
private let lock = NSRecursiveLock()
```

With:
```swift
private let lock = NSLock()
```

- [ ] **Step 2: Run full test suite**

Run: `swift test`
Expected: ALL PASS (no recursive locking needed in current implementation)

- [ ] **Step 3: Commit**

```bash
git add Sources/Core/DynamicStore.swift
git commit -m "perf: replace NSRecursiveLock with NSLock for state layer"
```

---

## Task 3: Fix Doc for `observeState`

**Files:**
- Modify: `Sources/Core/DynamicStore.swift:71`

**Interfaces:**
- Consumes: None
- Produces: Corrected documentation

- [ ] **Step 1: Fix doc comment**

Replace line 71:
```swift
/// - Returns: A publisher emitting values matching type `T` on the main thread.
```

With:
```swift
/// - Returns: A publisher emitting values matching type `T`. Subscribers must handle thread scheduling.
```

- [ ] **Step 2: Commit**

```bash
git add Sources/Core/DynamicStore.swift
git commit -m "docs: correct observeState return value documentation"
```

---

## Task 4: Fix `Capability.init?(rawValue:)` Type Safety

**Files:**
- Modify: `Sources/Core/Capability.swift`
- Test: `Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift`

**Interfaces:**
- Consumes: None
- Produces: `Capability` enum with proper validation

- [ ] **Step 1: Add `unknown` case to Capability enum**

Replace Capability enum (lines 6-34):

```swift
public enum Capability: Hashable, Sendable {
    case heavyTask
    case lightTask
    case networkAccess
    case backgroundExecution
    case custom(String)
    case unknown(String)

    /// String representation for ObjC bridge compatibility.
    public var rawValue: String {
        switch self {
        case .heavyTask: return "heavyTask"
        case .lightTask: return "lightTask"
        case .networkAccess: return "networkAccess"
        case .backgroundExecution: return "backgroundExecution"
        case .custom(let value): return value
        case .unknown(let value): return value
        }
    }

    /// Initialize from a string identifier.
    /// Known capabilities return their specific case.
    /// Unknown strings return `.unknown(rawValue)`.
    public init(rawValue: String) {
        switch rawValue {
        case "heavyTask": self = .heavyTask
        case "lightTask": self = .lightTask
        case "networkAccess": self = .networkAccess
        case "backgroundExecution": self = .backgroundExecution
        default: self = .unknown(rawValue)
        }
    }
}
```

- [ ] **Step 2: Write test for Capability init**

Add to test file:

```swift
@Test func capabilityInitFromRawValue() {
    let known = Capability(rawValue: "heavyTask")
    #expect(known == .heavyTask)
    
    let unknown = Capability(rawValue: "invalidCapability")
    if case .unknown(let value) = unknown {
        #expect(value == "invalidCapability")
    } else {
        #expect(Bool(false))
    }
}
```

- [ ] **Step 3: Run tests to verify**

Run: `swift test --filter capabilityInitFromRawValue`
Expected: PASS

- [ ] **Step 4: Run full test suite to check for regressions**

Run: `swift test`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Capability.swift Tests/ZSharedStateStoreTests/ZShareStateStoreTests.swift
git commit -m "feat: add unknown case to Capability for invalid raw values"
```

---

## Task 5: Move Sample to Separate Target

**Files:**
- Modify: `Package.swift`
- Create: `Sources/Sample/` already exists (no new files)

**Interfaces:**
- Consumes: `ZSharedStateStore` library
- Produces: Separate `ZSharedStateStoreSample` target

- [ ] **Step 1: Add Sample target to Package.swift**

Replace Package.swift content:

```swift
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ZSharedStateStore",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "ZSharedStateStore",
            targets: ["ZSharedStateStore"],
        )
    ],
    targets: [
        .target(
            name: "ZSharedStateStore",
            path: "Sources/Core",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "ZSharedStateStoreBridge",
            dependencies: ["ZSharedStateStore"],
            path: "Sources/Bridge",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "ZSharedStateStoreSample",
            dependencies: ["ZSharedStateStore", "ZSharedStateStoreBridge"],
            path: "Sources/Sample",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "ZSharedStateStoreTests",
            dependencies: ["ZSharedStateStore", "ZSharedStateStoreBridge", "ZSharedStateStoreSample"],
            path: "Tests/ZSharedStateStoreTests",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
```

- [ ] **Step 2: Update AGENTS.md to reflect new structure**

Update Architecture section in AGENTS.md:

```markdown
## Architecture
- **Entry point**: `Sources/Core/DynamicStore.swift` — singleton (`DynamicStore.shared`)
- **Plugin system**: `AppPlugin` protocol, `CapabilityProvider` protocol
- **Obj-C bridge**: `Sources/Bridge/` — wraps `DynamicStore` for Objective-C interop
- **Sample usage**: `Sources/Sample/ZSharedStateStoreSample.swift`
- **Targets**: ZSharedStateStore (Core), ZSharedStateStoreBridge, ZSharedStateStoreSample
```

- [ ] **Step 3: Run full test suite**

Run: `swift test`
Expected: ALL PASS

- [ ] **Step 4: Commit**

```bash
git add Package.swift AGENTS.md
git commit -m "refactor: separate Sample into independent target"
```

---

## Final Verification

- [ ] **Step 1: Run full test suite**

Run: `swift test`
Expected: ALL PASS

- [ ] **Step 2: Build clean**

Run: `swift build`
Expected: No warnings or errors
