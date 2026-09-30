# N5-02: Rewire Bridge subscribes to thin forwards

**What to build:** Both Bridge subscribe entries forward observer plus queue to the door factory and return the token untouched, so lifetime duplication leaves the Bridge view.

**Blocked by:** n5-01 (needs factory present before Bridge can forward).

**Status:** ready-for-agent

- [ ] Both subscribe entries read as thin translators with no direct publisher plumbing or token boxing at the Bridge level
- [ ] Public Bridge subscribe signatures and delivery behavior unchanged for callers
- [ ] Full suite green; delivery-unify plus single-view suites prove no routing or lifetime drift
