# 01: Split sample god-function into self-cleaning slices

**What to build:** `runExample` becomes a thin orchestrator over four per-feature slices — state, capability, scheduling, ObjC Bridge — each readable alone and each cleaning up what it touched, with the demo order and console behavior unchanged.

**Blocked by:** None (can start immediately).

**Status:** verify-only (landed — runExample 385-397 delegates to 4 slices; see spec STALE header)

- [ ] `runExample` delegates to `runStateExample` / `runCapabilityExample` / `runSchedulingExample` / `runObjCBridgeExample` in the current demo order; no step deleted or reordered from the caller's perspective
- [ ] Each slice takes the Store/Bridge (shared instances) as parameters and self-cleans: Swift plugins unregistered, temp states removed, cancellables released, scheduler config restored to `.default`
- [ ] No product-target change: only the Sample target is edited; Store facade seam and Bridge adapter seam are leveraged as-is; no new seam, no `DynamicStore.init` promotion, no Bridge unregister added
- [ ] ObjC-plugin leak documented in place (Bridge has no unregister seam) rather than worked around
- [ ] `sampleUsageRunsCleanly` passes; `swift build` green
