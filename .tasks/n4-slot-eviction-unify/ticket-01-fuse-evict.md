# 01: Fuse retire plus cancel into one waiter-eviction primitive

**What to build:** One intent-named waiter-eviction primitive on the slot
controller replacing the ~8-line `retire(taskId:owner:)` / `cancel(_:)`
duplication, so a queued waiter leaves the slots through exactly one
lock/index/remove/resume-false-outside-lock shape. Displacement calls it with
stale intent (evict waiter under the task id whose owner differs), cancellation
calls it with self intent (evict waiter whose owner matches); self-retire and
stranger no-ops preserved. The primitive is slot-only by construction: resumes
a continuation outside the lock, touches no Lease, no row, no lifecycle
transition. `withHold`, `park`, `release`, FIFO order, scope-exit release, and
the Tasks settle-then-retire-then-insert ordering are byte-for-byte behavior
identical in this ticket (no install change — that is ticket 02).

**Blocked by:** None (can start immediately; N1 lease-terminal unify is
recommended first as advisory sequencing since it moves the settle site this
path orders against, not as a correctness blocker).

**Status:** ready-for-agent

- [ ] Single eviction primitive (task id plus owner plus stale/self intent)
  owns lock, first-only search, removal, and false-resume outside the lock
- [ ] Displacement path calls stale intent; cancel path calls self intent;
  owner-mismatch cancel still no-ops so one lease never yanks another's wait
- [ ] Self-retire no-ops; admitted holders and unrelated waiters untouched;
  settle-first ordering and lock discipline unchanged
- [ ] Narrow retire pin extended to both intents plus no-op guards; facade
  overwrite/sequential-reuse tests untouched; full suite green
