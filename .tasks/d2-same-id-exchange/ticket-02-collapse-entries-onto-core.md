# 02: Collapse both table entries onto the single exchange core

**What to build:** both table entries reading only the parameterized exchange core, so the duplicated lookup-displace-insert spelling plus the insert-to-attach window disappear from the table with overwrite and wait behavior identical to today and both scheduling entries' call shapes unchanged.

**Blocked by:** 01 (parameterize one table-owned exchange core beside the duplicates).

**Status:** ready-for-agent

- [ ] Fire-and-forget table entry passes its completion-waiter list through the core; schedule-and-wait table entry wraps its single continuation waiter as a one-element list and maps the core outcome to parked (pumps the pending path) vs settled-early (resumes immediately without pumping or attaching elsewhere)
- [ ] Duplicated lookup-displace-insert spelling deleted so only the core performs displacement; Lease-identity guard lives once in the core with settled-early kept as safety net; birth-attach closes the insert-to-attach window
- [ ] Displaced delivery plus park-waiter cancel keep the take-inside-deliver-outside shape; slot stale-evict stays a separate lock step after the table transition on its own lock, never nested; settled-then-evicted-then-inserted order preserved
- [ ] Table methods only; scheduling entries' call shapes stable (no pump/kick edits); no Lease edit; park, Deadline, registry wait, activation, settlement, slot scope-exit, retry identity unchanged
- [ ] `swift build` green and full `swift test` green with zero test-semantics edits; mechanical check proves only one displacement protocol remains in the table
