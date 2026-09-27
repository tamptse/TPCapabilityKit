# 03: Full verify — build, suite, spelling and region grep

**What to build:** final verification that the per-identity migration landed
with zero seam, contract, or region drift: clean build, full suite green, old
global spelling gone, and the scheduling-generations region untouched.

**Blocked by:** 01, 02 (verifies the final tree after migration plus new pins).

**Status:** ready-for-agent

- [ ] `swift build` green with no warnings introduced by the migration
- [ ] Full `swift test` green (in particular StateLifecycle, StateWaiterIsolation, ObservationNarrowing, plus the ticket-02 pins)
- [ ] Grep confirms no global creation-counter or broadcast spelling remains in the State region, no test references State internals (owner, table, counter, broadcast), no public signature or file-split change, and the scheduling-generations region is undiffed

**Test command:** `swift build` then `swift test`
