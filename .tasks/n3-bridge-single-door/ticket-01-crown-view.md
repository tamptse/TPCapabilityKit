# 01: Crown taskScheduler live view as single scheduling door

**What to build:** every ObjC scheduling call documented and reviewed through the `taskScheduler` live view only, with the fresh-per-access stateless allocation stated as the safe default and the one delivery story readable beside the view — no behavior change.

**Blocked by:** None (can start immediately). External note: N2 (bridge timeout locality) is recommended before implementation since both touch the view wait path — not implemented here.

**Status:** ready-for-agent

- [ ] View documented as the single scheduling adapter (sync fire, wait-then-run pair, schedule, cancel, counts) with one delivery story
- [ ] Fresh-per-access stateless allocation stated as the no-stale-cache default beside the view
- [ ] Bypass-Lease/slot-admission/Deadline contract referenced from one place, not restated per entry
- [ ] Full test suite green with zero test-semantics edits
