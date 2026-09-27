# 01: Unify flag plus rechecks into one drain owner

**What to build:** one reviewable drain lifecycle beside the lifecycle table, so every kick, handover, and rekick flows through a single owner with one finish-or-continue rule and at most one drain runs per generation.

**Blocked by:** D7 race interface contract (hard external edge: the unified drain constructs one expiry race per dequeue and passes it to park/activation, so the race constructor plus value form must be stable first). No internal blocker (can start once D7 lands).

**Status:** ready-for-agent

- [ ] Single drain owner added beside the lifecycle table holding idle/draining state with one kick entry: idle starts one drain, already-draining returns with no new task, check-and-set in one locked step, kick entry shape stable for settle-retry repump callers
- [ ] Loop-tail and scope-exit handover migrated onto one finish-or-continue rule spelled once: nonempty queue continues-or-rekicks, empty queue clears-and-exits; enqueue between last dequeue and handover is never stranded; pump cancellation clears ownership with re-kick on nonempty
- [ ] Dequeue order, park reachability, activation gate, settlement identity, expiry race threading, slot admission/release, and counts snapshot unchanged; split flag-plus-two-rechecks spelling removed with no dual-behavior window left
- [ ] `swift build` green and full `swift test` green with zero test-semantics edits; burst/reentrancy/ordering pins stay green
