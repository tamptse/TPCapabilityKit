# 02: Route run-when-available through the shared descriptor-building core

**What to build:** Both value-returning wait entries share one build plus one delivery core: run-when-available stops building inline via a direct mapper call with hardcoded priority and retry values and instead crosses the same descriptor-building core as the descriptor entries, then flows through the existing shared wait-then-run delivery core with schedule-and-wait — so capability mapping, priority coercion, and the resolved timeout triple agree by construction.

**Blocked by:** 01 (Collapse timeout readers to one stored enum match) — lands after the reader collapse so the unified build reads the single stored match from the start.

**Status:** already-satisfied-on-HEAD (self-grill 2026-09-27: runWhenAvailable already builds via shared core; c6 CLOSE per specs/FAILURES.md 2026-09-26 entry)

- [ ] Run-when-available crosses the shared descriptor-building core (same capability mapping, same priority coercion to normal on out-of-range, same retry and metadata defaults); no inline literals remain in the wait entry
- [ ] Observable triple preserved exactly: capability set, coerced priority, and omitted-vs-negative-vs-explicit timeout behavior identical to before
- [ ] Shared wait-then-run delivery core stays the single delivery path for both entries (queue-or-main hop unchanged; sync fast-path untouched)
- [ ] Wait-then-run resolver-sharing test plus descriptor-construction-agreement tests pass unchanged; C5 expiry suites (resolve-once, execution-expiry, operation-wins) untouched
