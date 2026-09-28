# 01: Scan for first satisfiable waiter on release plus HOL regression pins

**What to build:** Release stops testing only the queue head and instead scans
waiters in arrival order, admitting the first waiter that fits current
capacity. End-to-end through the scheduling facade: with two contended
capabilities behind a tight shared domain, a queued head needing a still-full
capability no longer parks a follower whose demand is free — the follower
activates while the head keeps waiting, and the head activates at the first
later release freeing its demand. Homogeneous queues behave exactly as before
(scan degenerates to head wake), so FIFO order among fitting waiters is
unchanged. Single wake per release in this ticket (one freed global slot admits
at most one waiter); the multi-disjoint drain is ticket 02.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] Release scans the arrival queue from index zero and admits the first
  waiter fitting current capacity instead of testing only the head
- [ ] Skipped head loses no place and is reconsidered on every later release
- [ ] Facade HOL pin: blocked head plus fitting follower activates out of order
  by necessity, then the head follows when its demand frees
- [ ] Homogeneous FIFO pin still passes with zero test-semantics edits; full
  suite green
