# 01: Share the release consideration with limit change plus raise/lower pins

**What to build:** The limit entry stops mutating silently and crosses the same consideration path as release: update the caps, then scan the arrival queue from the head admitting every fitting waiter in order via the atomic install under one lock hold, resuming the admitted batch outside the lock in arrival order. End-to-end through the scheduling facade: raising a cap wakes fitting waiters on the reconfigure itself (blocked head overtaken by fitting followers, head following when its demand frees), lowering a cap admits nobody and overshoots nothing, mixed changes admit only the new headroom. Admission rules are bit-identical on both wake sources (first-fit FIFO with skip, skipped waiter keeps place, newcomers park behind queued waiters, one consideration bounded by headroom); scope-exit release stays the single release and the limit path never releases.

**Blocked by:** D1 explicit reap/settle points with reconfigure shape preserved (hard, external — the wake must hook the explicit point, not the old getter-triggered reap); D4 pump drain notification hook (transitive via D1, external — woken-waiter activation traffic lands on the coalesced pump). No local blocker (first in chain).

**Status:** ready-for-agent

- [ ] One shared scan-plus-install consideration crossed by both release and limit change; no second limit-scan spelling; batch resumes outside the lock in arrival order on both paths
- [ ] Facade pins: raise wakes fitting waiters in order (heterogeneous overtake plus homogeneous FIFO unchanged); lower-change admits nobody; mixed change admits only new headroom; limits never overshot; newcomer still parks behind queued waiters; duplicate rejection, cancellable wait, and eviction intents unchanged
- [ ] Scope-exit release stays the single release (limit path installs only); `swift build` green and full `swift test` green with zero test-semantics edits to pre-existing suites
