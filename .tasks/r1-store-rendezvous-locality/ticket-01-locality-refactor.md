# 01: Deepen StoreState rendezvous into one transition + ordering comment

**What to build:** `StoreState` reads as one review surface: the late-subscriber
rendezvous is stated once beside `observe`/`update`, with the 3-case enum and
the 4-op Combine await chain folded into private mechanics of a single
lookup-or-await transition. The load-bearing ordering (`creationClock.send`
before `subject.send`, `filter > after` replay guard, `Deferred` re-entry
reason) is stated once in a comment at the transition. Behavior through the
Store facade is bit-identical.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] Writer (`update`) and observer (`observe`) are the only two callers of the single rendezvous transition; no second spelling of capture-filter-relookup-first-switch remains
- [ ] Locked work stays index/counter read-or-insert only; both publishes emit after unlock with boundaries unchanged; ordering comment states clock-before-subject as lossless proof
- [ ] No-create / remove-completes-detached + fresh-subject / empty-id / typed-edge behavior identical; no public seam change; no new file or module
- [ ] Zero test files modified; `TPCapabilityKitStateLifecycleTests`, `TPCapabilityKitStateWaiterIsolationTests`, `TPCapabilityKitObservationNarrowingTests` green plus full suite green

**Test command:** `swift test`
