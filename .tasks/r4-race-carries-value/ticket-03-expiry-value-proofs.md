# 03: Expiry and value-carrying race proofs

**What to build:** behavior proofs that the generalized race preserves every expiry contract and the stored-nil vs never-stored distinction, so the box deletion is verified by outcomes through the public seam plus deterministic time.

**Blocked by:** 02 (Migrate executor to value path and delete ExecutionBox).

**Status:** ready-for-agent

- [ ] Value-race truth table proven: operation-wins-with-value delivers completed with that value; operation-wins-with-stored-nil routes into the void-completion retry policy (retries with budget, fails-or-expires without); timeout-wins delivers expired with empty result and never consults the value, including a late-loser-completes-after-timeout case
- [ ] Waiter parity proven: capability wait still parks once, expires once on single expiry, wins on mid-wait capability flip with the shared resolved timeout, and preserves per-Capability-before-snapshot emission order plus empty-set and already-satisfied fast paths
- [ ] Mechanical deletion proof plus full suite: `grep -rn ExecutionBox Sources/` empty, no test names the removed type, and `swift test` fully green (focused first: `swift test --filter DeadlineTests`, `swift test --filter SingleExpiryTests`, `swift test --filter TimeoutContractTests`, `swift test --filter CapabilityRegistryWait`)
