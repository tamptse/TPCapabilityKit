# 01: Fuse single table-owned park transition

**What to build:** one table-owned park transition added beside the existing three-step protocol, so park intent plus waiter enter in one locked step returning parked vs already-terminal with wake/terminal clear owned inside, and the old methods still exist until migration.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] Fused park seam added beside existing begin/set/clear: single locked transition takes park intent plus waiter (or non-suspending factory invoked under the transition) and returns parked vs already-terminal; double-park refusal stays in the table
- [ ] Wake-clear and terminal-take-and-cancel owned inside the table; no new caller protocol introduced in this ticket, old three methods untouched so existing caller still compiles
- [ ] Deadline expiry, registry whole-set wait, activation gate, settlement, slot admission/release, retry identity unchanged
- [ ] `swift build` green and full `swift test` green with zero test-semantics edits; grep shows fused seam present beside legacy begin/set/clear
