## Problem Statement

A maintainer asking "what does reading a count do?" must hold a contradiction together: every count read (pending, active, generation count) routes through one generations snapshot whose first step prunes drained generations by mutating the generations array — a read that spells a write. The prune holds the scheduling lock while asking each non-current generation for its drain state, and each drain answer takes that generation's scheduler lock, so the single Store-to-Tasks lock nesting lives unnamed inside a getter. The module header simultaneously claims no caller holds a Store lock across a submodule call, which the prune quietly violates. Each getter is correct in isolation; together they force every count audit to re-prove mutation-safety per getter, every lock audit to rediscover the nesting per read, and any future move of reaping to explicit points (reconfigure, settle) has no named seam to move — only an anonymous side-effect inside the read path.

## Solution

Extract the prune into one named reap pass that states the Store-to-Tasks order once, hardens the crossing (copy the generation list under lock, ask drain state outside the lock, sweep under lock removing only still-present non-current generations flagged drained), and keeps every observable count identical with the getter-to-snapshot-to-reap wiring unchanged in this phase. No behavior change: same summed counts across live generations, same shared slot admission, same current-never-reaped rule, same precede-first-use gate reading the same pruned count, same reconfigure drain behavior. Deletion test: removing the old anonymous prune spelling (callers read only the named reap pass) changes nothing observable through the public scheduling seam. Full separation — getters as pure reads with reaping only at explicit reconfigure/settle points fed by a settle/drain notification — is a defined follow-up explicitly blocked by T2 pump-coalesce, which owns the drain lifecycle hook this work deliberately does not invent.

## User Stories

1. As a Store maintainer, I want the prune to live behind one named reap pass, so that every count audit lands on one reviewable crossing instead of re-proving mutation-safety per getter.
2. As a reviewer, I want the Store-to-Tasks lock order stated once at the reap pass, so that lock audits stop rediscovering the nesting inside each getter.
3. As a reviewer, I want the module header's no-lock-across-submodule-call claim corrected to name the reap pass as the single allowed Store-to-Tasks crossing, so that the documented discipline matches the actual discipline.
4. As a counts consumer, I want pending, active, and generation-count values bit-identical before and after, so that no caller relearns what a count means.
5. As a reconfigure caller, I want reconfigure to keep appending a fresh generation and reaping drained ones with identical outcomes, so that in-flight drain behavior is untouched.
6. As a slot operator, I want the sum-vs-share split (counts sum across live generations while admission shares one Store-owned domain) stated once and untouched, so that reconfigure never doubles the configured limit during drain exactly as today.
7. As a deterministic-time user, I want the precede-first-use gate to keep reading the same pruned count, so that enable-before-first-schedule keeps its exact meaning.
8. As a concurrent scheduler, I want drain checks to run outside the scheduling lock, so that a contended generation cannot stall unrelated scheduling work and the crossing shrinks to two short critical sections plus lock-free drain checks.
9. As the drain-lifecycle owner (T2 pump-coalesce), I want the drain definition (empty pending plus active from one acquisition) untouched and the reap trigger points unchanged, so that pump-coalesce can redefine drain without rebasing around a parallel redefinition.
10. As a future contributor, I want an explicit named reap entry callable from reconfigure and settle points, so that the eventual getter-purity move has a seam to relocate instead of an anonymous getter side-effect.
11. As a cancel caller, I want cancel to keep fanning out across a safely-copied generation list, so that cancel behavior is identical.
12. As a Bridge consumer, I want bridge count views unchanged, so that ObjC-visible pending and active keep agreeing with the Store facade.
13. As a test author, I want the existing generation suites to stay green with zero semantics edits, so that the work is proven spelling-only.
14. As a test author, I want new pins proving reap idempotence and current-never-reaped, so that the named pass carries behavior guarantees rather than just a new name.
15. As an ADR reader, I want the change traceable to the generations snapshot and slot-sharing decisions, so that the hardening clearly extends prior decisions rather than reopening them.
16. As a T2 integrator (follow-up, blocked by T2 pump-coalesce), I want getters to become pure reads with reaping only at explicit reconfigure/settle points fed by a settle/drain notification, so that reads stop writing state entirely.
17. As a T2 integrator (follow-up, blocked by T2 pump-coalesce), I want the non-current-generations-drain-monotonically invariant re-proven against coalesced pumping before the sweep shape changes, so that the flag-then-sweep safety argument survives the new pump.
18. As a future contributor, I want no second prune spelling to exist, so that no parallel reap protocol can be re-introduced beside the named pass.

## Implementation Decisions

- **Module**: the Store scheduling-generations module keeps its shape (generation list, shared slots, shared clock behind the scheduling facade). Only the prune entry consolidates into one named reap pass. No new module is introduced.
- **Interface**: the public scheduling seam is unchanged (schedule, schedule-and-wait, cancel, pending, active, configure, plus the internal generation-count and deterministic-time controls). The internal change is the anonymous prune-then-loop becomes a named reap step feeding the unchanged sum loop; getters keep delegating to the snapshot in this phase.
- **Reap shape**: copy-check-sweep — copy the generation list under the scheduling lock, ask each non-current generation for drain state with no scheduling lock held, re-acquire and remove only generations still present, still non-current, and flagged drained. The current generation is never reaped even if drained.
- **Why no re-check under lock**: non-current generations drain monotonically — new work lands only on the current generation, cancel only removes, retry re-queues within its own generation — so a generation flagged drained cannot become live again before the sweep. This invariant is stated once beside the sweep and is the explicit assumption T2 must re-prove.
- **Drain definition untouched**: drained still means empty pending plus active from one scheduler acquisition. Redefining it belongs to T2 pump-coalesce; this work moves where the question is asked (outside the lock) without changing the question.
- **Lock discipline**: the reap pass is the single allowed Store-to-Tasks crossing, stated once at the pass. Everywhere else the header discipline stands: no caller holds the scheduling lock across a submodule call. Cancel keeps its copy-then-fan-out shape with no lock held across scheduler calls.
- **Header doc correction**: the no-lock-across-submodule-call claim is narrowed to name the reap pass as the one exception, so documentation and behavior agree in exactly one place.
- **Seam**: the highest seam stays the Store scheduling facade plus the internal generation-count and deterministic-time controls. Tests cross that seam; no new seam is created. The reap pass is internal mechanics, directly callable from reconfigure today and from a future settle hook after T2.
- **Expand–contract**: the named pass lands beside the old prune spelling (mechanical, independently reviewable), call sites migrate to it, then the old spelling is deleted. Each ticket lands green because no ticket changes reachability, counts, ordering, or delivery.
- **Leverage**: leverage is audit locality plus contention reduction — one named crossing, one lock-order statement, drain checks outside the lock. Risk is bounded because the move is spelling-plus-ordering only: same generations examined, same drain question, same removals, same counts.
- **Respects ADRs**: generations-snapshot ownership requires counts to keep summing across live generations; slot-sharing requires admission to stay on the one Store-owned domain; the single generations snapshot keeps stating the sum-vs-share split once. None are reopened.

## Testing Decisions

- A good test crosses the public Store scheduling seam and asserts externally observable behavior (pending/active sums across live generations under one shared limit, generation count dropping to one after drain, reconfigure preserving in-flight work, precede-first-use gate behavior), never the spelling of the reap pass — except mechanical greps proving the old anonymous prune spelling is gone and the Store-to-Tasks crossing exists only at the named pass.
- Modules under test: generations snapshot and reap (idempotent reap, current-never-reaped, drained release after natural drain, sums hold across two live generations), reconfigure path (append plus reap with in-flight preservation), deterministic-time gate (unchanged precede-first-use meaning), cancel fan-out (unchanged).
- Prior art: generations wiring suites (drain triple sums pending while sharing admission, pending sums across generations), snapshot postcondition suites (drain sums counts under one shared limit with unforked virtual time), generations suites (in-flight preservation with aggregated counts and drained release), shared-slot-domain suites, store determinism suites. The hardening must keep every one green with zero test-semantics edits.
- Verification per ticket: `swift build` green plus full `swift test` green; grep proves the old spelling shrinks monotonically (anonymous prune present before, absent after; drain-state reads under the scheduling lock present before, outside after).

## Out of Scope

- Any change to what counts as drained, to priority ordering, retry budget or void-completion policy, waiter preservation or exactly-once delivery, slot limits or release ownership, expiry resolution, or time adapters.
- The getter-purity follow-up (pure reads, reap only at explicit reconfigure/settle points): defined but blocked by T2 pump-coalesce, which must first supply the settle/drain notification and re-prove the monotonic-drain invariant under coalesced pumping.
- Changing the public Lease shape, the Bridge live-view reflection, State creation/observation, registry emission order or lock discipline, or deterministic-time spelling.
- Touching the slot admission primitive itself, Deadline internals, the registry wait implementation, or the activation gate.
- Reopening generations-snapshot, slot-sharing, unified-lifecycle-ownership, or single park-seam decisions: no revisit trigger is met; the hardening extends them, it does not redesign them.
- Reformatting or renames beyond the prune-to-reap consolidation.

## Further Notes

- Dependency: **blocked-by T2 pump-coalesce (follow-up only)**. This spec's tickets do not require T2 and must land without assuming it: they neither redefine drain nor move reap off the read path. The follow-up getter-purity move requires T2 first because only T2 can say when a generation is drain-stable under coalesced pumping and can feed the Store a settle/drain notification so a drained generation releases without a getter triggering the reap. Tickets record this as a sequencing note on the mechanical work and a hard blocked-by edge on the follow-up.
- Self-grill verdict (autonomous self-grill; decided, no questions asked):
  - T5-Q1 Pure reads now versus named pass first? Adopted named pass first. Pure reads now would leave drained generations visible until the next explicit reap, and no settle hook exists to trigger it — the suites pinning generation-count-returns-to-one after natural drain would fail. The named pass preserves semantics today and gives T2 a seam to relocate.
  - T5-Q2 Copy-check-sweep versus keep holding the lock across drain checks? Adopted copy-check-sweep. Holding the outer lock across per-generation scheduler locks is the exact nesting under review; copying first shrinks each critical section and makes the single crossing auditable.
  - T5-Q3 Re-check drain state under the sweep lock or trust the flag? Adopted trust the flag plus presence/current re-check. Re-checking under lock would reintroduce the nesting being removed; the flag is safe because non-current generations drain monotonically (schedule lands only on current, cancel only removes, retry stays in-generation). Recorded as the invariant T2 must re-prove.
  - T5-Q4 Fix the header doc or leave the old claim? Adopted narrow fix naming the reap pass as the single exception. Leaving it keeps documentation false; rewriting the whole discipline overstates the change.
  - T5-Q5 Two tickets or three? Adopted three (extract, pin, verify-plus-handoff) in expand–contract order, so the mechanical extraction lands independently reviewable from the new behavior pins and the T2 handoff is a reviewable artifact.
  - T5-Q6 Sequencing vs T2? Adopted this spec first with drain untouched: it changes spelling and lock-ordering only, so T2 builds on one reap vocabulary instead of an anonymous getter side-effect, and nothing here needs rebasing when T2 redefines drain.
  - Rejected: redefining drained (belongs to T2), moving reap off getters now (no settle hook; breaks generation-count pins), fusing slot admission into the reap (nests lock domains), adding a generations delegate protocol (leverage ~nil).
- Deletion test is the acceptance bar: deleting the old anonymous prune spelling (callers read only the named reap pass) changes nothing observable through the public seam.
- Source of prototype decisions: none — no prototype; decisions derive from the getter/prune inventory, the header-doc contradiction, and the missing settle-hook analysis that forces the T2 sequencing.
