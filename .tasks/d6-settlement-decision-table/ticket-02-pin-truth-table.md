# 02: Pin decision truth table and preservation guarantees

**What to build:** behavior pins proving the extracted table decides every outcome correctly and the apply preserves every scheduling guarantee, so the isolation is verified by public-seam outcomes rather than table spelling.

**Blocked by:** 01 (Extract pure settlement decision table beside the locked apply).

**Status:** ready-for-agent

- [ ] Truth-table pins through the public schedule/cancel/wait seam: won-with-value completes; won stored-nil retries with budget and recovers on the retry; stored-nil without budget fails when active else expires; failed fails when active else expires; timeout-empty expires; cancelled lands expired
- [ ] Preservation pins: same-Lease-identity retry re-queue (completions and live views survive retry), waiters preserved across retry with exactly-once terminal delivery, completed/failed active-only with expired accepting pending, activation scope-exit as the single slot release, retry re-pump re-entering the pump
- [ ] `swift build` green and full `swift test` green with zero test-semantics edits to prior suites; new pins fail if any row (budget, void policy, mapping) regresses
