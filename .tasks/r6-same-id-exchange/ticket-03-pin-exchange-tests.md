# 03: Pin overwrite, cancel-during-overwrite, and waiter-guard behavior

**What to build:** behavior pins proving the fuse changed only atomicity, so concurrent overwrite, cancel landing mid-overwrite, and schedule-wait attach guards hold without touching production code.

**Blocked by:** 02 (migrate enqueue funnel to the single exchange seam).

**Status:** ready-for-agent

- [ ] Overwrite pin: concurrent same-id schedule expires the old Lease exactly once with completion delivered and the new Lease completes, through the public seam (counts drain to zero, stale slot resume lands on an already-terminal Lease)
- [ ] Cancel-during-overwrite pin: cancel resolves against exactly one row (old-terminal or new-pending) with exactly-once waiter delivery and no half-displaced absence; same-id reschedule still works after terminal
- [ ] Waiter-guard pin: schedule-wait attach against a displaced id never appends to another Lease's waiter list (mismatched row identity returns already-settled); parked waiter of the displaced row cancelled exactly once; retry identity and waiter preservation unchanged
- [ ] `swift build` green and full `swift test` green; production code untouched in this ticket except test files
