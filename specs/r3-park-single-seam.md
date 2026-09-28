## Problem Statement

The pending → parked → wait move crosses three lock acquisitions with a `Task` allocation wedged between them: the Path flow checks a park flag, then allocates the capability waiter, then stores the waiter, then patches a terminal race by cancelling the just-created waiter. The park protocol (begin / set-waiter / clear) lives in the caller, not in the lifecycle table: the caller decides the order, the table only stores fragments. The terminal patch proves the seam leaks — if the lease terminalizes between the first and second crossing, the caller must clean up a waiter the table never owned atomically. Double-park refusal and waiter-cancel rules are therefore reviewable only by holding caller plus table together, against the single-transition ownership the domain already promises.

## Solution

Fuse begin / set-waiter / clear into a single table-owned park seam. The Path flow hands park intent plus the waiter (or a factory the table invokes under its single transition) in one call; the table returns parked vs already-terminal in the same transition and owns clearing on wake and on terminal. The caller keeps no park protocol — one call to park, one table-internal clear. Deadline expiry, the registry whole-set wait seam, and activation stay untouched. No behavior change except atomicity: same parked reachability, same double-park refusal, same terminal-cancel, same waiter delivery.

## User Stories

1. As a Tasks maintainer, I want pending → parked → wait to cross one table seam, so that I stop auditing three lock crossings plus an interleaved allocation to answer one park question.
2. As a reviewer, I want double-park and waiter-cancel rules in the table beside the single transition, so that caller plus table no longer must be held together.
3. As a cancel caller, I want cancel-while-parked to land terminal with the waiter cancelled exactly once, so that no caller-side patch is needed to clean a half-parked waiter.
4. As a park waiter, I want wake to clear table state internally, so that a woken row never looks still-waiting to the next transition.
5. As a terminal path, I want terminal settlement to take and cancel the waiter in the same row removal, so that clear-on-wake and cancel-on-terminal cannot disagree.
6. As a priority scheduler, I want dequeue-to-parked placement unchanged, so that order and counts agree exactly as today.
7. As a Deadline consumer, I want expiry resolution and the shared waiter-vs-execution race untouched, so that timeout behavior is identical before and after.
8. As a registry consumer, I want whole-set readiness to keep receiving the expiry race as a value, so that the registry never names the expiry type.
9. As a slot operator, I want scoped-hold admission, FIFO wake, cancellable wait, and scope-exit release untouched, so that concurrency limits behave identically.
10. As a retry integrator, I want retry re-queue through the same Lease identity preserved, so that completions and live Bridge views survive a retry.
11. As a test author, I want park atomicity proven by behavior through the public schedule/cancel/wait seam, so that the fuse is verified by outcomes not by method spelling — except one mechanical grep proving the three-step protocol is gone from the caller.
12. As a future contributor, I want one park entry to call instead of three, so that no second park protocol can be re-introduced by a new path.
13. As an ADR reader, I want the change traceable to single-settlement, unified-lifecycle-ownership, and single scoped-hold decisions, so that the fuse clearly respects prior decisions rather than reopening them.

## Implementation Decisions

- **Module**: Tasks remains the deep module behind the schedule/cancel/pending/active seam. The lifecycle table gains one park transition (intent plus waiter in, parked vs already-terminal out); the Path flow keeps process/park/wait/activate/settle as the only flow reader. No new module is introduced.
- **Interface**: the public scheduling seam is unchanged (schedule/schedule-and-wait/cancel/pending/active plus result rendezvous). The internal change is begin-park plus set-waiter plus clear-wait collapse into one table-owned seam: the caller passes intent and the waiter (or a factory invoked under the single transition), the table sets the waiting flag and stores the waiter atomically and reports already-terminal when the lease terminalized first.
- **Waiter handoff shape**: prefer passing a waiter factory invoked under the single table transition over passing a pre-allocated `Task`, so no allocation sits between two lock crossings and the already-terminal patch disappears. If the factory form proves awkward under the scheduler lock (creation cost, Sendable capture), the fallback is pass-intent-plus-Task in one call with the table owning the cancel decision — still one crossing, never two. The chosen shape is stated once beside the new seam.
- **Clear ownership**: clear-on-wake and cancel-on-terminal move inside the table. Wake clears waiting flag plus waiter as part of the same row update; terminal takes the row (waiters plus waiter) in the existing single row-removal transition and cancels exactly once outside the lock. No caller-side clear call remains on either path.
- **Depth**: depth decreases by two caller-visible steps (three crossings to one). No new abstraction is added; the fused seam is the same row write plus Lease liveness check already owned by the table, with the waiter store moved adjacent, not a new park layer.
- **Seam**: the highest seam stays the Tasks schedule/cancel/pending/active facade plus the single result rendezvous and the registry whole-set wait. Tests cross that seam; no new seam is created. The lifecycle table remains the single writer: each Lease mutation happens together with its row write in one locked transition.
- **Expand–contract**: add the fused seam beside the three existing methods, migrate the single Path caller, then delete the three old methods. No flag, no dual-write window beyond the migration ticket; CI stays green batch to batch because the old form still exists until the migrate ticket lands.
- **Lock discipline**: the fused transition holds the one scheduler lock once and never nests. Waiter `Task` creation (or factory invocation) must not suspend under lock; expiry race, registry wait, and slot hold stay outside the locked section exactly as today.
- **Locality**: double-park refusal (second park of the same row is refused), waiter-cancel on terminal, and wake-clear share one reviewable block with the single transition, so the park-to-terminal mapping needs no hop into the caller.
- **Leverage**: leverage is atomicity plus drift removal: one crossing to audit, one owner of waiter lifetime, zero caller-side terminal patch. Risk is bounded because the move is spelling-plus-ordering only — same rows, same place values, same snapshot derivation, same waiter identity — only the crossing count changes.
- **Respects ADRs**: single-settlement path with scoped slot constrains settlement to keep the single terminal decision plus waiter preservation and scope-exit release untouched; unified lifecycle ownership requires the table (not the caller) to own the row transition plus waiter lifetime; single scoped-hold discipline forbids moving slot admission or release into the park seam.

## Testing Decisions

- A good test crosses the public Tasks seam and asserts externally observable behavior (parked reachability, double-park refusal, cancel-while-parked lands terminal with one waiter delivery, terminal cancels the waiter, wake clears so re-park behaves, counts agreement), never the spelling of the fused seam or the absence of the three old methods as an implementation detail — except one mechanical grep proving no caller-side begin/set/clear protocol remains.
- Modules under test: lifecycle table park transition (first park succeeds, second park refused, already-terminal reported, wake clears, terminal takes and cancels), Path flow (unavailable capabilities park once, capability arrival wakes to activation, expiry settles expired, cancel-while-parked settles expired with one delivery).
- Prior art: lifecycle suites (double-park plus counts, terminal removal plus same-id reschedule through the Tasks seam, retry restores pending), path locality proof (park/wait/cancel/retry single-delivery plus freed slot), determinism suites (virtual-time timeout, cancel-pins-expired, priority high-before-low, slot serialization), activation-gate and slot-hold suites (admission refusal, TOCTOU re-check, FIFO wake, cancellable wait). The fuse must keep every one green with zero test-semantics edits.
- Verification per ticket: `swift build` green plus full `swift test` green; grep proves the old three-step caller protocol shrinks monotonically (present beside the new seam after fuse, absent after migrate, unreferenced after pin).

## Out of Scope

- Any change to lifecycle reachability (which states are legal from pending vs parked vs active), priority ordering, retry budget or void-completion policy, waiter preservation or exactly-once delivery, slot limits or release ownership (stays with activation scope-exit), expiry resolution (task timeout vs configured default), or time adapters.
- Changing the public `State`/Terminal shape, the Bridge live-view reflection, State creation/observation, registry emission order or lock discipline, generation prune or shared-slot coupling, or deterministic-time spelling.
- Touching Deadline internals, the registry wait implementation, or the activation gate beyond its existing Path call site.
- Reopening single-settlement, unified-lifecycle-ownership, or scoped-hold decisions: no revisit trigger is met by this work; the fuse extends them to park, it does not redesign them.
- Reformatting or renames beyond the fuse.

## Further Notes

- Grill verdict (grill-with-docs, autonomous self-grill; decided, no questions asked):
  - R3-Q1 Three crossings or actually four (dequeue already moves to parked)? Adopted: dequeue places the row as parked; the three park crossings are begin/set/clear on top. The fuse covers begin/set/clear only; dequeue placement stays untouched. Strong angle, deepened into ticket-01 acceptance.
  - R3-Q2 Task alloc wedged between locks — is the window real or benign? Adopted: real. Pre-allocated waiter plus post-hoc terminal-cancel patch is the leak proof; factory-under-transition (or single intent-plus-waiter call) removes the window rather than patching it.
  - R3-Q3 Factory invoked under lock — does creation under lock risk suspension or cost? Adopted: constrain to non-suspending creation only; expiry race, registry wait, slot hold stay outside. Tie-break recorded in Implementation Decisions so implementers do not re-litigate.
  - R3-Q4 Does clear-on-wake vs cancel-on-terminal double-clear? Adopted: no — wake clears in place, terminal takes the row; take removes so no second clear exists. Both owned by the table, never by the caller.
  - R3-Q5 Does the table already claim single-seam park per the glossary? Adopted: yes, the Tasks glossary already states park crosses one park-and-wait seam with rules in the table — the code lags the contract. This candidate closes code-to-contract drift, it does not change the contract. No CONTEXT.md or ADR edit needed.
  - R3-Q6 One ticket or three? Adopted: three (fuse beside old, migrate caller, pin behavior) as expand–contract, so each lands green and the old protocol deletion is independently reviewable.
  - R3-Q7 Behavior change except atomicity — anything observable? Adopted: no. Same parked set, same order, same counts, same expiry, same delivery; only the interleaving window closes. Tests pin this by staying green with zero semantics edits plus new atomicity pins.
  - Rejected: fusing dequeue into the same seam (widens the transition to order mechanics for no atomicity gain), moving Deadline or activation into the park seam (violates untouched scope), adding a park state enum (leverage ~nil, adds spelling for a one-flag waiter rule).
- Deletion test is the acceptance bar: deleting the three old table methods (callers read only the fused seam) changes nothing observable through the public seam.
- Source of prototype decisions: none — no prototype; decisions derive from the three-crossing plus wedged-allocation inventory and single-transition ownership decisions.
