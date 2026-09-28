# 01: Add guarded kick plus concurrent drain beside raw spawns

**What to build:** one kick entry plus a guarded drain added beside the three existing raw drain spawns, so enqueue-then-kick starts at most one drain per scheduler while available rows still activate concurrently and no existing call site changes behavior yet.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] Kick entry added beside existing spawns: locked drain-flag check-and-set (idle starts one drain, already-draining returns with no new task); flag scoped per scheduler generation
- [ ] Guarded drain loop added beside existing path: rapid priority-order dequeue decoupled from activation (available rows handed to concurrent activation via existing gate/hold/Deadline/settlement, parked rows keep single park seam), missed-wakeup clear-plus-recheck so enqueue between last dequeue and clear is never stranded, scope-exit flag clear with re-kick on nonempty after cancel
- [ ] Park, activation gate, settlement, retry identity, Deadline race, registry wait, slot admission/release, counts snapshot unchanged; old three raw spawns untouched so existing callers still compile
- [ ] `swift build` green and full `swift test` green with zero test-semantics edits; mechanical check shows kick present beside legacy raw spawns
