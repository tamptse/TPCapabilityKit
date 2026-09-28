# 01: Unify schedule completion through single delivery seam

**What to build:** every Bridge completion arriving on the given queue or the main queue through the single delivery seam, so the `schedule` entry no longer fires on the Tasks execution context while waits and subscriptions hop.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] `schedule` completion routes through the single given-or-main delivery seam (given queue when supplied, main queue when omitted) alongside the wait core and both subscription entries
- [ ] Delivery contract stated once beside the single core and referenced, not restated, by the `schedule` entry; no second delivery path or restated contract remains at rest (mechanical check)
- [ ] No scheduling-semantics change: Lease lifecycle, slot admission, Deadline/expiry, retry, cancel, counts, descriptor/timeout behavior identical; Swift Store facade signatures unchanged; any new delivery-queue parameter is additive with omitted-means-main
- [ ] Sample target untouched (explicitly non-goal, no harness or sleep change)
