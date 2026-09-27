# 01: Unify wait adapter onto the single value topology

**What to build:** the expiry detail exposes the same two public race shapes but both run on the single shared TaskGroup topology with no wait-side unwrap, so waiter and executor provably share one expiry with one code path to audit and all expiry behavior identical to today.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] Single private TaskGroup topology (one operation task plus one sleep task on the shared sleep seam, first-wins, cancel-all, loser discarded never stored) is the only race construction site; value form is canonical, `Bool` form is a pure thin map over it (timeout maps to `false`, operation-`false` still `false`) owning no unwrap of its own
- [ ] Named race kept with frozen `task-plus-default-plus-clock` construction and readable resolved timeout; registry whole-set wait keeps receiving the `Bool` race as an opaque value and never names the expiry type; live/virtual adapters and advance policy untouched; no new lock domain, no new module, no public API change
- [ ] Verify: `swift build` green plus full `swift test` green with zero test-semantics edits; TaskGroup construction search in the expiry detail returns exactly one site at rest
