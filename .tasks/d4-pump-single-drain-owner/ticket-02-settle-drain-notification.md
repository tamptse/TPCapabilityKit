# 02: Add settle-drain notification for reconfigure and settle points

**What to build:** one settle/drain notification callable from explicit reconfigure and settle points, so a generation landing drained wakes the reaper without any getter triggering the reap.

**Blocked by:** 01 (unify flag plus rechecks into one drain owner).

**Status:** ready-for-agent

- [ ] Single void settle/drain hook added beside the unified owner: fired outside the scheduler lock when terminal settlement lands a generation drained, carrying at most generation identity, plus callable from explicit reconfigure points; no delegate protocol, no polling seam
- [ ] Store-to-Tasks lock order preserved: notification never fires under the scheduler lock, adjacent to waiter delivery; drained predicate (empty pending plus active from one acquisition) unchanged; reap stays on its current path in this ticket
- [ ] Kick entry shape, dequeue order, park reachability, activation, settlement delivery, and counts unchanged; hook is additive until the pin ticket proves it
- [ ] `swift build` green and full `swift test` green with zero test-semantics edits
