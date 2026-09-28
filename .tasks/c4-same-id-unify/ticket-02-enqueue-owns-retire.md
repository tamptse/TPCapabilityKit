# 02: Enqueue owns same-id retire and park slims to admission

**What to build:** The enqueue step becomes the single owner of same-id
displacement: for a non-terminal row under the incoming id it settles the
displaced Lease as expired through the existing settlement path, then calls
the narrow retire seam, then inserts the new row — each step outside the
other's lock, never nested. Park drops its implicit stale-retire and its
cross-owner same-id duplicate branches, keeping admission, FIFO order,
cancellable wait, and the same-Lease re-entrancy guard; the scope-exit
release owner check is untouched. Both schedule entries are fixed at once
because both funnel through enqueue, and sequential reuse after terminal
takes no settle-or-retire path.

**Blocked by:** 01 (Expose the narrow retire seam on the controller) — the
enqueue step needs the evict seam to exist before park can shed its implicit
retire.

**Status:** ready-for-agent

- [ ] Overwrite through the facade still expires the old row exactly once and
  completes the new row, for both schedule entries via the one enqueue path
- [ ] Sequential reuse after terminal works untouched with no retire crossed
- [ ] Park holds no task-id policy branches; double-acquire of the same Lease
  still rejected; FIFO and cancel-while-waiting unchanged
- [ ] Displaced-active stale scope-exit still cannot release the new
  holder's slot; no scheduler/controller lock nesting; full suite green
