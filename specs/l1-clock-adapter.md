# L1 — Clock deterministic adapter split

## Problem Statement
Prod `Clock` exposes test-only rendezvous (`waiterCount`, `waitForWaiters`) on the same interface as prod `sleep`. Callers must learn preconditions (`enableDeterministic`, 5s rendezvous) that prod never needs.

## Solution
Keep `Clock` as deep module behind one `sleep` seam (live + virtual). Move deterministic rendezvous (`waiterCount`, `waitForWaiters`, polling + precondition) onto a test-only adapter owned by the time module; `advance` drives virtual time without hidden rendezvous tax. Prod behavior unchanged.

## User Stories
1. As a scheduler author, I want one sleep seam for waiter and executor, so that expiry shares one path.
2. As a test author, I want a deterministic adapter with explicit waiter rendezvous, so that timing tests are not flaky.
3. As a prod caller, I want no test preconditions on Clock, so that misuse fails at type level not crash.
4. As a maintainer, I want VirtualTime registry locality in one place, so that wake-loss/dup fixes land once.

## Implementation Decisions
- Module: time module owns both `Clock` (prod) and deterministic adapter (test). No new seam beyond `sleep` + adapter drive.
- Interface: `Clock` keeps `sleep`, `enableDeterministic`, `advance`; `waiterCount`/`waitForWaiters` move to adapter. `StoreSchedulingGenerations` forwards `advance` via Clock, rendezvous via adapter only in tests.
- Preserve VirtualTime wake semantics exactly (expired-only wake, no loss/dup, cancel resumes).
- Respect ADR-0010 (one capability waiter, injectable clock), ADR-0012 (Deadline owns expiry), ADR-0023 (time owns adapters). Deferred K4-02 note removed when landed.
- Grill decisions (auto, best-practice): no prod logic change; adapter lives in same file as private extension to avoid new file churn; DEBUG-only warn not needed here.

## Testing Decisions
- Test external behavior only: sleep wakes on advance, cancel resumes, advance wakes only expired.
- Modules: Clock sleep seam + adapter rendezvous. Prior art: SingleExpiryTests, RaceValueProofsTests, TimeoutContractTests, deterministic advance tests.
- Full `swift test` must stay green; no new public seam to pin beyond adapter.

## Out of Scope
- Deadline race, generations reconfigure, registry wait, settlement, Bridge mapping.

## Further Notes
- Unblocks L3 (generations deterministic gate moves off prod Clock). If tests use Clock directly, migrate them to adapter in same ticket.
