# 01: Migrate State rendezvous to per-identity waiter table

**What to build:** the State creation rendezvous wakes per identity instead of
globally: observers park on their own Plugin identity, writers drain only that
identity's parkers, and the global counter plus broadcast spelling is gone.
Behavior through the Store facade is bit-identical with zero test edits.

**Blocked by:** None (can start immediately; no external candidate blocks this work).

**Status:** ready-for-agent

- [ ] Observer miss parks on its own Plugin identity; writer hit-or-insert drains only that identity's parker list (copied under lock, resolved after unlock adjacent to the value publish); global counter plus broadcast spelling deleted with no per-notice re-check chain remaining
- [ ] Locked work stays index read-or-insert plus waiter park-or-drain-list copy only; all publishes emit after unlock; per-subscription re-entry plus waiter-to-subject switch topology preserved; removal stays out of band (deletes index entry, completes detached subject, never touches the table); empty-id guards stay at owner entries; typed filtering stays at the observation edge
- [ ] No public seam change; no new module or file; diff constrained to the State region only with zero hunks in the scheduling-generations region
- [ ] Zero test files modified; `swift build` green plus full `swift test` green (in particular StateLifecycle, StateWaiterIsolation, ObservationNarrowing suites)

**Test command:** `swift build` then `swift test`
