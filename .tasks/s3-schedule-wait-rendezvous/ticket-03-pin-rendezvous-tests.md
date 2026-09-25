# 03: Pin wait rendezvous, displacement-during-wait, and retry behavior

**What to build:** behavior pins proving the fuse changed only atomicity, so success/cancel/displacement/retry outcomes for waiting callers hold without touching production code.

**Blocked by:** 02 (migrate schedule-and-wait entry to the single rendezvous seam).

**Status:** ready-for-agent

- [ ] Wait-outcome pin: success resumes with the value, failure/timeout/cancel resume nil, each exactly once, through the public seam with counts draining to zero
- [ ] Cancel-during-wait pin: cancel resolves against exactly one row with exactly-once waiter delivery whether it races the fused insert or lands after the park; same-identity reschedule still works after terminal
- [ ] Displacement-during-wait pin: same-identity reschedule against an in-flight wait expires the old waiter exactly once while the new lease completes; waiter-guard pin shows a mismatched row never receives another lease's waiter and the displaced parked waiter cancels exactly once; retry pin shows the waiter preserved to recovery
- [ ] Build green and full test suite green; production code untouched in this ticket except test files
