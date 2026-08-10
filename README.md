# TPCapabilityKit

A Swift package providing `DynamicStore` — an in-memory state database and capability registry for decoupled plugins in micro-frontend architecture.

## Features

- **Plugin Registration** — Register/unregister plugins with automatic lifecycle management
- **State Management** — Type-safe state storage with Combine reactive observation
- **Capability Registry** — Query and observe plugin capabilities in real-time
- **Async Task Execution** — Run tasks conditionally based on available capabilities
- **Thread Safety** — Single `NSLock` protects all mutable state
- **Objective-C Bridge** — Full interop for legacy ObjC plugins via `ObjcStoreBridge`
- **Strict Concurrency** — Swift 6.1 with strict concurrency checking enabled

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/tamptse/TPCapabilityKit.git", from: "1.0.0")
]
```

Then add the dependency to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: ["TPCapabilityKit"]
)
```

For Objective-C interop, also include:

```swift
.target(
    name: "YourTarget",
    dependencies: ["TPCapabilityKit", "TPCapabilityKitBridge"]
)
```

## Usage

### Basic Plugin

```swift
import TPCapabilityKit

final class UserProfilePlugin: AppPlugin {
    let id = "UserProfilePlugin"
    private var store: DynamicStore?

    func start(with store: DynamicStore) {
        self.store = store
        store.updateState(pluginId: id, newState: UserProfileState(userId: "u123", name: "Alice"))
    }
}
```

### State Observation

```swift
let store = DynamicStore.shared

// Register plugins
store.register(plugin: UserProfilePlugin())
store.register(plugin: ChatPlugin())

// Observe state changes reactively
store.observeState(pluginId: "UserProfilePlugin", type: UserProfileState.self)
    .sink { profile in
        print("User: \(profile.name)")
    }
    .store(in: &cancellables)
```

### Capability Provider

```swift
final class NetworkPlugin: CapabilityProvider {
    let id = "NetworkPlugin"
    let capabilities: Set<Capability> = [.networkAccess, .lightTask]

    func start(with store: DynamicStore) {
        store.updateState(pluginId: id, newState: "Ready")
    }
}

// Query capabilities
let hasNetwork = store.queryCapability(.networkAccess) // true

// Run task only if capability is available
let result = await store.runTask(requiring: .networkAccess) {
    return try await fetchData()
}

// Wait for capability with timeout
let data = await store.runTaskWhenAvailable(capability: .networkAccess, timeout: 5.0) {
    return try await fetchData()
}
```

### Objective-C Integration

```objc
@objc(MyPlugin)
class MyObjCPlugin: NSObject, ObjcAppPlugin {
    let id = "MyObjCPlugin"

    func start(with store: ObjcStoreBridge) {
        [store updateStateWithPluginId:self.id newState:@@"Initial"];
    }
}

// Register via bridge
ObjcStoreBridge.shared().register(plugin: objcPlugin)

// Subscribe to updates
ObjcStoreBridge.shared().subscribe(pluginId: "MyObjCPlugin", queue: nil) { state in
    print("State: \(state)")
}
```

## Architecture

```
Sources/
├── TPCapabilityKit/          # Core library
│   ├── DynamicStore.swift    # Singleton state database + capability registry
│   ├── Capability.swift      # Capability enum + CapabilityProvider protocol
│   └── AppPlugin.swift       # Plugin protocol
├── TPCapabilityKitBridge/    # Objective-C interop bridge
│   ├── ObjcStoreBridge.swift # ObjC bridge singleton
│   ├── ObjcAppPlugin.swift   # ObjC plugin protocol
│   └── ObjcCancellable.swift # ObjC subscription token
└── TPCapabilityKitSample/    # Sample usage examples
```

## Requirements

- Swift 6.1+
- iOS 15+ / macOS 12+
- No external dependencies

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.

You may use this software commercially without restrictions. See the license for full terms including patent grant and attribution requirements.
