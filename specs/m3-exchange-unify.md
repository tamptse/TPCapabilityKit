# M3 — Exchange fan-out unify (single insert seam)

## Problem Statement

Two schedule entries duplicate the same tail: displace delivery plus pump kick. The wait entry wraps the plain insert with liveness pre/post checks, mirroring its result fields by hand, so same-id semantics differ subtly by entry and reviewers must check two call sites.

## Solution

Keep the plain insert as the canonical exchange. Turn the wait rendezvous into a thin wrapper that guards terminal identity, delegates to insert, re-guards freshness, and wraps the canonical result instead of mirroring fields. Funnel both schedule entries through one private finish-exchange helper that delivers displaced waiters, notes slot eviction, and kicks the pump outside the scheduler lock.

## User Stories

1. As a scheduler author, I want one displace-deliver-pump tail, so that same-id behavior cannot diverge by entry.
2. As a fire-and-forget caller, I want zero-waiter exchange without continuation overhead, so that the fast path stays fast.
3. As a wait caller, I want early-settled identity to return without parking, so that cancelled-before-park never strands.
4. As a reviewer, I want outcome nesting instead of field mirroring, so that new displaced fields propagate automatically.
5. As a retry reader, I want settlement untouched by exchange unify, so that same-identity retry review stays separate.

## Implementation Decisions

- Module: lifecycle table owns canonical insert with atomic take-row plus terminalize plus eviction-obligation mint in one locked seam; scheduler owns the finish-exchange helper; table never calls pump or slots.
- Interface: insert keeps multi-waiter list shape (zero-to-many preserved waiters); rendezvous keeps parked vs settled-early shape but parked wraps the canonical result.
- Terminalize stays inside insert under lock; half-displaced identifiers never observable.
- Finish-exchange runs outside the scheduler lock: cancel waiter task, deliver preserved waiters, note slot eviction if present, then kick pump. Never holds scheduler lock across waiter delivery or controller calls.
- Retry path untouched: same-Lease reuse, waiters preserved, not via insert.
- Grill (auto): optional-single-waiter signature rejected (loses zero-to-many distinction); deleting canonical result rejected (fire path needs it); deleting rendezvous outcome rejected (wait path needs early-settled case); moving terminalize to caller rejected (opens half-displaced window).

## Testing Decisions

- External behavior only: concurrent overwrite, slot contention keeps-new, cancel-after-overwrite lands on new, wait-storm never joins new, parked-cancel never runs.
- Modules: public schedule seam plus exchange seam.
- Prior art: same-id exchange pins, displacement pairing tests, fire agreement tests, rendezvous pins, retry identity tests.
- Full suite green; retry and settlement subsets must pass untouched.

## Out of Scope

- Ordering policy changes (M2); eviction ownership moves (M4); settlement decision changes; public schedule shape changes; slot admission policy changes.

## Further Notes

- Blocked by M2 (needs stable exchange shape); blocks M4 (leaves exactly one call site to audit lock order). Respects single-rendezvous, same-id-unsupported, scoped-hold, and lock-order ADRs.
