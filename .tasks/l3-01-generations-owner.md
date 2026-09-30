# 05: Generations owner injection + narrow seam

**What to build:** Generations captures owner once at construction; per-call owner params removed and whole-scheduler exposure narrowed to schedule/cancel/counts.

**Blocked by:** 01 Clock deterministic adapter split (deterministic gate moves off prod Clock first).

**Status:** ready-for-agent

- [ ] `current()`/`reconfigure(_:)`/`enableDeterministicTime()` take no owner; reconfigure drain/sum/shared-domain semantics preserved
- [ ] No whole-`TaskScheduler` leak to Fire; Fire funnels via narrow seam
- [ ] `swift test` green (generations/drain/reconfigure + full)
