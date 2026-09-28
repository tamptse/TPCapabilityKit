# 03: Lock the single-writer contract beside the unified type

**What to build:** a committed single-writer contract so no future path mutates a Lease outside the lifecycle-table transition, keeping the unify from drifting back into parallel writers.

**Blocked by:** 02 (fuse decide into the single row-transition site).

**Status:** ready-for-agent

- [ ] Contract stated once beside the unified type: each Lease mutation pairs with its row write under the scheduler lock; direct mutator calls from new paths forbidden
- [ ] Grep evidence: no caller outside the lifecycle table invokes the internal mutators; no `Decision` reference remains
- [ ] Public `State` seam and Bridge live-view reflection verified unchanged (`swift build` + full `swift test` green)
- [ ] No behavior delta: terminal reachability, retry identity, and slot-release ownership unchanged
