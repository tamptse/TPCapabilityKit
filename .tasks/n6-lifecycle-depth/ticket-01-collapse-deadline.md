# 01: Collapse Deadline into Path-private race helper

**What to build:** one shared expiry race spelled beside the Tasks flow instead of a named cross-seam Deadline type, so waiter and executor share one timeout with the registry never naming the type and all expiry behavior identical to today.

**Blocked by:** None (can start immediately). Note: sequence after N1 (terminal unify) and N4 (slot-eviction unify) first — same Path/Lifecycle core.

**Status:** ready-for-agent

- [ ] Deadline type deleted into a Path-private race helper; timeout still resolves once from task plus configured default and one race still shared by capability wait and execution
- [ ] Registry whole-set wait keeps receiving the race as a value and never names the Tasks expiry type; live/virtual adapters and advance policy untouched
- [ ] TOCTOU window (entry check vs post-admission re-check across hold suspension) stated once beside activation; pure extractions kept, not inlined
- [ ] Full test suite green with zero test-semantics edits; grep proves no Deadline type remains
