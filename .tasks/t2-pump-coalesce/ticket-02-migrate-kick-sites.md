# 02: Migrate schedule, schedule-and-wait, and retry to kick

**What to build:** all three raw drain spawns migrated to the single kick entry, so fire-and-forget, schedule-and-wait, and settlement retry re-queue share one drain with no rival pumps left.

**Blocked by:** 01 (add guarded kick plus concurrent drain).

**Status:** ready-for-agent

- [ ] Fire-and-forget entry migrated: enqueue through existing table transition with displaced delivery plus slot evict outside lock, then kick instead of raw spawn
- [ ] Schedule-and-wait entry migrated: same enqueue-then-kick order on the parked branch (settled-early still resumes immediately without kicking); retry re-queue in settlement migrated to kick
- [ ] No raw drain spawn remains in entries or settlement; drain concurrency verified by existing pins (priority high-before-low, slot serialization with FIFO wake, retry recovery, cancel-while-parked terminal)
- [ ] `swift build` green and full `swift test` green with zero test-semantics edits; mechanical check shows raw-spawn count at zero
