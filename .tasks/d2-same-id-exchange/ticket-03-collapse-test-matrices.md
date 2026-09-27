# 03: Collapse the two same-identity test matrices to one

**What to build:** one same-identity pin suite covering both scheduling entries through the public seam, so overwrite, cancel-during-overwrite, and waiter-guard behavior are each pinned once with production code untouched.

**Blocked by:** 02 (collapse both table entries onto the single exchange core).

**Status:** ready-for-agent

- [ ] Overwrite pin: concurrent same-identity schedules through both entries expire the old Lease exactly once with completion delivered and the new Lease completing, with counts draining to zero and stale slot resume landing on an already-terminal Lease
- [ ] Cancel-during-overwrite pin: cancel resolves against exactly one row (old-terminal or new-pending) with exactly-once waiter delivery and no half-displaced absence; sequential reuse after terminal still works; schedule-and-wait cancel of a pending wait delivers nil exactly once
- [ ] Waiter-guard pin: schedule-and-wait attach against a displaced identity never appends to another Lease's waiter list; displaced parked waiter cancelled exactly once; retry preserves the waiter to recovery; enqueue without displacement evicts nothing
- [ ] Duplicate same-identity pins merged so each behavior exists once covering both entries; production code untouched in this ticket except test files
- [ ] `swift build` green and full `swift test` green
