# 02: Fuse canAcquire plus installHold into one atomic install

**What to build:** One lock-internal atomic try-install replacing the
comment-contract `canAcquire`-then-`installHold` pair, so `park` and `release`
head-wake no longer spell check-then-act as two calls with a "callers hold
lock and checked first" obligation. The atomic step checks capacity and
installs under the same lock acquisition, returning admitted/not; both
admission sites call it. No bare `installHold` without a check remains. No
admission semantics change: limits, FIFO wake, duplicate rejection, and
scope-exit release identical.

**Blocked by:** 01 (fuse retire plus cancel into one waiter-eviction primitive).

**Status:** ready-for-agent

- [ ] Atomic try-install owns check-plus-install under one lock acquisition;
  bare `installHold` and call-site `canAcquire`-then-`installHold` gone
- [ ] `park` admission and `release` head-wake both cross the atomic step;
  duplicate guard and FIFO order unchanged
- [ ] Grep evidence: no caller spells check-then-install at the call site;
  no eviction copy reintroduced beside the fused primitive
- [ ] Slot-hold/admission suites plus full suite green with zero
  test-semantics edits (`swift build` + `swift test`)
