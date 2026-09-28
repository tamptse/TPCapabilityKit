# 01: Trim facade time delegation to Generations-only seam

**What to build:** deterministic-time controls exposed on `StoreSchedulingGenerations` only with the Store facade time forwarders deleted, so enable/advance/wait reviews in one hop with behavior identical to today.

**Blocked by:** None (can start immediately as a work item, but DO NOT START until the speculative gate clears: N5 `n5-state-observe-waiter` merged first — same `DynamicStore.swift` file — plus one ADR-0026 revisit trigger evidenced in this ticket before editing code: a fourth lock domain named, renewed review friction with two-hop proof, or prune logic stable across a full cycle).

**Status:** ready-for-agent

- [ ] Facade `enableDeterministicTime` / `advanceTime(by:)` / `waitForDeterministicWaiters(count:)` forwarders deleted; facade keeps `configureScheduler` / `scheduleTask` / `scheduleTaskAndWait` / `cancelTask` / `pendingTaskCount` / `activeTaskCount` with production behavior unchanged
- [ ] Deterministic controls live once on Generations (enable with precede-first-use gate beside the pruned count, advance, waiter rendezvous); `Clock` / `VirtualTime` untouched as pure adapters; shared slot domain plus shared clock wiring preserved per ADR-0021
- [ ] Trigger evidence cited in-ticket before code edits (N5 merged pointer + one ADR-0026 condition); `generationCount` placement decided once per spec tie-break (keep with counts unless trigger review moves it)
- [ ] Full test suite green with test-seam updates only (facade-time call sites re-pointed to Generations), zero behavior-semantics edits; grep proves no facade time forwarder remains
