## Problem Statement

The Tasks deep module already funnels every Lease lifecycle mutation through one
locked transition seam on the lifecycle table, but three thin per-move wrappers
still sit around that seam and a free outcome-decision function lives outside
the module that applies it. The wrappers add apparent depth without real depth:
one delegates trivially to the single transition from a single activation-gate
caller, one has no production or test callers at all, and the third has no
production callers while duplicating row removal without the paired Lease
terminalization — a second writer that re-opens the exact split-brain the
single-writer unification closed. The free decision function is called from
exactly one place (the settlement step) yet reviews as a separate unit,
forcing reviewers to hold decision and application in two heads instead of one
decide-then-transition path.

## Solution

Collapse the fake depth into the one real seam with zero semantic change. Inline
the single activation wrapper at its only call site so every mutation visibly
crosses the transition seam; delete the two caller-less wrappers outright
(the row-removal-only one is an invariant-violating duplicate, not a
convenience); and relocate the outcome-decision function into the Tasks path
scope immediately adjacent to the settlement step that applies it, so
decide-then-transition reviews as one path. Observable behavior through every
public seam stays identical.

## User Stories

1. As a Plugin author scheduling work, I want activation to keep leaving Lease
   state and scheduler counts in agreement, so that "active" still means the
   same thing wherever I observe it.
2. As a Plugin author awaiting a result, I want successful completion to keep
   delivering my completion exactly once with the Lease terminal, so that this
   cleanup never costs me a delivery.
3. As a Plugin author with a flaky execution, I want a retry to keep resetting
   the Lease and re-queuing the row as one atomic move, so that budget
   accounting and re-queue can never split apart.
4. As a Plugin author cancelling parked work, I want cancel to keep expiring
   the Lease and draining the row together, so that cancellation still leaks
   nothing and strands no waiter.
5. As a Plugin author reusing a task id, I want sequential reuse to keep
   working exactly as today, so that id lifecycle semantics are untouched.
6. As a Tasks maintainer, I want the locked transition to be the only visible
   writer with no delegating wrappers around it, so that the next lifecycle
   change has exactly one seam to audit.
7. As a Tasks maintainer, I want no row-removal path that skips the paired
   Lease mutation, so that the single-writer invariant holds by construction
   instead of by convention.
8. As a Tasks maintainer, I want dead wrappers with zero callers gone rather
   than kept "just in case", so that the interface advertises only seams the
   module actually crosses.
9. As a Tasks maintainer, I want the outcome decision to read adjacent to the
   settlement step that applies it, so that decide-then-transition reviews as
   one path in one scroll.
10. As a Tasks maintainer, I want the activation gate to show the transition
    call directly, so that the admit-then-activate flow needs no hop to follow.
11. As a reviewer, I want the deletion test to pass — removing any remaining
    wrapper breaks the build — so that fake depth cannot silently reappear.
12. As a reviewer, I want the full existing suite green with no behavior
    change, so that this refactor is provably semantics-preserving.
13. As a reviewer, I want the one table-level test that used the divergent
    removal path to drain through the single transition seam instead, so that
    no test bakes in the split-brain the module just closed.
14. As a Bridge consumer, I want the live Lease view to keep reflecting every
    transition with no sync call, so that this refactor stays invisible from
    Objective-C.
15. As a future contributor, I want one obvious home for decision logic and one
    obvious seam for lifecycle writes, so that new paths cannot accidentally
    grow a second writer or a second decision site.

## Implementation Decisions

- The lifecycle table keeps its single locked transition as the sole writer
  seam; this change removes interface around it and moves no write logic.
- The activation-gate wrapper is inlined at its only call site: the gate keeps
  its three-way outcome shape (proceed / failed / refused) and the lock scope
  still covers exactly one transition call, so lock ordering is unchanged.
- The retry wrapper is deleted outright with no replacement: it has zero
  callers in production and tests, and the settlement step already selects the
  retry move through the single transition.
- The terminal-removal wrapper is deleted outright with no replacement: it has
  zero production callers, and unlike the transition's terminal move it removes
  the row without terminalizing the Lease, so keeping it would preserve a
  second writer that violates the single-writer invariant. Deletion is the fix,
  not just a cleanup.
- The outcome-decision function moves into the Tasks path scope as a private
  member placed immediately above the settlement step; its signature shape and
  call-site spelling stay equivalent so the diff reads as a move.
  The considered alternative (a static member on the nested outcome type) is
  rejected to keep the diff minimal: adjacency, not re-typing, is what makes
  decide-then-transition review as one path.
- The nested outcome and decision types do not move or change: they already
  live in the right scope; only the free function joins them.
- No deprecation period: all three wrappers and the free function are internal
  seams, so outright removal is safe and preferable to a compatibility shim.
- No observable behavior change: same states, same counts snapshots, same
  exactly-once terminal delivery, same waiter preservation across retry, same
  retry-budget and void-completion policy, same slot release ownership at the
  activation scope exit.
- The change respects the unified lifecycle ownership record (one table owns
  lease, place, execution, and waiters), the order-index-internal refinement
  (place, order, and counts cannot disagree), and the Settlement-owns-budget
  record (budget checks and reset decisions stay in Settlement scope, which the
  relocation honors by moving decision logic toward, not away from, that
  scope). It also fulfills the domain glossary line stating the outcome
  decision reads adjacent to the settlement step.

## Testing Decisions

- Good tests for this change exercise external behavior through existing
  seams (the scheduling facade, scheduler counts, completion delivery) and
  assert nothing about wrapper existence; no new seams are introduced.
- The one table-level test that drains a row through the removed divergent
  path is updated to drain through the single transition seam with its terminal
  move, keeping its existing counts assertions intact. This keeps table-level
  coverage without pinning the deleted interface.
- No test references the retry wrapper, the activation wrapper, or the free
  decision function directly (verified by search), so no other test file needs
  modification; the relocation must keep every existing settlement, retry,
  cancel, and lifecycle-agreement test green unchanged.
- Prior art: the lifecycle-table suite (double-park, cancel-reschedule,
  retry-restores-pending), the lifecycle-transition agreement suite, and the
  settlement suite establish the through-seam patterns this verification
  follows.
- Verification: focused lifecycle plus settlement suites first, then the full
  suite green; build regularly during the change.

## Out of Scope

- Any semantic change to activation, settlement, retry budget, void policy,
  cancellation, timeout/expiry, slot admission and release, or same-id reuse.
- Moving or reshaping the nested outcome/decision types, the park/waiter
  mechanics, the order index, or any other Tasks internal mechanics.
- Touching the state database, capability registry, Bridge translators and
  delivery, time adapters and advance policy, concurrency control, the domain
  glossary, decision records, or package manifest.
- Introducing new observation or waiting seams, new validated types, or any
  new public interface.

## Further Notes

Grill record (self-grill, two rounds; coordinator delegated all open questions,
recommendations adopted):

- Round 1, Q1 — Inline versus keep the activation wrapper for call-site
  readability? Inline: the delegation body is a single pattern match with no
  logic worth naming, and the gate already names the outcome; the hop costs
  more than it explains. Adopted.
- Round 1, Q2 — Is the terminal-removal wrapper really deletable, given one
  test calls it? Yes, and deletion is load-bearing, not cosmetic: it removes
  the row without the paired Lease mutation, so it is a second writer by
  behavior, not just a wrapper by shape. The test is migrated to the terminal
  move of the single seam. Adopted.
- Round 1, Q3 — Does deleting the retry wrapper risk a future caller wanting
  it? No: zero callers plus full delegation means it fails the deletion test
  today; a future path should call the single seam directly rather than route
  through a synonym. Adopted.
- Round 1, Q4 — New home for the decision function: adjacent private member
  versus static on the outcome type? Adjacent private member: same locality
  gain with a smaller diff and unchanged call-site spelling. Adopted.
- Round 1, Q5 — Lock-scope risk from inlining? None: one locked region around
  one transition call before and after; verified by inspection. Adopted.
- Round 2 (Strong deepening), Q6 — Should the nested outcome/decision types
  move as part of the relocation? No: they already sit in the Tasks path
  scope; moving them would widen review surface for zero locality gain.
  Adopted.
- Round 2, Q7 — Deprecation shim for the removed wrappers? No: internal seam
  with no external adopters; a shim would preserve the fake depth this
  candidate exists to remove. Adopted.
- Round 2, Q8 — Does the decision relocation alter the "decision stays in
  place" constraint from the earlier single-writer candidate? No: that
  constraint forbade mixing write-path unification with a seam move in one
  change; this candidate is exactly the later, separately-reviewed seam move
  it deferred to. Adopted.

Strong recommendation holds after both rounds: the wrappers are depth without
depth and the divergent removal path is an invariant violation, so collapse is
strictly safer than the status quo; the decision move completes the
decide-then-transition locality the glossary already promises.
