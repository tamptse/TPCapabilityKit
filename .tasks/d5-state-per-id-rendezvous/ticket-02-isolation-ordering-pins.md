# 02: Per-identity isolation and ordering pins via facade

**What to build:** facade-only tests proving the targeted rendezvous:
interleaved same-id and unrelated-id parkers isolate by construction,
remove-before-create stays a no-op for parkers, cancellation drops silently,
and the no-create invariant holds around the new mechanics.

**Blocked by:** 01 (per-identity drain must exist first so the pins prove the final shape).

**Status:** ready-for-agent

- [ ] Tests cross only the Store facade (observe/update/get/remove plus cancellation); no reference to the State owner, waiter table, or any counter or broadcast spelling
- [ ] Asserts: N same-id pre-write parkers all resolve on the one write while an unrelated-id parker stays pending, then resolves on its own write; remove-before-create with a parker present still resolves on the next write; a cancelled parker stays silent while survivors resolve; reads stay nil before creation (never-creates re-asserted)
- [ ] New pins green alongside unmodified StateLifecycle, StateWaiterIsolation, and ObservationNarrowing suites

**Test command:** `swift build` then `swift test`
