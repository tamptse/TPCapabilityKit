# 03: State the overtake policy and pin throughput plus full-suite green

**What to build:** The fairness-vs-throughput tradeoff becomes explicit and
provable: the overtake policy (first-fit FIFO with skip, head re-evaluated on
every release, skipping delays but never strands) is stated once beside the
admission seam and recorded in the domain glossary plus the decision log with
its no-strand argument, so a future strict-FIFO revert must answer the
evidence. End-to-end verifiable: a heterogeneous stress mix completes with no
idle-slot stall (blocked heads overtaken, all leases terminal, counts drain to
zero), homogeneous FIFO order is re-pinned untouched, and no head-only wake
spelling remains.

**Blocked by:** 02 (drain all satisfiable waiters per release with
outside-lock batch resume).

**Status:** ready-for-agent

- [ ] Overtake policy stated once beside the admission seam and recorded in
  the glossary plus decision log with the no-strand argument (scan restarts
  at the head each release; an unfit head faces exhaustion, not unfairness)
- [ ] Heterogeneous stress pin through the facade: overtaken heads, fitting
  followers flowing, all terminal, counts drained, limits never overshot
- [ ] Grep evidence: no head-only wake spelling remains beside the scan; no
  new public seam or adapter change
- [ ] Full suite green (`swift build` + `swift test`) with zero
  test-semantics edits to pre-existing tests
