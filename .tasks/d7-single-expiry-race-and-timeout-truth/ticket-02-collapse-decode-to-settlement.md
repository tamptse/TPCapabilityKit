# 02: Collapse the decode table adjacent to settlement

**What to build:** the raced outcome travels from the executor call into the settlement entry without flow-side unwrapping, so the won gate and the void-completion policy read as one truth table next to the single decide-then-transition block, with timeout still delivering expired with an empty result and stored-nil still routing to retry-vs-fail-vs-expire exactly as today.

**Blocked by:** 01 (Unify wait adapter onto the single value topology — the single topology must exist before the decode collapses onto one site).

**Status:** ready-for-agent

- [ ] Flow passes the raced outcome into the settlement entry unwrapped-by-settlement; no flow-side outer-optional decode remains and a bare-optional fold without the won gate is rejected
- [ ] Single settlement-adjacent decode table: won gate (timeout path never consults the carried value) plus void policy (absent result with budget retries; present-vs-absent routing when budget is exhausted) as one auditable table; waiter preservation, retry identity, exactly-once delivery, and slot-release ownership unchanged
- [ ] Verify: `swift build` green plus full `swift test` green with zero test-semantics edits; outer-optional unwrap search returns exactly one site at the settlement entry
