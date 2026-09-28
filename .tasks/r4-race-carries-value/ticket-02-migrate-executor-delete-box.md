# 02: Migrate executor to value path and delete ExecutionBox

**What to build:** the activated-lease execution path carries its result through the value race instead of the side-channel box, so the nested holder type and its lock disappear while Settlement receives exactly the same outcomes as today.

**Blocked by:** 01 (Generalize race seam with Bool specialization preserved).

**Status:** ready-for-agent

- [ ] `runActivatedLease` calls the value-carrying race form and delivers the carried value into the existing `settle(lease,result:timedOut:execution:)` entry; timeout yields expired with an empty result without consulting the value; won delivers the carried value including stored-`nil` into the retry policy
- [ ] `ExecutionBox` nested type plus its `NSLock` deleted; no per-execution holder escapes its scope; loser result discarded by TaskGroup cancellation, never stored; `grep -rn ExecutionBox Sources/` returns empty
- [ ] Waiter path (`waitForCapabilities` adapting the `Bool` specialization into the registry race value), park double-park plus waiter-cancel rules, slot scoped-hold with scope-exit release, retry same-Lease-identity re-queue, and waiter exactly-once delivery all unchanged
- [ ] Verify: `swift test --filter DeadlineTests` green, `swift test --filter SettlementTests` green, `swift test --filter SettlementGuards` green, `swift test --filter ActivationGate` green; full `swift test` green with zero test-semantics edits
