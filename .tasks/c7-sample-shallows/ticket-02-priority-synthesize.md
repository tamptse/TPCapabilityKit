# 02: Synthesize TaskPriority.allCases

**What to build:** the manual `allCases` list disappears; the compiler owns priority ordering in one place so a future case cannot drift from a hand-maintained list.

**Blocked by:** None (can start immediately; independent of 01).

**Status:** verify-only (landed — TaskPriority.swift:6 CaseIterable on declaration, 26-line file; see spec STALE header 2026-09-27)

- [ ] `CaseIterable` moves to the `TaskPriority` declaration; the manual `extension TaskPriority: CaseIterable` with hard-coded `allCases` is deleted
- [ ] Ordering preserved (`background, low, normal, high, critical`), count 5, raw values / `description` / `Comparable` unchanged
- [ ] `ObjcDelivery`, `ObjcCancellable`, and `Capability.description` untouched (explicit non-goals)
- [ ] Existing scheduler/priority tests pass unchanged
