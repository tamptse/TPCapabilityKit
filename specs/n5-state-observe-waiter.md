## Problem Statement

State creation rendezvous is spelled twice inside the Store's State helper: an outer `CreationRendezvous` (existing/created/pending) wraps an inner `Decision` (existing/created/pending) that exists only to split the locked lookup from the unlocked Combine assembly, while the pending branch inlines a clock-filter plus weak-self re-read plus compactMap-plus-first chain at the call site. A reviewer asking "how does an observer that arrives before the first write get its subject?" must hop two enums plus an inline publisher chain to assemble one answer, and each hop is a drift risk: the inner cases duplicating the outer cases invite a future fourth case on one side only, the inline chain invites a second copy-paste waiter with a subtly different filter, and the writer's impossible `pending` arm reads as reachable instead of contractually dead.

## Solution

Collapse the two enums into a single-lock `CreationRendezvous` and extract the pending waiter into one named helper (`awaitCreation`-style) that the observation path calls. Writers keep get-or-create, observation alone never creates, removal still completes detached subscribers with the next update minting a fresh subject, and the `Deferred` plus `switchToLatest` topology, lock discipline, removal/completion behavior, and empty-id rejection stay exactly as they are. The writer's impossible arm remains explicit as an assertion rather than a silent no-op. No behavior change: creation sequence, clock notice emission order, and subscription lifecycle are identical before and after.

## User Stories

1. As a State maintainer, I want one rendezvous type instead of two, so that existing/created/pending reviews in a single hop.
2. As an observer arriving before the first write, I want to park on one named waiter, so that my subscription resolves when the writer's clock notice fires without a copy-pasted chain.
3. As a writer, I want get-or-create to stay atomic under the single lock, so that concurrent first writes mint exactly one subject.
4. As a removal caller, I want removal to keep completing detached subscribers, so that stale observers never stall silently and the next update mints a fresh subject.
5. As a subscriber, I want observation alone to never create, so that subscription lifecycle stays explicit per the State glossary.
6. As a reviewer, I want the locked-lookup vs unlocked-assembly split visible in one function, so that no lock is held across publisher assembly.
7. As a future contributor, I want the pending waiter extracted once, so that no second inline filter chain can drift out of sync.
8. As a test author, I want waiter behavior asserted through the public update/observe/remove seam, so that the collapse is proven by lifecycle behavior not by enum spelling.
9. As an empty-id caller, I want writes/removals to stay no-ops with reads returning `nil` and observations completing immediately, so that invalid usage stays safe and observable.
10. As a registry reviewer, I want State lock discipline untouched, so that the Store→Tasks order and mutate-and-notify contracts are unaffected.
11. As a Combine reader, I want the `Deferred` plus `switchToLatest` topology preserved verbatim, so that per-subscription laziness and waiter-to-subject switching behave identically.
12. As a debugger, I want the writer's impossible `pending` arm kept as an explicit assertion, so that a contract violation fails loudly instead of hiding as a silent return.
13. As an ADR reader, I want the change traceable to explicit State lifecycle and ordered emission, so that the collapse clearly respects prior decisions rather than reopening them.

## Implementation Decisions

- **Module**: State helper remains the single State module behind the Store seam (update/get/remove/observe); the Store facade keeps thin delegation without guarding since empty-id rejection lives at the owner seam. No new module is introduced; the waiter helper is a private function of the same module.
- **Interface**: the public Store seam is unchanged (register/update/get/observe state; observation typed via generics; removal-completes-detached; next-update-mints-fresh). The internal change is type collapse (inner `Decision` deleted into the single `CreationRendezvous`) plus waiter extraction (pending branch calls one named helper instead of inlining the chain).
- **Depth**: depth decreases by one type with zero new abstraction. The locked lookup (existing vs create vs record-sequence) plus unlocked assembly (existing/created direct, pending via helper) stay the same two phases; they now read as one function with two clearly separated regions instead of two enums.
- **Seam**: the highest seam stays the Store facade update/observe/remove. Tests cross that seam; no new seam is created. The creation-clock notice (sequence increment under lock, emit after unlock, waiter filters for greater-than-recorded) remains the only cross-phase coordination, unchanged.
- **Adapter**: no adapter change. The Bridge and Tasks cross only the Store facade; deterministic-time spelling and registry wait seams are untouched.
- **Locality**: the sequence increment, clock emit, waiter filter predicate, weak-self re-read under lock, and compactMap-plus-first termination sit adjacent in one helper beside the single rendezvous, so the full before-first-write path reads without hopping between an outer enum, an inner enum, and an inline chain.
- **Leverage**: leverage is waiter locality plus duplication removal: one filter predicate to audit, one re-read to verify lock-safe, zero inline copies to sync. Risk is bounded because the helper is behavior-identical (same operators, same order, same lock boundaries); only the address changes.
- **Respects ADRs**: ADR-0015 (writers get-or-create, observation never creates, removal completes detached instead of stalling, generations preserved) forbids any lifecycle-semantics change — the collapse is spelling-only; ADR-0014 (registry owns its lock with per-Capability notices before whole-snapshot publish; no Store lock held across a registry call) constrains lock discipline to stay as-is; ADR-0022 (global Store→Tasks order; changes collected under lock and emitted after unlock) requires the sequence/emit split and the unlocked waiter assembly to remain exactly ordered.

## Testing Decisions

- A good test crosses the public Store seam and asserts externally observable lifecycle (writer get-or-create round-trip; observe-before-write resolves on first update; observe-never-creates proven by no subject side effect; remove completes detached and next update mints fresh for new subscribers; concurrent first writes converge on one subject; empty-id writes no-op / reads `nil` / observations complete immediately), never the spelling of the rendezvous or the name of the helper — except one mechanical grep proving no inner `Decision` remains.
- Modules under test: State lifecycle (creation rendezvous, pending waiter, removal completion, empty-id rejection). Prior art: state-lifecycle suites around get-or-create, observe-never-creates, remove-completes-detached, and fresh-subject-after-remove; the collapse must keep every one green with zero test-semantics edits.
- Isolation proof: a waiter-isolation check (observer parked before first write resolves only on that plugin id's creation notice, not on unrelated ids; multiple parked observers on the same id all resolve; removal before creation notice leaves parkers completing rather than hanging) run through the facade seam.

## Out of Scope

- Any change to State lifecycle semantics (get-or-create, observe-never-creates, remove-completes-detached, fresh-subject-after-remove, empty-id rejection, typed observation, `Deferred`/`switchToLatest` topology, lock boundaries, notice ordering).
- Touching the capability registry (lock, emission order, per-Capability vs whole-snapshot grains, whole-set wait), scheduling generations, slot admission, Deadline/expiry, time adapters, or Bridge mapping.
- Introducing a scheduler protocol, new public API, caching/snapshotting, or new lock domain.
- Renames beyond the collapse or formatting churn.

## Further Notes

- The writer's impossible `pending` arm stays an `assertionFailure` (not a silent return, not a fatal): it documents the contract that writers always pass create-if-missing, so a future caller passing the wrong flag fails loudly in debug while staying non-crashing in production.
- If the helper name is contested during implementation, prefer a waiter-named spelling (`awaitCreation` or equivalent) over a publisher-named one, because the helper's contract is rendezvous (resolve when the creation notice for this id fires), not generic Combine assembly.
- Source of prototype decisions: none — no prototype; decisions derive from the two-enum plus inline-chain inventory and ADR-0015/0014/0022.
