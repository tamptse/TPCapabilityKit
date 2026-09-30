# N4 — Legacy fire alias removal

## Problem Statement

Callers choosing how to fire work face three public spellings where two suffice. The legacy async immediate spelling looks like a waiter but behaves like the sync check: it verifies availability through the sync core and then runs the caller's closure directly, bypassing the Lease lifecycle, slot admission, and the expiry race exactly the way sync check-and-run does by contract. Under slot pressure this lie matters: sync fire still runs while a scheduled wait parks, so a reader of the legacy spelling cannot predict whether their work queued or jumped the queue. The fire module stays shallow — one extra spelling taxes every future reader — and the bypass contract must defend itself against a third interpretation.

## Solution

Remove the legacy async immediate alias entirely and migrate its remaining callers to the two documented entries: sync check-and-run for point-in-time execution, schedule-and-wait (plus its single-capability convenience) for queued waiting. The bypass contract keeps living stated once beside the internal fire core; both entries and the Bridge scheduling door keep pointing at it instead of restating it. After this change the shape of the call decides the path and no spelling can be mistaken for a waiter while bypassing it.

## User Stories

1. As an author needing immediate execution, I want sync check-and-run returning a value or nil, so that I get a point-in-time answer with no parking.
2. As an author needing to wait for readiness, I want the async schedule-and-wait entry, so that my work parks through the one waiter until ready or expired.
3. As an author with a single required skill, I want the single-capability convenience over the waiter, so that I never hand-build a descriptor for the common case.
4. As an author with full scheduling needs, I want the descriptor entry over the same waiter, so that priority, timeout, retries, and metadata travel together.
5. As a consumer under slot pressure, I want sync to run while waits park, so that urgent checks are never starved by a full queue.
6. As a legacy alias caller, I want a mechanical migration to one of the two entries, so that my behavior is preserved with no ambiguity about queuing.
7. As a sample reader, I want every demo to use only the two entries, so that I never copy a deprecated spelling into new code.
8. As a docs reader, I want usage guidance to show only the two entries, so that I choose correctly on the first read.
9. As a Bridge consumer, I want the Bridge scheduling door unchanged, so that no ObjC-side migration is needed for this cleanup.
10. As a maintainer, I want exactly two fire spellings plus one convenience, so that new spellings must justify themselves as conveniences rather than new executors.
11. As a reviewer, I want the bypass-vs-waiter rule readable in one place, so that future edits cannot split it into drifting copies.
12. As a test author, I want agreement pinned through the public spellings, so that the removed alias needs no test and migrated callers pin identical outcomes.
13. As a future architect, I want the removal recorded as intentional, so that nobody reintroduces a third executor under a new name.

## Implementation Decisions

- Module: the fire module loses its third public spelling; the sample module and usage docs are re-pointed as adapters over the two surviving entries. No scheduler, registry, or State module changes.
- Interface: exactly two stable entries remain — sync check-and-run plus async schedule-and-wait — with the single-capability convenience thin over the waiter. The legacy async immediate spelling disappears with no replacement signature.
- Seam: work at the highest seam, the public fire entries. No new seam is introduced; the internal fire core (sync query-plus-invoke vs descriptor waiter funnel) is consumed as-is and its once-stated bypass contract is untouched.
- Adapter: sample demos and usage docs are thin adapters — they change which entry they call, never scheduling semantics. Migration rule: point-in-time execution maps to sync check-and-run; anything that waited maps to the waiter or its convenience.
- Depth: deletion deepens the fire module by removing a shallow third spelling; the interface now admits no combination its implementation rejects.
- Leverage: leverages the existing waiter seam and the existing agreement coverage rather than building new machinery; the cleanup rides the green suites that already pin sync-vs-wait divergence.
- Locality: all bypass-vs-waiter knowledge stays beside the internal core; entries and the Bridge door keep pointing at it, so the rule has exactly one home.
- Grill (self-grilled, no user input per task constraints): delete-vs-keep-deprecated decided as delete, because every remaining caller is migratable and the alias actively misleads under slot pressure; keep-as-thin-alias rejected since the compat window has closed. Bridge forwarders left untouched — separate door, separate breaking-change window. Expand-then-contract ordering decided: migrate callers first while the alias still exists, then remove the alias, so the suite stays green batch to batch.
- Respect: the K8 two-entries collapse and the Task/TaskDescriptor/Lease vocabulary — sync never mints a Lease, never touches slot admission, never builds an expiry race; queued work always funnels through the single Tasks path.

## Testing Decisions

- What makes a good test here: pin the seam, not the internals — assert through the public fire spellings that sync returns value-or-nil, queued waits resolve-or-expire, and slot-pressure divergence holds (sync runs while the waiter parks).
- Modules under test: fire agreement plus the sync seam. Prior art: the two-entry agreement suite with its slot-pressure divergence case, plus scheduler integration coverage for the shared waiter.
- Migrated callers pin identical observable outcomes as before migration; the removed alias gets no test because there is no spelling left to assert.
- Constraint: full suite green before and after each step; no observable behavior change for migrated callers.

## Out of Scope

- Scheduler internals (priority queues, matching, timeout, retry, slot mechanics, generations) and the single Tasks path.
- Registry and State regions, capability or descriptor shape changes, and Bridge mapping work.
- Bridge forwarders and the Bridge scheduling door beyond re-pointed references.
- New timeout, retry, or scheduling semantics, and any new public fire API.
- Renaming either surviving entry or changing any surviving signature.

## Further Notes

- Final consolidation step after the two-entry collapse: stating bypass once beside the core guards future sprawl — any new spelling must arrive as a convenience, never as a new executor.
- Independent of the lease-mapping cleanup; neither blocks the other. Sequencing inside this spec is expand (migrate callers) then contract (remove alias).
- Assumption: remaining legacy callers are the sample demos, usage docs, and tests — all migratable to the two entries with no behavior change. Deletion is a source break only for legacy-spelling callers, mitigated by the prior deprecation window and the mechanical migration rule above.
