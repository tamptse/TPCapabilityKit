# 02: Deterministic ObjC delivery tests proving no product behavior change

**What to build:** proof that the delivery unify lands with predictable threads and zero scheduling-behavior change — deterministic Bridge delivery pins green plus the full suite green.

**Blocked by:** 01 (unify-schedule-delivery).

**Status:** ready-for-agent

- [ ] New behavior pins cross the public Bridge/view seam with continuation rendezvous (no sleeps): `schedule` arrives on the given queue and on main when omitted; both wait spellings agree on the asserted queues; subscription entries remain on the asserted queues as regression guard
- [ ] Scheduling invariance proven: Lease terminal states, cancel, pending/active counts, and retry outcomes identical before/after; existing Bridge single-view, fire-agreement, scheduler integration, and timeout suites green with zero test-semantics edits to scheduling outcome
- [ ] Full `swift build` + `swift test` green; no public API diff beyond the additive delivery-queue default; no Sample file modified
- [ ] Decision recorded: single delivery story at rest per the single-view promise; Sample remains explicitly non-goal with no follow-up deepening spawned from this area
