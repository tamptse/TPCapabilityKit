# 01: Extract the State creation seam behind one helper

**What to build:** the writer path and the observer path become two callers
of a single State-owned lookup-or-await creation helper, so per-Plugin
creation reviews as one named seam. The mechanism is unchanged (global
creation notice plus per-Plugin index, first-hit plus switch-to-subject),
all publishes stay after unlock, typed filtering stays at the observation
edge, and every behavior observed through the Store facade is identical.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] Writer and observer cross one State-owned creation helper; no second
  spelling of capture-filter-relookup-first-switch remains
- [ ] Locked work stays lookup-or-insert plus notice-generation read; all
  publishes emitted after unlock with boundaries textually unchanged
- [ ] No-create contract preserved: observation alone creates no visible
  state; removal still completes detached with a fresh subject on next update
- [ ] No public seam change; no test file modified; State lifecycle suite
  plus full suite green
