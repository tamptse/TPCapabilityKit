# 02: Migrate Path caller to the single park seam

**What to build:** the single Path park caller crossing the fused seam once, so the three-lock protocol plus wedged allocation plus terminal-cancel patch disappear from the caller with park behavior identical to today.

**Blocked by:** 01 (fuse single table-owned park transition).

**Status:** ready-for-agent

- [ ] Park caller hands intent plus waiter through the fused seam in one crossing; no allocation sits between two lock acquisitions and no caller-side already-terminal cancel patch remains
- [ ] Wake path relies on table-internal clear; terminal path relies on table row-take-and-cancel; no caller-side clear call remains on either path
- [ ] Legacy begin/set/clear table methods deleted; grep proves no caller-side park protocol remains
- [ ] Deadline expiry, registry wait value-passing, activation, settlement, slot scope-exit unchanged
- [ ] `swift build` green and full `swift test` green with zero test-semantics edits
