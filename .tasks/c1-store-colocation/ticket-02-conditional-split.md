# 02: Split Store file on trigger only (parked-skip otherwise)

**What to build:** IF the trigger from ticket 01 fires, a pure mechanical relocation of `StoreState` into `DynamicStore+State.swift` and `StoreSchedulingGenerations` into `DynamicStore+Generations.swift` with zero behavior change; IF the trigger has not fired, close this ticket as parked-skip with no code change.

**Blocked by:** 01 (Record C1 park decision and arm the split trigger).

**Status:** ready-for-agent (parked-skip unless trigger fires — do NOT start code without trigger evidence)

- [ ] Trigger check first: cite which condition fired (fourth lock domain / prune stable one cycle / review friction with file line count). If none fires, close as parked-skip with a one-line reason and zero code edits
- [ ] If triggered: pure move only — `StoreState` (~86 lines) and `StoreSchedulingGenerations` (~99 lines) relocate verbatim; facade keeps thin delegation; each new file opens with the lock-order contract comment (no caller holds a Store lock across a submodule call; Store→Tasks per ADR-0022)
- [ ] No semantics change: submodule locks, prune-keeps-current, snapshot sum-vs-share, deterministic-time spelling on facade all preserved; `@unchecked Sendable` annotations move with their types
- [ ] `swift build` green and full `swift test` green with zero test edits (tests cross the facade seam only)
