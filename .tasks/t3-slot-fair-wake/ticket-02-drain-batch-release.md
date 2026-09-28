# 02: Drain all satisfiable waiters per release with outside-lock batch resume

**What to build:** The release scan generalizes from first-satisfiable to
drain-all-fitting: within one locked pass, in arrival order, every waiter that
fits the freed capacity is admitted, bounded by that capacity (one freed
global slot admits at most one waiter when a global limit binds;
per-capability limits otherwise). All admitted waiters resume outside the lock
as an arrival-ordered batch — woken means admitted, never wake-then-contend.
End-to-end: one release freeing several disjoint per-capability slots activates
every fitting waiter at once instead of serializing them across releases, and
a waiter refused at the activation gate still returns its slot through the
unchanged scope-exit release so the cascade continues. Newcomer no-overtake
parking stays coherent: queued waiters own freed capacity first.

**Blocked by:** 01 (scan for first satisfiable waiter on release plus HOL
regression pins).

**Status:** ready-for-agent

- [ ] Release admits every satisfiable waiter in arrival order within one
  locked pass, bounded by freed capacity; global limits never overshot
- [ ] Batch resumes delivered outside the lock in arrival order; no
  wake-then-repark churn (woken waiters already hold installed slots)
- [ ] Gate-refused waiter returns its slot via scope-exit release and the
  cascade continues; cancellable wait, eviction intents, and duplicate
  rejection unchanged
- [ ] Disjoint-demand drain pinned through the facade plus narrow
  batch-resume pin; full suite green
