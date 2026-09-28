# 02: Ordering postcondition test via facade

**What to build:** a facade-only test proving the lossless-wakeup ordering:
multiple observers attached before any write all receive the single subsequent
write, `getState` reads it, an unrelated-id waiter stays pending, and the
no-create invariant holds around the rendezvous.

**Blocked by:** 01 (deepened transition must exist first so the test proves the final shape).

**Status:** ready-for-agent

- [ ] Test crosses only `DynamicStore.observeState/updateState/getState/removeState`; no reference to `StoreState`, helper, enum, sequence, or clock
- [ ] Asserts: N pre-write observers (same id) all receive the one write; `getState` equals the write; different-id observer receives nothing; observation-alone-created-nothing re-asserted via `getState == nil` before write
- [ ] New test green alongside `TPCapabilityKitStateLifecycleTests`, `TPCapabilityKitStateWaiterIsolationTests`, `TPCapabilityKitObservationNarrowingTests` with no edits to existing tests

**Test command:** `swift test`
