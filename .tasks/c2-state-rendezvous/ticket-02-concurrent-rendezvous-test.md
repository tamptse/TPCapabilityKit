# 02: Prove the observe-before-create rendezvous concurrently

**What to build:** a facade-only concurrency test proving the State creation
rendezvous: multiple observers attached before any write all receive the
single subsequent write, while observation alone still creates no visible
state and removal-then-recreate still completes detached with a fresh
subject for new subscribers. The test pins the behavior the extraction in
ticket 01 preserves, using the same through-facade style as the existing
State lifecycle suite.

**Blocked by:** 01 (Extract the State creation seam behind one helper) —
the rendezvous proof must run against the single-seam spelling, not the
duplicated mechanism.

**Status:** ready-for-agent

- [ ] Concurrent observers-before-write all receive the one write through
  the Store facade seam only, with no direct State-owner references
- [ ] No-create invariant re-asserted around the rendezvous (read returns
  nil before the write; detached completion plus fresh-subject behavior
  intact)
- [ ] New test follows existing State lifecycle prior art style; no
  existing test modified for behavior
- [ ] Full suite green with the new test included
