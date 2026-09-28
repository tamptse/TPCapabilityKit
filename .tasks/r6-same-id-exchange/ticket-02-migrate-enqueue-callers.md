# 02: Migrate enqueue funnel to the single exchange seam

**What to build:** the single enqueue funnel crossing the fused exchange once, so the three-lock lookup-plus-settle-plus-insert protocol plus the half-displaced id window disappear from the caller with overwrite behavior identical to today.

**Blocked by:** 01 (fuse single table-owned exchange transition).

**Status:** ready-for-agent

- [ ] Enqueue caller hands new Lease intent through the fused exchange in one scheduler-lock crossing, then calls the untouched slot stale-evict primitive once on its own lock after the exchange returns, never nested; no caller-side settle or lookup remains on the overwrite path
- [ ] Facade-observable order preserved: displaced Lease terminal before stale slot evict before new row observable as taking the id; sequential reuse after terminal flows through the same seam as fresh insert
- [ ] Legacy caller-side lookup-plus-settle-plus-insert spelling deleted; grep proves no caller-side displace protocol remains and no park-fusion seam renamed or re-spelled
- [ ] Deadline expiry, registry wait value-passing, activation, settlement, slot scope-exit, retry identity unchanged; no Lease edit
- [ ] `swift build` green and full `swift test` green with zero test-semantics edits
