# 03: Pin the limit-wake policy and verify full-suite green

**What to build:** The limit-wake policy becomes explicit and provable: raise-wakes / lower-no-ops / mixed-bounded-by-headroom plus the slot-self-wakes argument is stated once beside the consideration step, so a future reconfigure-pumps-Tasks rewrite must answer the lock-order evidence. End-to-end verifiable through the scheduling facade: a heterogeneous stress mix under a raised cap completes with no idle-capacity stall (blocked heads overtaken, all leases terminal, counts drain to zero), unbounded-ward raises drain every fitting waiter, gate-refused woken waiters return their slots through the single scope-exit release and the cascade continues, and Bridge behavior is identical from Objective-C.

**Blocked by:** 02 (hook the wake into the explicit point with reconfigure shape preserved); D1 explicit reap/settle points with reconfigure shape preserved (hard, external, inherited); D4 pump drain notification hook (transitive via D1, external, inherited).

**Status:** ready-for-agent

- [ ] Policy stated once beside the consideration step (shared first-fit FIFO with skip on both wake sources; any-change-triggers with admission-decides; slot-self-wakes with reconfigure shape preserved; explicit-point-only hook) with the never-overshoot and no-strand arguments
- [ ] Facade stress pins: raise-then-drain completes with all terminal and counts zero; unbounded-ward raise drains fitting queue; refusal cascade continues via the single release; no second release spelling; Bridge invisible
- [ ] Grep evidence: one consideration spelling crossed by both wake sources, no getter-triggered consideration, no head-only wake spelling remains; `swift build` green and full `swift test` green with zero test-semantics edits to pre-existing tests
