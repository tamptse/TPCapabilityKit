# 01: Clock deterministic adapter split

**What to build:** Move test-only rendezvous off prod Clock onto a test adapter; prod keeps one sleep seam with identical VirtualTime wake semantics.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] Prod `Clock` exposes `sleep` (+ `enableDeterministic`/`advance` drive) without `waiterCount`/`waitForWaiters` on prod path
- [ ] Deterministic tests drive via adapter rendezvous, no 5s precondition flake
- [ ] `swift test` green (at least Clock/expiry/timeout subsets + full at end)
