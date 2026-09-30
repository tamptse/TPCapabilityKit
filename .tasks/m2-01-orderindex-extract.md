# M2-01: Lifecycle ordering extract

**What to build:** Extract priority ordering mechanics into its own file-module verbatim, keeping rows plus counts snapshot plus transitions in the table; document the snapshot refinement with debug-only recompute.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] Ordering keeps per-priority FIFO with skip plus remove-on-take plus terminal auto-clean, no behavior change
- [ ] Counts keep single-writer snapshot with debug-only invariant from insert, transition, take, and dequeue paths
- [ ] `swift test` green (at least priority, lifecycle table, ordering and snapshot postconditions plus full at end)
