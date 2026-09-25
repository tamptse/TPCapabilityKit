# 01: Fuse table-owned enqueue-and-park rendezvous beside legacy

**What to build:** one table-owned rendezvous transition added beside the existing enqueue-then-attach spelling, so new-row insert plus continuation-waiter park enter in one locked step returning parked vs already-settled, with the old entry path still compiling until migration.

**Blocked by:** S1 enqueue-funnel shape (conceptual; sequence this ticket after that work lands and write the fused transition against its post-state). No ticket in this slice gates it otherwise.

**Status:** ready-for-agent

- [ ] Fused rendezvous seam added beside legacy: single locked transition takes new-lease intent plus execution plus continuation waiter, displaces any non-terminal occupant for the same identity to expired and installs the new pending row already carrying the waiter, returning parked vs already-settled (no row or foreign row or already-terminal lease) with displaced waiters plus park waiter taken for outside-lock delivery and cancellation
- [ ] Identity check lives inside the fused transition: a mismatched row provably returns the settled lease and never appends to another lease's waiter list; settled-early resume stays a safety-net branch, not caller patch
- [ ] Displaced delivery plus park-waiter cancel keep the existing take-inside-deliver-outside shape; slot stale-evict primitive untouched, still called after the table transition on its own lock, never nested
- [ ] Capability-wait park system, deadline expiry, registry whole-set wait, activation gate, settlement decision, slot admission/release, retry identity unchanged; no lease-shape edit
- [ ] Build green and full test suite green with zero test-semantics edits; mechanical check shows fused rendezvous present beside legacy enqueue-then-attach
