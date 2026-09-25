# 01: Unify race mechanics behind one value-carrying race

**What to build:** the expiry module exposes the same two public race shapes but both run on a single private TaskGroup topology, so waiter and executor provably share one expiry with one code path to audit and all expiry behavior identical to today.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] Single private TaskGroup topology (one operation task plus one sleep task on the shared sleep seam, first-wins, cancel-all, loser discarded never stored) is the only race construction site in the expiry module; value form is canonical, `Bool` form is a thin mapping over it with byte-identical semantics (timeout maps to `false`, operation-`false` still `false`)
- [ ] Named type kept with resolve-once construction (task plus configured default) and readable resolved timeout untouched; registry whole-set wait keeps receiving the `Bool` race as an opaque value and never names the expiry type; live/virtual adapters and advance policy untouched; no new lock domain, no new module, no public API change
- [ ] Verify: `swift test --filter DeadlineTests` green, `swift test --filter TimeoutContractTests` green, `swift test --filter SingleExpiryTests` green, `swift test --filter RaceValueProofs` green; full `swift test` green with zero test-semantics edits; TaskGroup construction search in the expiry module returns exactly one site at rest
