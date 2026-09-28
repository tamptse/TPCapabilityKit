# 03: Merge the SlotHold and Lifecycle test matrix at the facade

**What to build:** Displacement coverage lives once through the scheduling
facade: the overwrite test asserts old-expired-once plus new-completes plus
drained counts, the sequential-reuse test guards the untouched path, and the
admission/FIFO/cancel pins read as one matrix with them. The
controller-direct same-id displacement test is deleted — its outcome is
already asserted above the seam — leaving only the narrow retire contract
test and the double-acquire admission test at the controller seam. No test
pins retire-inside-park after the slim.

**Blocked by:** 02 (Enqueue owns same-id retire and park slims to admission)
— the matrix can only collapse to the facade once the policy actually lives
there.

**Status:** ready-for-agent

- [ ] Controller-direct same-id test removed; facade overwrite test is the
  single displacement pin with counts-drained assertions intact
- [ ] Only narrow retire plus double-acquire pins remain at the controller
  seam; grep shows no test referencing the removed park retire path
- [ ] SlotHold and Lifecycle suites read as one facade-level matrix with no
  duplicated admission coverage; full suite green
