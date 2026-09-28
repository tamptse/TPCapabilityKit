## Problem Statement

> Status (2026-09-27 grill): STALE — both slices already landed in code. `runExample` is now a thin orchestrator (`TPCapabilityKitSample.swift:385-397`) over `runStateExample` (137-175), `runCapabilityExample` (177-204), `runSchedulingExample` (206-266), `runObjCBridgeExample` (268-382). `TaskPriority` is already synthesized (`TaskPriority.swift:6`, 26-line file, no manual extension). Original rationale preserved below; do not re-implement.

`TPCapabilityKitSample.runExample()` (originally `Sources/TPCapabilityKitSample/TPCapabilityKitSample.swift:138-374`) was a ~240-line god-function with 21 numbered steps covering State, Capability, `runTask`/`runTaskWhenAvailable`, scheduling, configuration, and ObjC Bridge in one locality. It drives the Store facade through `DynamicStore.shared` plus `ObjcStoreBridge.shared`, and its cleanup is partial: it unregisters `profilePlugin`/`chatPlugin`/`networkPlugin` and removes `TempPlugin` state, but the `SampleObjcPlugin` adapter registered via the Bridge has no unregister path and scheduler reconfiguration side-effects linger until explicitly restored. The only test seam covering it is `sampleUsageRunsCleanly` (`Tests/TPCapabilityKitTests/TPCapabilityKitCoreTests.swift:230-232`), which asserts "runs without crashing" — so drift here is silent.

Separately, `TaskPriority` (originally `Sources/TPCapabilityKit/TaskPriority.swift:28-32`) carried a manual `allCases` extension even though the enum is a plain `Int` enum with no associated values and already conforms to `CaseIterable` semantics — now resolved: declaration at `TaskPriority.swift:6` is `public enum TaskPriority: Int, Comparable, CaseIterable, Sendable, CustomStringConvertible`, manual extension deleted, file is 26 lines.

Two apparent shallows turn out to be load-bearing and must be kept: `Capability.description` returning `rawValue` (`Sources/TPCapabilityKit/Capability.swift:25-27`) is the documented ObjC-bridge/debug string per the domain glossary, and `ObjcDelivery` (`Sources/TPCapabilityKitBridge/ObjcDelivery.swift:4-7`) is the single given-or-main delivery point behind the Bridge — deletion-tested, keep as-is. `ObjcCancellable` (27 lines) is likewise a thin lifecycle wrapper, not a deepening target.

## Solution

Narrow, doc-only cleanup with zero product-seam change:

1. Split `runExample` into per-feature functions — `runStateExample`, `runCapabilityExample`, `runSchedulingExample`, `runObjCBridgeExample` — each taking the Store/Bridge as parameters, each self-cleaning (unregister what it registers, remove what it writes, restore what it configures). Keep `runExample` as a thin orchestrator preserving the current demo order so the existing `sampleUsageRunsCleanly` seam still passes unchanged.
2. Synthesize `TaskPriority.allCases` via `CaseIterable` (move conformance to the declaration, delete the manual extension). No ordering, `description`, or `Comparable` behavior change.
3. Explicitly keep `ObjcDelivery`, `Capability.description`, and `ObjcCancellable` untouched.

This is speculative, low priority, and excluded from the product build (`TPCapabilityKitSample` is a separate target, not in the `products` library in `Package.swift`). It improves sample readability and removes one drift vector, but deepens no product module.

## User Stories

1. As a sample reader, I want state vs capability vs scheduling vs ObjC Bridge demos in separate functions, so that I can read one feature without scrolling 240 lines.
2. As a test author, I want each sample slice to clean up after itself, so that `sampleUsageRunsCleanly` does not leak `SampleObjcPlugin`/scheduler config into `DynamicStore.shared` for neighboring tests.
3. As a Store maintainer, I want the sample to keep using the existing Store facade seam (`register`/`update`/`get`/`observe`, `query`/`observeCapability`, scheduling facade) with no new seam, so that sample churn never forces prod API change.
4. As a Bridge consumer, I want the ObjC Bridge demo isolated in one function, so that the single scheduling adapter (`taskScheduler` live view) usage is reviewable in one locality.
5. As a Tasks maintainer, I want `TaskPriority.allCases` synthesized, so that adding a priority cannot silently diverge from the manual list.
6. As a Bridge maintainer, I want `ObjcDelivery` and `Capability.description` untouched, so that the given-or-main delivery policy and ObjC wire strings stay stable.

## Implementation Decisions

- **Modules touched:** `TPCapabilityKitSample` (sample locality only) and `TaskPriority` value type. No changes to `DynamicStore`, `CapabilityRegistry`, Tasks/Scheduler, Settlement/Lease, Time, or Bridge adapter modules.
- **Interfaces preserved:** `TPCapabilityKitSample.runExample()` keeps its spelling and demo order (thin orchestrator); `TaskPriority` keeps its cases, raw values, `description`, and `Comparable`; the Store facade seam and the Bridge `TPStoreBridge` adapter seam are leveraged as-is, no new seam introduced.
- **Depth verdict:** Sample is documentation, not a deep module — splitting increases locality focus but adds no depth. `TaskPriority` synthesis removes a shallow duplicate. `Capability.description`, `ObjcDelivery`, `ObjcCancellable` already sit at the right depth (thin translators/wrappers over one seam) — deepening them would add interface without leverage.
- **Seam choice:** Highest existing seams only — sample calls the public Store facade and the public Bridge view (`bridge.taskScheduler`, `bridge.queryCapability`, `bridge.runTask*`, `bridge.subscribe`). No `@testable` reach into State/registry/generations, no new scheduler seam, no new delivery helper.
- **Fresh-instance rejected:** `DynamicStore.init(configuration:)` is `internal` (`Sources/TPCapabilityKit/DynamicStore.swift:33`); the Sample target (non-testable dependency) cannot construct a fresh instance without promoting the initializer to public. Opening a prod seam to benefit excluded sample code is rejected — slices keep using `.shared` with disciplined self-cleaning instead.
- **Locality split:** `runStateExample` (register/order-agnostic observe/sync read/update/removeState), `runCapabilityExample` (query/observe/unregister), `runSchedulingExample` (schedule/scheduleAndWait/cancel/counts/configure), `runObjCBridgeExample` (subscribe/cancel, runTask, runTaskWhenAvailable, ObjC scheduling). Shared `cancellables`/plugins passed in or scoped per-slice; each slice unregisters/removes/restores what it touched. Adapter `PluginObjcAdapter` (Bridge-internal) stays untouched — sample cannot unregister ObjC plugins, so the ObjC slice documents the leak rather than working around it.
- **TaskPriority synthesis:** declare `public enum TaskPriority: Int, Comparable, CaseIterable, Sendable, CustomStringConvertible`, delete the `extension TaskPriority: CaseIterable` manual `allCases`. Compiler-synthesized order follows declaration order (`background, low, normal, high, critical`), identical to the manual list.
- **Adapter leverage:** both descriptor-creation paths and the wait-then-run entry continue to cross the existing mapper-owned timeout fork; sample scheduling slices pass explicit timeouts so the omitted-vs-unspecified fork is never perturbed.
- **What stays:** `ObjcDelivery.on(_:execute:)` (single given-or-main helper), `Capability.rawValue`/`description`/`init(rawValue:)` round-trip, `ObjcCancellable.cancel()` + `deinit` — no edits, no renames.

## Testing Decisions

- A good test crosses the same seam as callers: sample verification goes through the public `runExample()` orchestrator, not per-slice internals; `TaskPriority` verification goes through ordering/`description`/`allCases` behavior, not source inspection.
- **Modules tested:** Sample via existing `sampleUsageRunsCleanly` (runs cleanly, no crash, suite green); `TaskPriority` via existing priority/scheduler tests plus an `allCases`-order assertion if one does not already exist (declaration order, count 5).
- **Prior art:** `TPCapabilityKitCoreTests.sampleUsageRunsCleanly`, scheduler integration tests using `TaskPriority.high`, bridge timeout/display/delivery tests (untouched, must stay green as regression guard).
- No new `@testable` access, no new test-double mechanism, no virtual-time change. Full `swift test` green is the gate.

## Out of Scope

- Any change to `ObjcDelivery`, `ObjcCancellable`, `Capability.description`/`rawValue`, or the ObjC timeout mapper fork.
- Promoting `DynamicStore.init` to public to give the sample a fresh instance; adding `unregister` to `ObjcStoreBridge`; changing virtual-time rendezvous, slot admission, Settlement/Lease, or registry whole-set wait.
- New `@objc` spellings, new scheduling Configuration knobs, or any product-target API change.
- Deleting or reordering demo steps in ways visible to downstream docs beyond the orchestrator's preserved order.

## Further Notes

- **Grill verdict (grill-with-docs, autonomous, 2026-09-27 re-grill):** STALE / DONE — solution sections 1-2 already match current code (four self-cleaning slices + thin orchestrator preserving demo order; synthesized `allCases`; ObjC leak documented at `TPCapabilityKitSample.swift:273-275`; scheduler restore at `:264`). Original verdict preserved: CONDITIONAL GO, narrowed scope only. Worth doing iff cost stays at ~2 trivial slices: sample readability has real but small leverage (onboarding/docs), and `allCases` synthesis removes a real drift vector at near-zero risk. Not worth expanding: the sample is excluded from the product build, so no product depth is gained; any attempt to "fix" Bridge/Capability shallows would trade proven thin adapters for interface churn. Priority: low — schedule as filler when the sample area is touched anyway, never ahead of Tasks/Lease/Settlement/Slot/Time/Store-facade deepenings.
- **Scope-safety record:** fresh-instance-per-slice was proposed and rejected (would require opening `DynamicStore.init`); ObjC-plugin leak cannot be fixed from the sample side (no Bridge unregister seam) — document, don't work around. Cleanup inventory for slices: Swift plugins unregister + `removeState` for temp ids + `cancellables.removeAll()` + `configureScheduler(.default)` restore.
- No ADR needed (reversible, unsurprising, no hard trade-off beyond the rejected fresh-instance option recorded here). No `CONTEXT.md` change (no domain term changes; `Capability.description derives from rawValue` already stated).
