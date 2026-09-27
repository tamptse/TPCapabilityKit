# 01: Add pure read view and settle reap entry beside getters

**What to build:** a pure generations read (lock, copy, sum, report with no drain question and no mutation) and a settle-triggered reap entry routing to the one named reap pass land beside the current reaping snapshot, with zero observable change through the public scheduling seam (getters still delegate to the reaping snapshot; the new spelling is present but not yet the live path).

**Blocked by:** None (can start immediately; sequencing note: D4 pump single-drain-owner owns (a) the single-kick drain lifecycle, (b) the settle/drain notification shape, (c) the re-proven monotonic-drain invariant — this ticket must consume that contract later, not invent pump internals now).

**Status:** ready-for-agent

- [ ] Pure view added beside the reaping snapshot: back-to-back count reads with no explicit reap change nothing (generation count stable, pending/active identical); mechanical grep shows the new view asks no drain state and mutates nothing
- [ ] Settle-triggered reap entry added routing only to the named reap pass (idempotent; no admission, parking, or settlement work moves into it); reconfigure path and all getters behavior-identical
- [ ] No second reap spelling introduced: the Store-to-Tasks crossing still exists only at the named pass; current-never-reaped and the sum-vs-share split unchanged
- [ ] `swift build` green and full `swift test` green with zero test-semantics edits
