# L2 — Lifecycle single insert seam + counts locality

## Problem Statement
`LifecycleStore.exchange` forwards one line to `insert` (depth ~0, interface bloat). `Counts` snapshot maintained incrementally via `move(from:to:)` at 4 writers; invariant rows+queues+counts must be held by discipline, drift-prone.

## Solution
Fuse `exchange` into the single locked insert seam (one entry). Localize counts: keep incremental cache but derive via one `recalc` + `debugInvariant` asserting rows/queues/counts agree after each mutation; no new writer may bypass it.

## User Stories
1. As a scheduler author, I want one insert seam, so that same-id displace is never half-observable.
2. As a maintainer adding a Transition, I want counts auto-consistent, so that I cannot forget a move call.
3. As a test author, I want to assert rows/order, so that counter asserts are unnecessary.

## Implementation Decisions
- Module: Tasks LifecycleStore stays deep; OrderIndex remains private mechanics (per ADR-0017).
- Interface: delete `exchange` forwarder, callers use `insert` (internal). Keep `Counts` value shape; add `debugInvariant()` (rows place vs queues vs snapshot) called in DEBUG after insert/transition/take/dequeue.
- No behavior change: pending=queued+parked, queued/parked/active moves identical. Perf: keep O(1) incremental; recalc only for assert.
- Grill (auto): prefer inline fuse over new protocol; no public API change.

## Testing Decisions
- External only: pending/active counts via facade, dequeue priority order, same-id displace terminalizes old. Prior art: lifecycle/park/dequeue tests.
- Full suite green; no snapshot-text pins touched.

## Out of Scope
- Settlement decision, slot hold, Deadline, registry, Bridge.

## Further Notes
- Independent of L1; blocks T3-style settlement work (same Lifecycle file — land before L6 settlement spec).
