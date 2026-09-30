# L6 — Deferred deepenings (registry wait, fire funnel, settlement) — docs only

## Problem Statement
Three friction areas are real but unsafe to change autonomously: (a) Registry `waitForAll(race:)` splits waiter across seam via closure + `observeAll` leaks to 6 test files (ADR-0024); (b) Fire has 5+ spellings with contract in prose (K8 landed two entries — further collapse breaks public API); (c) Settlement has 5 terminal spellings + decision/apply split with retry-identity semantics.

## Solution
Docs-only this wave. No prod code change. Record窄 direction + ADR status so future waves don't re-suggest blindly.

## User Stories
1. As a Tasks author, I want whole-set readiness behind one wait interface, so that snapshot+re-query misuse is impossible.
2. As a Fire consumer, I want two entries only, so that shape decides sync-vs-wait.
3. As a maintainer, I want one terminal vocab + pure decide, so that retry matrix is testable.

## Implementation Decisions
- Registry: keep `race` closure + `observeAll` internal; mark `observeAll` waiter-only again, file follow-up to migrate 6 test files to `waitForAll`/`observe(capability)` first. Possible future: narrow `ExpiryRacer` protocol owned by registry. Contradicts nothing today; ADR-0024 stays.
- Fire: K8 already collapsed to two entries + thin conveniences; deleting `runTaskWhenAvailable`/legacy alias now breaks ObjC compat (ObjcStoreBridge deprecated forwarders point to door). Keep. Future needs compat window.
- Settlement: keep `settleDecision/SettleDirective` private static + `Lease.canRetry/beginRetry` split; future pure `SettlementResolver.resolve(outcome,canRetry,isActive)` unit-tested without lock. Touches Lease `==` ignoring Error + retry same-Lease identity — needs careful migration (ADR-0001/0004/0005/0009).
- Grill (auto): load-bearing rejections → offer ADRs only if future explorer would re-suggest; here record as deferred, no new ADR (existing ADRs cover).

## Testing Decisions
- No code, no new tests. Verify with `swift build` only (unchanged tree).

## Out of Scope
- Any prod edit in this spec.

## Further Notes
- Depends on L1–L5 landing first (Path/Lifecycle files churn). Revisit after.
