# 02: Migrate tests to the generations time seam

**What to build:** every deterministic-time test crosses the narrower generations seam instead of the facade, so deletion of the facade trio becomes mechanical with no behavior change.

**Blocked by:** 01 (expose generations time seam beside the facade).

**Status:** ready-for-agent

- [ ] All enable call sites (order of a dozen files plus the shared deterministic fixture flag) re-pointed to the generations seam; all advance/wait call sites re-pointed likewise; live-generation-count reads stay with the counts seam per the spec tie-break
- [ ] Zero behavior-semantics edits: enable-before-first-schedule succeeds, enable-after-first-schedule traps, enable-on-shared traps, advance expires exactly the due waiters once, waiter rendezvous synchronizes, reconfigure never forks virtual time — all asserted through the generations seam, never the adapter directly
- [ ] Full suite green batch by batch (fixture first, then per-file batches); no production, admission, snapshot-arithmetic, lock-order, or lifecycle semantics change
