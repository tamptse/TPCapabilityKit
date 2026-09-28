# 03: Unify runWhenAvailable and scheduleAndWait on single wait core

**What to build:** both value-returning wait spellings sharing one delivery core with a single contract comment, so descriptor-built and capability-built waits agree by construction instead of by parallel implementation.

**Blocked by:** 02 (demote-doors).

**Status:** ready-for-agent

- [ ] `runWhenAvailable` and `scheduleAndWait` share the single wait-then-run delivery core (one descriptor-build plus queue-hop path)
- [ ] Bypass-Lease/slot-admission/Deadline contract stated once beside the core; duplicate paraphrases deleted
- [ ] Mechanical grep proves no second wait path or restated contract remains at rest
- [ ] Full test suite green with zero test-semantics edits
