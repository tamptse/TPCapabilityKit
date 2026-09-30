# M6-01: Sample teardown helper

**What to build:** Add one private teardown helper in the sample module clearing created plugins and state, rewiring all examples to call it with unchanged setup order, durations, scheduler restore adjacency, and printed output.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] Helper takes explicit plugin plus state lists plus in-out cancellables with no singleton capture, ObjC overload detaches via bridge
- [ ] All examples end clean on the shared store with zero pending/active and nil states after run
- [ ] `swift build` green (including sample target) plus one manual sample run showing all sections
