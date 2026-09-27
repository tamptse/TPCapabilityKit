# 01: Parameterize one table-owned exchange core beside the duplicates

**What to build:** one parameterized table-owned exchange core added beside the two existing same-identity displacement spellings, so displace-old plus insert-new plus waiter-attach enter in one locked step with the displaced delivery payload and the single stale slot-evict obligation returned for outside-lock handling, and both existing table entries plus both scheduling entries still compile untouched until migration.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] Parameterized exchange core added beside the two existing displacement spellings: single locked transition takes new-Lease intent plus execution plus Tasks waiter list, terminalizes any non-terminal occupant to expired and installs the new pending row already carrying its waiters, returning displaced waiters plus park waiter for outside-lock delivery and cancellation with the evict obligation present exactly on displacement
- [ ] Both existing table entries and both scheduling entries untouched in this ticket; settled-then-evicted-then-inserted observable order, Lease-identity guard, stale slot-evict after unlock never nested, waiter exactly-once delivery, and wedged-continuation safety unchanged
- [ ] Table methods only; scheduling entries' call shapes stable; no Lease edit; park system, Deadline expiry, registry wait, activation gate, settlement decision, slot admission/release, retry identity unchanged
- [ ] `swift build` green and full `swift test` green with zero test-semantics edits; mechanical check shows the new core present beside the two legacy displacement spellings
