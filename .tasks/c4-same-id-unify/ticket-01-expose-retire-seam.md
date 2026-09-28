# 01: Expose the narrow retire seam on the controller

**What to build:** The slot controller gains one small evict-stale-waiter
seam: given a task id and the newcomer's owner, it removes any queued waiter
under that id whose owner differs and resumes it with false, no-op-ing when
there is nothing stale. Park behavior is completely unchanged in this ticket
(expand phase — the old implicit retire stays put), and no production caller
crosses the new seam yet. The seam is slot-only by construction: it resumes a
continuation and touches no Lease, no row, and no lifecycle transition.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] New retire seam evicts a stale waiter under the same task id with false
  while leaving the admitted holder and unrelated waiters untouched
- [ ] Self-retire (caller names only its own waiter) no-ops
- [ ] Park, admission, FIFO order, cancellable wait, and scope-exit release
  byte-for-byte unchanged; full suite green
- [ ] One narrow retire test pins the evict-stale contract at the controller
  seam; no facade test modified
