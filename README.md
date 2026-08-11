# TPCapabilityKit

A Swift package providing `DynamicStore` — an in-memory state database and capability registry for decoupled plugins in micro-frontend architecture.

## Features

- **Plugin Registration** — Register/unregister plugins with automatic lifecycle management
- **State Management** — Type-safe state storage with Combine reactive observation
- **Capability Registry** — Query and observe plugin capabilities in real-time
- **Async Task Execution** — Run tasks conditionally based on available capabilities
- **Centralized Task Scheduling** — Priority queues, capability-based routing, and lease lifecycle
- **Concurrency Control** — Actor-based limiter with per-capability and global limits
- **Protocol-based Design** — `TaskSchedulerProtocol` enables A/B testing of scheduling implementations
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

### Centralized Task Scheduling

```swift
import TPCapabilityKit

// Schedule a task with capability matching and priority
let descriptor = TaskDescriptor(
    requiredCapabilities: [.networkAccess, .backgroundExecution],
    priority: .high,
    timeout: 30.0,
    maxRetries: 2
)

// Schedule and wait for result
let result = await store.scheduleTaskAndWait(descriptor) {
    return try await fetchData()
}

// Or schedule with completion handler
let lease = store.scheduleTask(descriptor) {
    await processInBackground()
} completion: { lease in
    switch lease.state {
    case .completed: print("Done")
    case .failed: print("Failed")
    case .expired: print("Timeout")
    default: break
    }
}

// Cancel a pending task
store.scheduler.cancel(taskId: descriptor.id)

// Check pending/active counts
print("Pending: \(store.scheduler.pendingCount)")
print("Active: \(store.scheduler.activeCount)")
```

### A/B Testing with Protocol

```swift
// Create custom scheduler implementation
final class MyCustomScheduler: TaskSchedulerProtocol {
    // Implement protocol methods
    func schedule(_ task: TaskDescriptor, ...) -> Lease { ... }
    func scheduleAndWait<T: Sendable>(_ task: TaskDescriptor, ...) async -> T? { ... }
    func cancel(taskId: String) { ... }
    var pendingCount: Int { 0 }
    var activeCount: Int { 0 }
    var events: AnyPublisher<TaskScheduler.SchedulerEvent, Never> { ... }
}

// Replace default scheduler
store.scheduler = MyCustomScheduler(store: store)

// A/B test different implementations
let schedulerA = TaskScheduler(store: store)  // Default
let schedulerB = MyCustomScheduler(store: store)  // Custom

// Use based on experiment
if experiments.isEnabled("new-scheduler") {
    store.scheduler = schedulerB
}
```

### Objective-C Integration

```objc
// Task Scheduling via Bridge
TPTaskDescriptor *descriptor = [[TPTaskDescriptor alloc] 
    initWithCapabilities:@[@"networkAccess"] 
    priority:4 
    timeout:30.0 
    maxRetries:2 
    metadata:@{@"source": @"objc"}];

// Schedule and wait for result
[[TPStoreBridge shared] scheduleTaskAndWait:descriptor 
    task:^NSObject *{
        return [self fetchData];
    } 
    completion:^(NSObject *result) {
        NSLog(@"Result: %@", result);
    }];

// Cancel a task
[[TPStoreBridge shared] cancelTaskWithTaskId:descriptor.id];

// Check counts
NSLog(@"Pending: %ld", [TPStoreBridge shared].pendingTaskCount);
NSLog(@"Active: %ld", [TPStoreBridge shared].activeTaskCount);
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
├── TPCapabilityKit/              # Core library
│   ├── DynamicStore.swift        # Singleton state database + capability registry
│   ├── Capability.swift          # Capability enum + CapabilityProvider protocol
│   ├── AppPlugin.swift           # Plugin protocol
│   ├── TaskSchedulerProtocol.swift # Protocol for A/B testing
│   ├── TaskScheduler.swift       # Centralized task scheduler
│   ├── TaskDescriptor.swift      # Task metadata (capabilities, priority, timeout)
│   ├── TaskPriority.swift        # Priority levels (background → critical)
│   ├── Lease.swift               # Task lifecycle management
│   └── ConcurrencyController.swift # Actor-based concurrency limiter
├── TPCapabilityKitBridge/        # Objective-C interop bridge
│   ├── ObjcStoreBridge.swift     # ObjC bridge singleton + scheduling APIs
│   ├── ObjcAppPlugin.swift       # ObjC plugin protocol
│   ├── ObjcCancellable.swift     # ObjC subscription token
│   ├── ObjcTaskDescriptor.swift  # ObjC wrapper for TaskDescriptor
│   ├── ObjcLease.swift           # ObjC wrapper for Lease
│   └── ObjcTaskScheduler.swift   # ObjC wrapper for TaskSchedulerProtocol
└── TPCapabilityKitSample/        # Sample usage examples
```

## Requirements

- Swift 6.1+
- iOS 15+ / macOS 12+
- No external dependencies

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.

You may use this software commercially without restrictions. See the license for full terms including patent grant and attribution requirements.
