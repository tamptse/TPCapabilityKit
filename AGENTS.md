# TPCapabilityKit

## What it is
A Swift package providing `DynamicStore` — an in-memory state database and capability registry for decoupled plugins in micro-frontend architecture.

## Build & Test
- **Build**: `swift build` (Swift 6.1, strict concurrency enabled)
- **Test**: `swift test` (uses Swift Testing framework, not XCTest)
- **Test files**: `Tests/TPCapabilityKitTests/`
- **No lint/format/typecheck commands** — pure Swift package with no external tooling

## Architecture
- **Entry point**: `Sources/TPCapabilityKit/DynamicStore.swift` — singleton (`DynamicStore.shared`)
- **Plugin system**: `AppPlugin` protocol (single canonical protocol)
- **Obj-C bridge**: `Sources/TPCapabilityKitBridge/` — wraps `DynamicStore` for Objective-C interop
- **Sample usage**: `Sources/TPCapabilityKitSample/TPCapabilityKitSample.swift`
- **Targets**: TPCapabilityKit (Core), TPCapabilityKitBridge, TPCapabilityKitSample

## Key Patterns
- `DynamicStore.shared` is a singleton; tests mutate shared state (clean up after tests)
- State stored as `Any?` with type-safe access via generics
- Capability registry uses `Set<Capability>` per plugin
- Combine publishers for reactive observation

## Monorepo Context
- Build excludes `Tests/**` and `Sources/TPCapabilityKitSample/**`
- Modular Swift package with tests enabled
