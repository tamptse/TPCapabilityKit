## Problem Statement

One Lease lifecycle is spelled as four enums across two modules: the Lease tracker owns `State` (pending/active/completed/failed/expired, public) plus `Terminal` (completed/failed/expired, internal), while the Tasks path step owns `Settlement` (completed/failed/expired/cancelled) plus `Decision` (retry/complete/fail/expire). A reviewer asking "what are the terminal outcomes of a scheduled Task, and where is the retry choice made?" must hop four types to assemble one answer, and each hop is a drift risk: `Settlement.failed` drops its `Error` only for the row transition to re-mint a fresh execution error; `Settlement.cancelled` silently collapses to expired with no shape change on the Lease; `completed` carries its optional value through three separate associated-value spellings; `Decision` duplicates terminal cases (`complete`/`fail`/`expire`) beside the retry case so the decide-then-transition split reads as two decisions instead of one.

## Solution

Unify to a single Terminal vocabulary owned by one side with the other spelling kept only as a typealias, and fuse the outcome decision into the single row-transition site so decide-then-transition reviews as one path. `Decision` is deleted: the budget check, void-completion policy, and retry re-queue read adjacent to the lifecycle-table transition that applies them, inside the one locked settle step. The Lease mutation primitives stay infallible safety no-ops; all policy stays in Settlement. No behavior change: pending/active/terminal reachability, retry identity preservation, and waiter delivery are identical before and after.

## User Stories

1. As a Tasks maintainer, I want one Terminal type to read instead of four, so that terminal outcomes review in a single hop.
2. As a Lease consumer, I want `State` terminal cases and the Settlement outcome to share one vocabulary, so that completed/failed/expired mean the same thing on both sides of the seam.
3. As a Settlement reviewer, I want the retry budget check adjacent to the row transition that applies it, so that decide-then-transition reads as one path.
4. As a retry integrator, I want retry re-use of the same Lease identity preserved, so that completions and live Bridge views survive a retry.
5. As a cancel caller, I want cancel to keep settling through the expired path explicitly, so that no Lease shape change hides in the collapse.
6. As a failure debugger, I want the failed-error drop-and-remint to be stated once at the single transition, so that error identity is never re-litigated per path.
7. As a void-completion caller, I want the nil-result retry-vs-fail-vs-expire policy in exactly one place, so that fire-and-forget and typed waits agree.
8. As a Bridge consumer, I want the public `State` seam unchanged, so that live Lease views keep reflecting without churn.
9. As a test author, I want terminal reachability asserted through the public schedule/cancel/wait seam, so that the unify is proven by behavior not by enum spelling.
10. As a future contributor, I want `Decision` gone rather than deprecated, so that no second decision type can be re-imported by a new path.
11. As a reviewer, I want the single-writer contract (each Lease mutation paired with its row write under lock) stated once beside the unified type, so that new paths know never to call mutators directly.
12. As a scheduler operator, I want pending-to-parked-to-active-to-terminal plus retry re-queue to stay the one Tasks path, so that counts and slot admission are unaffected by the vocabulary change.
13. As an ADR reader, I want the change traceable to unified lifecycle ownership and Settlement-owned retry policy, so that the unify clearly respects prior decisions rather than reopening them.

## Implementation Decisions

- **Module**: Lease remains the lifecycle tracker; Tasks keeps park, Deadline expiry, activation, and the Settlement step. No new module is introduced; the unified Terminal type is owned by one side (Lease side preferred, since `State` is the public seam) with the other side keeping only a typealias during migration, then zero duplicates at rest.
- **Interface**: the public `State` seam (pending/active/completed/failed/expired, custom `==` ignoring associated `Error`) is unchanged. The internal `Terminal` / `Settlement` / `Decision` spellings collapse to one terminal vocabulary; `cancelled` remains a Settlement input that maps to the expired terminal explicitly at the single site, not a fourth Lease shape.
- **Depth**: depth decreases by one type (`Decision` deleted) and one spelling (`Terminal` vs `Settlement` merged). No new abstraction is added; the fused decide-plus-transition is the same locked step with the budget/policy lines moved adjacent, not a new decision layer.
- **Seam**: the highest seam stays the Tasks schedule/cancel/pending/active facade plus the single result rendezvous. Tests cross that seam; no new seam is created. The lifecycle table remains the single writer: each Lease mutation happens together with its row write in one locked transition.
- **Adapter**: no adapter change. The Bridge live Lease view reflects the unified `State` without modification; display/rawValue mappings are untouched.
- **Locality**: the retry budget check (`canRetry` read-only view), the void-completion policy (nil result with budget retries, nil without budget fails-or-expires by active-ness), and the retry re-queue share one reviewable block with the row transition, so the outcome-to-transition mapping needs no hop.
- **Leverage**: leverage is reviewer locality plus drift removal: one terminal list to extend, one policy block to audit, zero cross-enum sync. The mechanical risk (missed call site) is bounded because all writers already funnel through the single settle step.
- **Respects ADRs**: ADR-0009 (one lifecycle table keyed by task id; Settlement owns the row transition plus the single release) constrains the fuse to stay inside the existing settle step; ADR-0004 (Settlement owns retry budget, void policy, and re-queue through the shared path; Lease exposes only primitives plus a read-only budget view) forbids moving policy back into Lease; ADR-0005 (single result rendezvous with waiter preservation across retry and claim-once terminal delivery) requires retry to keep Lease identity and waiter preservation unchanged.

## Testing Decisions

- A good test crosses the public Tasks seam and asserts externally observable behavior (terminal state reached, retry count consumed, waiter delivered exactly once, cancel lands expired, void completion retries vs fails per policy), never the spelling of the unified enum or the absence of `Decision` as an implementation detail — except one mechanical grep proving no `Decision` reference remains.
- Modules under test: Lease transitions (pending→active→terminal, terminal rejects further mutation, retry resets to pending), Settlement policy (timeout→expired, nil-with-budget→retry, nil-without-budget→fail-or-expire, failed→fail-or-expire by active-ness, cancelled→expired), rendezvous delivery (waiters preserved across retry, claimed once at terminal).
- Prior art: lifecycle/settlement suites around the Tasks path (retry, cancel, timeout, void-completion, waiter preservation tests) plus Lease unit tests; the unify must keep every one green with zero test-semantics edits.

## Out of Scope

- Any change to terminal reachability (which states are legal from pending vs active), retry identity, waiter preservation, slot release ownership (stays with activation scope exit), or Deadline/expiry resolution.
- Changing the public `State` shape, its `Equatable` ignoring associated `Error`, or the Bridge live-view reflection.
- Touching State creation/observation, registry emission order, generation prune, or time adapters.
- Renames beyond the unify or formatting churn.

## Further Notes

- Ownership tie-break: if Lease-side vs Settlement-side ownership is contested during implementation, prefer Lease-side ownership because `State` is the public seam and the internal terminal is its strict subset; Settlement then typealiases during migration and the alias is removed at rest.
- `cancelled` stays an input-only spelling: it documents caller intent at the settle entry and maps to expired inside the fused site, so a future true cancelled Lease shape would be an explicit additive decision, not an accidental fork.
- Source of prototype decisions: none — no prototype; decisions derive from the four-enum inventory and ADR-0004/0009/0005.
