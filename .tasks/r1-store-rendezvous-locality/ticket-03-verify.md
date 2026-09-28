# 03: Full verify — build, suite, seam-leak grep

**What to build:** final verification that the R1 deepen landed with zero
seam or contract drift: clean build, full suite green, and proof that tests
and Bridge cross only the facade seam.

**Blocked by:** 01, 02 (verifies the final tree after refactor + new test).

**Status:** ready-for-agent

- [ ] `swift build` green with no warnings introduced by the refactor
- [ ] Full `swift test` green (in particular StateLifecycle, StateWaiterIsolation, ObservationNarrowing)
- [ ] Grep confirms no test references `StoreState` internals (helper/enum/sequence/clock) and no file split or public signature change (`git diff --stat` shows only `DynamicStore.swift` + one new test)

**Test command:** `swift test`
