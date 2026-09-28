# 02: Narrow waiter facade to UI pair plus Tasks-only waiter with proofs

**What to build:** the Store readiness facade reads as two documented grains (UI pair vs Tasks-only waiter) with the registry remaining the single set-matching owner, proven by behavior through the public query/observe/wait seam; helpers kept, prose grouped, no seam cut.

**Blocked by:** 01 (Collapse triple check into one documented availability gate).

**Status:** ready-for-agent

- [ ] Facade grouped by prose into UI pair (single-capability query plus per-capability Bool observation for UI-style subscribers) vs Tasks-only waiter (whole-snapshot observation plus whole-set wait for the scheduler); all four thin delegations kept, no method deleted, rebuilding the wait in callers out of snapshot observation plus re-query explicitly rejected in prose
- [ ] Registry seam unchanged: Bool race received as an opaque value with the expiry owner never named (R4-compatible), empty-set and already-satisfied fast paths untouched, per-Capability-before-snapshot emission order untouched, park/expiry/activation/settlement staying in Tasks
- [ ] Proofs added through the public seam with deterministic time: RegistryWait (empty-set skip, already-satisfied skip, missing/partial-set expiry, arriving-set resolve), EmissionOrder (per-Capability before snapshot on register and unregister), FireAgreement (missing/nil agreement, available/value agreement, waiter-convenience parity, slot-pressure divergence as bypass contract)
- [ ] Verify: `swift test --filter CapabilityRegistryWait` green, `swift test --filter RegistryEmissionOrder` green, `swift test --filter FireAgreement` green, `swift test --filter ActivationGate` green; full `swift test` green with zero test-semantics edits except the new pins
