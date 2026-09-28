# 01: Fuse single table-owned exchange transition

**What to build:** one table-owned exchange transition added beside the existing lookup-plus-settle-plus-insert caller spelling, so displace-old plus insert-new enter in one locked step returning displaced-terminal vs fresh-insert with displaced waiters taken for outside-lock delivery, and the old caller path still compiles until migration.

**Blocked by:** None (can start immediately; read the park-single-seam spec plus its tickets first and keep transition naming consistent with its fused park seam; assumes lease-terminal-unify plus slot-eviction-unify post-state).

**Status:** ready-for-agent

- [ ] Fused exchange seam added beside legacy lookup/settle/insert: single locked transition takes new Lease intent plus execution and waiters, terminalizes any non-terminal occupant to expired and installs the new pending row atomically, returning displaced waiters plus park waiter for outside-lock delivery and cancellation; terminal occupant and fresh id flow as insert without settle
- [ ] Displaced waiter delivery plus park-waiter cancel keep the terminal-take shape (taken inside, delivered and cancelled outside the lock); slot stale-evict primitive untouched, still called after the table exchange on its own lock, never nested
- [ ] Park fusion, dequeue-to-parked placement, Deadline expiry, registry whole-set wait, activation gate, settlement policy, slot admission/release, retry identity unchanged; no Lease edit
- [ ] `swift build` green and full `swift test` green with zero test-semantics edits; grep shows fused exchange present beside legacy lookup-plus-settle-plus-insert
