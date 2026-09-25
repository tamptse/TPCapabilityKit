# 02: Collapse double-optional decode to settlement site and verify

**What to build:** the activated-lease execution path hands its raced outcome to Settlement without unwrapping, so the won gate and the void-completion policy read as one truth table at the single terminal step with all delivery outcomes identical to today.

**Blocked by:** 01 (Unify race mechanics behind one value-carrying race).

**Status:** ready-for-agent

- [ ] Flow passes the raced outcome (timeout-empty vs won-with-value including stored-nil) into the settlement entry with no outer-optional unwrap at the call site; timeout path never consults the carried value and late loser values stay discarded with single expired delivery
- [ ] Settlement entry owns the single decode plus existing void policy (nil with budget retries; nil without budget fails when active else expires; cancelled maps to expired once) adjacent to the decide-then-transition block; retry same-Lease-identity re-queue, waiter preservation, park/expiry/activation behavior, and slot scope-exit release unchanged
- [ ] Verify: `swift test --filter SettlementTests` green, `swift test --filter SettlementGuards` green, `swift test --filter RaceValueProofs` green, `swift test --filter TimeoutContractTests` green, `swift test --filter ActivationGate` green; full `swift test` green with zero test-semantics edits; outer-optional unwrap search returns exactly one site at the settlement entry at rest
