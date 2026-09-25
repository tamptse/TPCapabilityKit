# 02: Pin pairing via enqueue behavior — stale drained, stray evict gone

**What to build:** behavior pins proving the pairing changed only forgetability: displacement drains the stale waiter and admits the newcomer through the public schedule seam, while enqueue without displacement evicts nothing. Production code untouched in this ticket except test files.

**Blocked by:** 01 (carry obligation and drain it in the funnel).

**Status:** ready-for-agent

- [ ] Displacement pin: same-id overwrite under slot contention evicts the stale waiter exactly once and the newcomer admits and completes, through the public seam; displaced park waiter cancelled exactly once and never runs
- [ ] No-stray-evict pin: enqueue with no displacement (fresh id, sequential reuse after terminal) leaves unrelated same-id slot waiters untouched with FIFO order and counts agreeing
- [ ] Regression net: concurrent overwrite expires old exactly once, cancel-after-overwrite lands on the new row, schedule-wait guard never joins the new lease, slot stale/self/no-op guards hold; production code untouched
- [ ] `swift build` green and full `swift test` green; new pins live beside the same-id exchange and slot-hold suites with no semantics edits to existing tests
