# 02: Prove sum-vs-share as a single snapshot postcondition

**What to build:** behavioral proof that reconfigure-drain keeps summed counts with a shared slot limit, so the promoted invariant survives the trim independent of the comment.

**Blocked by:** 01 (trim facade time delegation to Generations-only seam).

**Status:** ready-for-agent

- [ ] One snapshot postcondition test through the generations seam: two live generations during drain sum pending/active while admission enforces one shared Store-owned limit (reconfigure never doubles the limit, never drops in-flight rows)
- [ ] Advance still expires exactly the due virtual waiters once with the shared clock unforked across reconfigure; enable-after-first-schedule still traps; all assertions cross the generations seam, never `Clock` / `VirtualTime` directly
- [ ] `swift build` + full `swift test` green; no time, admission, snapshot-arithmetic, lock-order, or lifecycle semantics change
