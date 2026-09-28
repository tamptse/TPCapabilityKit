# 01: Record C1 park decision and arm the split trigger

**What to build:** a committed record that C1 stays parked with an unambiguous trigger for revisiting, so no future session re-litigates colocation without new evidence.

**Blocked by:** None (can start immediately).

**Status:** done (2026-09-28: PARK recorded — DynamicStore.swift 562 lines <600, no 4th domain, grep 0 test refs to StoreState/StoreSchedulingGenerations, build green)

- [ ] ADR-0025/0026 trigger restated in `specs/c1-store-colocation.md`: fourth lock domain OR prune stable one full cycle OR review friction (file > ~600 lines or ≥2 reviewers flag hop cost)
- [ ] Pre-drawn cut points documented: facade→State and facade→generations; target names `DynamicStore+State.swift` + `DynamicStore+Generations.swift` with duplicated lock-order contract header per file
- [ ] Grep evidence recorded: no test references `StoreState`/`StoreSchedulingGenerations` directly (facade seam only), `swift build` green
- [ ] No file move, no semantics change; spec + this ticket are the only artifacts
