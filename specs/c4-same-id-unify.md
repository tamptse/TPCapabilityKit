## Problem Statement

One domain policy — what happens when a second Task is scheduled under an id
whose row is still non-terminal — currently has two owners. The Tasks enqueue
step settles the displaced Lease as expired (delivering its waiters exactly
once, cancelling its park waiter Task, releasing its slot) before the new row
takes the id, while the slot controller's park step independently retires a
stale waiter under the same task id (deferred resume-false) and rejects
same-id arrivals through its own duplicate guard. Reviewers must hold both
halves in one head to answer "who evicts the old holder", and a future change
to either half alone can strand a waiter or double-resume one. The C3 cleanup
kept the single locked lifecycle transition as the only visible Lease writer;
this candidate extends the same single-owner picture to the same-id policy, so
the transition seam stays the only place Leases change hands.

## Solution

Give Tasks sole ownership of the same-id policy and narrow the controller to
pure admission. The controller exposes one small evict-stale-waiter seam,
`retire(taskId:owner:)`, which removes any waiter queued under the task id
whose owner is not the newcomer and resumes it with false (self-retire
no-ops). The enqueue step — the single funnel both schedule entries cross —
settles the displaced Lease through the existing settlement path first, then
calls the retire seam, then inserts the new row. Park slims to admission plus
FIFO order plus cancellable wait (keeping only the same-Lease re-entrancy
guard, which is admission, not policy) and no longer names task-id identity.
Observable behavior through the scheduling facade is unchanged: overwrite
still expires the old row exactly once, sequential reuse still works, FIFO
wake order and scope-exit release are untouched.

## User Stories

1. As a Plugin author reusing a task id concurrently, I want the old Lease to
   keep expiring exactly once with its completion delivered, so that overwrite
   never orphans my waiter.
2. As a Plugin author reusing a task id sequentially, I want reuse after
   terminal to keep working untouched, so that id lifecycle semantics are
   unchanged.
3. As a Plugin author awaiting a result, I want my waiter to keep resuming
   exactly once across displacement, so that no double-resume or stranded
   waiter appears.
4. As a Plugin author queuing under contention, I want FIFO wake order to
   stay identical, so that fairness promises survive the split.
5. As a Plugin author cancelling parked work, I want cancel-while-waiting to
   keep working with no leaked hold, so that cancellation still strands
   nothing.
6. As a schedule-and-wait caller, I want my call to get the same displacement
   fix as fire-and-forget with no second patch, so that both entries behave
   identically because they share one funnel.
7. As a Tasks maintainer, I want the enqueue step to read as the single place
   that decides same-id displacement, so that the next policy change has
   exactly one seam to audit.
8. As a Tasks maintainer, I want the controller park to read as pure
   admission (can-acquire plus FIFO plus cancellable wait), so that slot
   reviews never need the Lease lifecycle in mind.
9. As a Tasks maintainer, I want the scope-exit release guard to stay where
   it is, so that a displaced-active row's stale scope-exit still cannot
   release the new holder's slot.
10. As a Tasks maintainer, I want no lock nesting between the scheduler lock
    and the controller lock, so that the Store-to-Tasks lock order stays
    intact.
11. As a reviewer, I want the single-transition picture from the C3 cleanup
    preserved — retire touches slots only, never a Lease or a row — so that
    the lifecycle table remains the only Lease writer.
12. As a test author, I want displacement covered once through the scheduling
    facade, so that no controller-direct test pins the policy the controller
    no longer owns.
13. As a test author, I want the narrow retire seam pinned directly with one
    small test, so that the evict-stale contract is explicit without
    re-pinning the whole policy below the facade.
14. As a reviewer, I want the full existing suite green with no behavior
    change, so that this refactor is provably semantics-preserving.
15. As a future contributor, I want one obvious home for same-id decisions
    and one obvious seam for slot eviction, so that new paths cannot
    accidentally grow a second policy owner.

## Implementation Decisions

- **Module**: Tasks owns the same-id policy end to end; the slot controller
  remains the slot module owning admission, FIFO wake order, cancellable
  wait, and scope-exit release. No new module is introduced, and no Lease or
  row logic moves into the controller.
- **Interface**: the controller gains exactly one narrow seam,
  `retire(taskId:owner:)`. Its contract: evict any queued waiter under
  `taskId` whose owner differs from the given newcomer owner and resume it
  with false; a call naming only its own waiter no-ops. The rejected
  alternative (pass the displaced Lease so the controller retires that exact
  owner) is fragile — Tasks would have to name a waiter it may never have
  parked — while newcomer-keyed retire is robust to "stale waiter unknown".
  The Lease-keyed hold spelling stays for acquire/park/cancel/release; retire
  is the deliberate exception because it names a different holder than the
  caller.
- **Depth**: no depth change — one policy owner instead of two is strictly
  shallower. The retire seam adds interface but removes the implicit
  retire-inside-park, so net interface shrinks: park loses the deferred
  retire plus the cross-owner duplicate branch.
- **Seam**: the highest seam stays the scheduling facade
  (schedule/schedule-and-wait/cancel/pending/active). Tests pin displacement
  there; the retire seam is the single cross-module seam Tasks crosses for
  eviction, and it is slot-only by construction (resumes a continuation,
  touches no Lease, crosses no lifecycle transition).
- **Adapter**: no adapter change. The Bridge stays the single ObjC scheduling
  adapter and is untouched; displacement is invisible from Objective-C.
- **Leverage**: both schedule entries funnel through the one enqueue step, so
  the fix lands once and covers both — the quantified reason no second edit
  is needed. The schedule-and-wait waiter-attach guard (a mismatched row
  means our Lease is already settled, never append to another Lease's list)
  already assumes settle-before-replace; this change preserves that
  invariant, so that guard needs no edit.
- **Locality**: settle-then-retire-then-insert reads as one displacement path
  in the enqueue step, adjacent to the comment that already states the
  policy. Park reads as admission-only with no task-id branches to skip.
- **Owner choice**: Tasks, because it already owns the lifecycle row keyed by
  task id plus the settle path that terminalizes the displaced Lease. The
  controller has no Lease-lifecycle visibility, so owning eviction there
  forces it to guess terminality (today via "displaced is terminal, retire
  cannot strand work"). After the move the controller guesses nothing.
- **Ordering**: enqueue settles the displaced Lease first (terminalize,
  waiter delivery, park-waiter Task cancel through the single transition),
  then retires the stale controller waiter, then inserts the new row — each
  step outside the other's lock, never nested. Settle-first is load-bearing:
  the controller resume-false must land on an already-terminal Lease so it
  can never be mistaken for a live admission refusal. Lock-nesting in either
  direction is rejected per the Store-to-Tasks lock-order contract.
- **Duplicate-guard split**: the cross-owner same-id duplicate branches leave
  park with the stale-retire; the same-Lease re-entrancy guard stays (same
  `Lease` acquiring twice while held returns duplicate/false). That guard is
  admission — it names one holder, not a policy between two — and the
  double-acquire test keeps its pin at the controller seam. Removing it would
  trade a real re-entrancy pin for slogan purity; keeping the task-id
  branches would keep the split this candidate exists to close.
- **Release guard stays**: the scope-exit owner check (held entry's owner
  must equal the exiting Lease, else no-op) is safety, not policy — it stops
  a displaced-active row's stale scope-exit from releasing the new holder's
  slot. It is untouched, and its displaced-active self-heal behavior is
  unchanged.
- **C3 picture preserved**: the relocated decision-adjacent settlement step
  and the single locked transition are not crossed differently; retire never
  terminalizes, delivers no lifecycle waiter, and cancels no park Task. The
  lifecycle table remains the only Lease writer by construction.
- **No observable behavior change**: same expired-on-overwrite outcome, same
  exactly-once terminal delivery, same waiter preservation across retry, same
  retry-budget and void-completion policy, same FIFO order, same counts
  snapshots, same sequential-reuse path (terminal row needs no
  settle-or-retire).
- **Respects ADRs**: the task-keyed rendezvous record (same-id concurrent
  scheduling unsupported; overwrite settles old as expired before the new row
  takes the id; sequential reuse untouched), the Lease-keyed scoped-hold
  record (retire is the named exception, not a second token spelling), the
  scoped-hold FIFO-cancellable record (admission, order, cancellable wait,
  scope-exit release stay in the controller), and the Store-to-Tasks
  lock-order record (no nesting introduced).

## Testing Decisions

- A good test pins externally observable displacement behavior through the
  scheduling facade (old completion is expired exactly once, new completion
  is completed, counts drain to zero), never which module evicted which
  waiter.
- Modules under test: the enqueue displacement path (overwrite + sequential
  reuse through the facade), the narrow retire seam (stale waiter evicted
  with false, self-retire no-ops, admitted holder unaffected), and the
  admission seam (double-acquire still rejected, FIFO order preserved).
- Prior art: the settlement overwrite test (old-expired-once plus
  new-completes through the facade), the sequential-reuse test, and the
  controller slot-hold suite (double-acquire rejection, same-id displacement
  of a parked waiter) are the models — the first two stay untouched as the
  regression net, the third is the suite being merged.
- The controller-direct same-id displacement test is deleted and its
  coverage moves up: the facade overwrite test already asserts the full
  displacement outcome, and a new narrow retire test pins only the
  evict-stale contract (queued stale waiter resumed false, newcomer parks
  and is later admitted). No test pins retire-inside-park after the slim.
- The SlotHold and Lifecycle matrix suites merge at the facade seam:
  admission, FIFO, cancel-while-waiting, overwrite, and sequential reuse
  read as one matrix through schedule/cancel/counts, with only the narrow
  retire plus double-acquire pins remaining at the controller seam.
- Verification: focused settlement plus slot suites first, then the full
  suite green; grep confirms no production or test caller depends on the
  removed park retire path.

## Out of Scope

- Any semantic change to activation, settlement, retry budget, void policy,
  cancellation, timeout/expiry, capability matching, priority order, or
  sequential same-id reuse.
- Moving or reshaping the lifecycle table, the order index, the outcome
  decision, the Deadline race, the registry wait seam, or the release
  scope-exit guard.
- Touching the state database, capability registry, Bridge translators and
  delivery, time adapters and advance policy, generations, the domain
  glossary, decision records beyond a new ADR entry, or package manifest.
- Introducing new observation or waiting seams, new validated types, or any
  new public interface beyond the single internal retire seam.

## Further Notes

Grill record (autonomous self-grill, two rounds; coordinator delegated all
open questions, recommendations adopted):

- Round 1, Q1 — Owner choice: Tasks owns the policy, controller exposes a
  narrow evict seam? Yes: Tasks already owns the id-keyed row and the settle
  path; the controller cannot see terminality and today must assume the
  displaced Lease is terminal. The reverse (controller owns, Tasks delegates)
  would give the lifecycle-blind module authority over Lease handoff.
  Adopted.
- Round 1, Q2 — Seam shape: `retire(taskId:owner:)` keyed by the newcomer
  rather than the displaced Lease? Yes: newcomer-keyed evict-any-non-owner
  is robust when Tasks never parked a waiter for the stale id; exact-owner
  retire would require Tasks to name state it may not hold. A Lease-only
  spelling would hide the task-id keying the seam exists to name. Adopted.
- Round 1, Q3 — Waiter-cancel / slot-release ordering: lifecycle settle
  first, then controller retire, then insert, locks never nested? Yes:
  settle-first guarantees the resume-false lands on a terminal Lease and can
  never read as a live refusal; nesting either lock inside the other
  violates the Store-to-Tasks order. Retire-first rejected as racy.
  Adopted.
- Round 1, Q4 — Test merge: facade overwrite test becomes the displacement
  pin, controller-direct same-id test deleted in favor of a narrow retire
  test? Yes: pinning the policy below the facade would re-split ownership in
  test form; the facade test already asserts the full outcome. Adopted.
- Round 2 (Strong deepening), Q5 — Does the same-Lease double-acquire guard
  stay in park despite "no identity"? Yes, refined: "no identity" means no
  task-id policy, not no holder distinction. Same-owner re-entrancy is
  admission (one holder, duplicate entry), keeps its existing pin, and costs
  one equality branch. The cross-owner branches leave with the retire.
  Adopted.
- Round 2, Q6 — Does schedule-and-wait need its own edit? No: both entries
  funnel through enqueue, and the waiter-attach identity guard already
  assumes settle-before-replace, which this change preserves rather than
  alters. A second patch would be a duplicate owner in edit form. Adopted.
- Round 2, Q7 — Does the release scope-exit owner check move with the
  retire? No: it is safety against stale scope-exit releasing a new holder's
  slot (the displaced-active self-heal), not displacement policy. Moving it
  would reopen the exact slot-theft the guard closed. Adopted (stays).
- Round 2, Q8 — Merge SlotHold plus Lifecycle matrix suites now or leave
  them? Merge now at the facade seam: post-slim the controller-direct suite
  would otherwise pin admission behavior twice (once below, once above the
  seam) with no policy left below to justify it. Only narrow retire plus
  double-acquire pins remain at the controller seam. Adopted.

Strong recommendation holds after both rounds: one policy with two owners is
strictly riskier than one owner plus one narrow evict seam, and the funnel
shape (both entries through enqueue) makes the unification a single-point
fix with facade-level verification.
