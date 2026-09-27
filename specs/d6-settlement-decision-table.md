## Problem Statement

A maintainer asking "what does Settlement decide, and what does it apply?" must read one locked block that does both: the retry budget check, the void-completion policy (nil result with budget retries; nil without budget fails when active else expires), the cancelled-to-expired mapping, the fresh execution-error mint, the retry re-queue, and the waiter delivery all sit inside a single decide-then-transition span. Each outcome audit re-proves locking, each policy audit re-reads row mechanics, and any future change to the budget or void rule has no named decision to move — only branches interleaved with the lifecycle-table transition that applies them.

## Solution

Isolate the Settlement outcome decision into one pure decision table beside the row-application step. The table consumes one unified raced-decoded input (the D7 post-state: timeout-empty vs won-with-value including stored-nil, plus the completion intent) together with the Lease read-only budget view and active-ness, and returns one directive — retry, complete, fail, or expire. The locked step then applies the directive: single row transition, single error mint, retry re-queue through the same Lease identity, waiter handling, and retry re-pump. No behavior change: reachability, retry identity, waiter preservation, exactly-once delivery, slot discipline, and re-pump are identical before and after.

## User Stories

1. As a Settlement maintainer, I want the retry budget check in exactly one pure table, so that budget audits land on one reviewable truth table instead of branches inside a locked block.
2. As a void-completion integrator, I want the nil-result retry-vs-fail-vs-expire policy stated once in the table, so that fire-and-forget and typed waits provably agree.
3. As a cancel caller, I want cancelled mapped to expired once at the decision boundary, so that no fourth Lease shape hides inside the row transition.
4. As a failure debugger, I want the failed-error drop-and-remint stated once at the apply site, so that error identity is never re-litigated per outcome.
5. As a retry integrator, I want retry to keep re-using the same Lease identity through the shared re-queue path, so that completions and live Bridge views survive a retry.
6. As a waiter holder, I want waiters preserved across retry and delivered exactly once at terminal, so that schedule-and-wait semantics are untouched.
7. As a slot operator, I want the apply step to keep never releasing the slot, so that activation scope-exit remains the single release owner.
8. As a lifecycle reviewer, I want completed/failed to stay active-only with expired accepting pending, so that terminal reachability is unchanged and reviewable from the table.
9. As a scheduler operator, I want retry re-pump behavior unchanged, so that a retried Lease re-enters the pump exactly as today.
10. As a race-topology integrator (D7), I want the table to consume one unified raced-decoded input, so that the old double-optional split between flow decode and settle policy never reappears.
11. As a drain owner (D4), I want the drain/pump region untouched by this work, so that pump-coalesce sequencing never conflicts with the decision extraction.
12. As a Lease consumer, I want the Lease to keep exposing only primitives plus the read-only budget view, so that all policy visibly lives in Settlement.
13. As a test author, I want the policy proven by behavior through the public schedule/cancel/wait seam, so that the extraction is verified by outcomes not by table spelling — except mechanical greps proving one decide site.
14. As a test author, I want the stored-nil vs never-stored truth table pinned (nil with budget retries, nil without budget fails-or-expires by active-ness), so that void completions cannot regress silently.
15. As a future contributor, I want one decision table to extend and one apply site to audit, so that no second decide-then-transition block can be reintroduced beside the fused one.
16. As an ADR reader, I want the change traceable to Settlement-owned retry/void policy and unified lifecycle ownership, so that the isolation clearly respects prior decisions rather than reopening them.

## Implementation Decisions

- **Module**: Tasks remains the deep module behind the schedule/cancel/pending/active seam. No new module is introduced; the decision table is internal mechanics of the existing Settlement step, and the Lease remains the lifecycle tracker exposing only transition primitives plus the read-only budget view.
- **Interface**: the public scheduling seam is unchanged (schedule, schedule-and-wait, cancel, pending, active, plus the single result rendezvous). The internal change is decide-then-apply: the pure table maps (unified raced-decoded input, budget, active-ness) to one directive, and the locked step applies it. Caller-visible outcomes, terminal vocabulary, and waiter delivery are byte-identical.
- **Decision shape** (the one allowed shape; from the self-grill, not a prototype):
  - input: unified raced-decoded outcome (timeout-empty vs won-with-value including stored-nil) plus intent (completed / failed / expired / cancelled)
  - reads: retry budget remaining, Lease active-ness
  - output: one of retry | complete(value) | fail | expire
  - truth rows: won-with-value completes; won stored-nil retries with budget else fails when active else expires; failed fails when active else expires; timeout-empty expires; cancelled normalizes to expired at the table boundary
- **Pure table vs closures**: the table is a pure function returning data, not closures capturing lock or Lease. Closures would drag row mechanics back into the decision and re-split what the extraction fuses; the data directive keeps decide testable by equality and apply auditable in one locked span.
- **Cancelled mapping site**: cancelled normalizes to expired once at the decision-table boundary, so the row transition speaks Terminal-only vocabulary. Mapping inside the locked apply is rejected because it keeps a fourth input spelling in the block being shrunk.
- **Error-minting site**: the table emits abstract fail; the apply site mints the fresh execution error once when applying it. Minting inside the table is rejected because error identity is effectful and would make the pure table untestable by equality (the public equality already ignores associated errors).
- **Waiter ownership**: waiter preservation across retry and claim-once terminal delivery stay in the apply step with the lifecycle-table transition (take waiters on terminal, preserve on retry, cancel the taken waiter task, re-pump on retry). Moving waiter handling into the table is rejected because waiter ownership is a table concern requiring the lock.
- **Seam**: the highest seam stays the Tasks scheduling facade plus the single result rendezvous. Tests cross that seam; no new seam is created. The table-to-apply wiring is internal mechanics: a single settle entry feeds a single table and a single locked apply, so per codebase-design one caller means a hypothetical seam — no protocol, no second adapter.
- **Adapter**: no adapter change. The Bridge live Lease view reflects the unchanged public state without modification.
- **Depth**: depth increases by factoring one pure decision out of one locked block with zero new abstraction at the interface. One truth table replaces N interleaved branches; callers learn nothing new.
- **Leverage**: leverage is audit locality — one policy table to extend, one apply span to audit, zero cross-site sync between budget, void rule, and mapping. Risk is bounded because the move is decide-then-apply factoring only: same inputs examined, same directives applied, same transitions taken.
- **Locality**: budget check, void policy, and cancelled normalization share one reviewable table adjacent to the single row transition that applies them, so outcome-to-transition mapping needs no hop.
- **D7 input assumption**: the table consumes the D7 post-state input (one unified raced-decoded value adjacent to settlement, not the legacy double-optional split between flow decode and settle policy). Ticket 01 carries the hard blocked-by D7 edge and must not land on the pre-D7 split.
- **Region discipline**: this work touches only the settle region plus the Lease budget view. The shared-race topology region is owned by D7 and the drain/pump region by D4; neither is edited here.
- **Respects ADRs**: single-settlement-with-scoped-slot constrains the work to keep one settle decision with waiter preservation and scope-exit release; settlement-owns-retry-and-void-policy forbids moving policy back into the Lease (Lease keeps the read-only budget view only); unified-lifecycle-ownership keeps the lifecycle table the single writer with Settlement owning the row transition.

## Testing Decisions

- A good test crosses the public Tasks seam and asserts externally observable behavior (terminal state reached, retry count consumed, waiter delivered exactly once, cancel lands expired, void completion retries vs fails per policy, timeout expires, retry re-pumps), never the spelling of the decision table — except mechanical greps proving exactly one decide site and no resurrected inline branches.
- Modules under test: Settlement decision rows (value completes; stored-nil with budget retries; stored-nil without budget fails-or-expires by active-ness; failed fails-or-expires by active-ness; timeout-empty expires; cancelled expires), Lease transitions (pending-to-active-to-terminal, terminal rejects further mutation, retry resets to pending with cleared result), rendezvous delivery (waiters preserved across retry, claimed once at terminal, taken-waiter cancellation on terminal).
- Prior art: lifecycle/settlement suites around the Tasks path (retry, cancel, timeout, void-completion, waiter preservation), activation-gate suites, slot-hold suites, and Lease unit tests; the isolation must keep every one green with zero test-semantics edits, plus new pins for the full decision truth table through the public seam.

## Out of Scope

- Any change to terminal reachability (which states are legal from pending vs active), retry identity, waiter preservation, exactly-once delivery, slot release ownership (stays with activation scope-exit), retry re-pump wiring, or Deadline/expiry resolution.
- The D7 race-topology unification (one value-carrying race plus single decode table): assumed post-state, not built here.
- The D4 drain/pump work: untouched region, no sequencing change.
- Changing the public Lease state shape, its equality ignoring associated errors, or the Bridge live-view reflection.
- Touching state creation/observation, registry emission order or whole-set wait, generation handling, or time adapters.
- Renames beyond the decision extraction or formatting churn.

## Further Notes

- Dependency: **hard blocked-by D7 (single-expiry race and timeout truth: one value-carrying race topology with single decode table adjacent to settlement)**. Ticket 01 must not land before D7: the decision table is specified against the unified raced-decoded input, and building it on the legacy double-optional split would bake the exact fork D7 exists to remove. Transitive edges flow 01 → 02 → 03.
- Region discipline: settle region plus Lease budget view only. The shared-race region is D7-owned and the drain/pump region is D4-owned; verification greps confirm neither region changed in this work.
- Preservation invariants (asserted per ticket): same-Lease-identity retry re-queue, waiter preserved across retry with exactly-once terminal delivery, never-releases-slot (activation scope-exit owns release), completed/failed active-only with expired accepting pending, retry re-pump unchanged.
- Deletion test is the acceptance bar: deleting the old inline decide branches (the settle step reads only the named decision table) changes nothing observable through the public scheduling seam.
- Self-grill verdict (autonomous self-grill; decided, no questions asked):
  - D6-Q1 Pure decision table vs closures? Adopted pure table returning data. Closures would recapture lock/Lease inside the decision and re-split decide vs apply; data directives keep the table equality-testable and the apply span single.
  - D6-Q2 Where does cancelled map to expired? Adopted table-boundary normalization. Mapping inside the locked apply would preserve a fourth input spelling in the block being shrunk and keep the row transition over non-Terminal vocabulary.
  - D6-Q3 Where is the execution error minted? Adopted apply-site mint-once. The table emits abstract fail; minting in the table makes a pure function depend on fresh error identity and breaks equality-based pins.
  - D6-Q4 Who owns waiter preservation across retry? Adopted apply step with the lifecycle-table transition. Waiter take-vs-preserve requires the lock and the row write; the table only emits retry vs terminal directives.
  - D6-Q5 Internal wiring vs new seam? Adopted internal wiring, no protocol. One caller over the table is a hypothetical seam per codebase-design; a protocol would add interface without a second varying adapter.
  - D6-Q6 Two tickets or three? Adopted three (extract, pin, verify-plus-handoff) in expand–contract order, so the mechanical extraction lands independently reviewable from the new behavior pins and the D7 handoff is a reviewable artifact.
  - Rejected: moving budget/policy into the Lease (reopens the settlement-owns-policy decision), minting errors in the table (breaks purity), waiter logic in the table (leaks the lock), a decision-delegate protocol (leverage ~nil with one caller), redefining reachability or release ownership (out of scope).
- Source of prototype decisions: none — no prototype; decisions derive from the settle-block inventory (budget check, void rows, cancelled mapping, error mint, re-queue, waiter fan-out, re-pump), the Lease primitive inventory (budget view, retry reset, terminal vocabulary), and the D7/D4 region split.
