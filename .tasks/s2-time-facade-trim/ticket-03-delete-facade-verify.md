# 03: Delete facade trio and prove sum-vs-share

**What to build:** facade time forwarders gone with the generations gate as the single spelling, plus one snapshot postcondition test proving reconfigure-drain keeps summed counts under one shared limit, so the invariant survives independent of prose.

**Blocked by:** 01 (expose generations time seam beside the facade), 02 (migrate tests to the generations time seam).

**Status:** ready-for-agent

- [ ] Facade time trio deleted (fresh-instance per-forwarder guards go with them); facade keeps production scheduling only with behavior unchanged; mechanical grep proves no facade time forwarder remains and no caller straddles two seams
- [ ] One snapshot postcondition test through the generations seam: two live generations during drain sum pending/active while admission enforces one shared Store-owned limit (reconfigure never doubles the limit, never drops in-flight rows); advance still expires exactly the due waiters once with the shared clock unforked
- [ ] Build plus full test suite green; no time, admission, snapshot-arithmetic, lock-order, or lifecycle semantics change
