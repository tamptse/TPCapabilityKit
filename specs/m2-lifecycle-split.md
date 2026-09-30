# M2 — Lifecycle ordering split (OrderIndex extract)

## Problem Statement

The lifecycle table module holds three jobs at once: priority ordering, incremental counting with a snapshot, and row placement with five outcome vocabularies. Ordering policy cannot be read or tested without importing the whole table; the ordering invariant is only asserted inside the parent.

## Solution

Extract ordering mechanics into its own file-module as an internal detail of the lifecycle table, verbatim semantics: per-priority queues, FIFO within priority, dequeue-with-skip, remove-on-take. Keep rows, placement, counts snapshot, transitions, and all outcome vocabularies in the table module. Document that the counts snapshot refines the earlier derive-instead-of-store decision.

## User Stories

1. As a scheduler author, I want priority policy in one readable unit, so that FIFO-with-skip changes land once.
2. As a maintainer, I want the ordering invariant stated next to the table that enforces it, so that split truth cannot drift.
3. As a test author, I want ordering covered through the public schedule seam, so that mechanical moves do not force test rewrites.
4. As a reviewer, I want counts derivation to have one documented source, so that incremental vs recomputed confusion vanishes.

## Implementation Decisions

- Module: ordering becomes a sibling file-module, still an internal detail of the lifecycle table, used only by the table; no new public seam.
- Interface: ordering keeps enqueue/dequeue/remove-by-id plus identifier listing; table keeps rows, placement, counts snapshot, transitions, park, execution, and live-row reads.
- Dequeue semantics unchanged: priority descending, FIFO within priority, terminal removal auto-cleans ordering.
- Counts keep single-writer snapshot; recomputed counts stay debug-only assertion, stripped in release.
- Invariant (place plus order plus counts agree) stays in the table and is called from insert, transition, take, and dequeue paths.
- No new lock: every ordering operation stays under the scheduler lock; no ordering-private lock.
- Grill (auto): sibling callable queue rejected (splits truth, regresses single-table ADR); sort-on-read rejected (per-dequeue cost plus FIFO break); moving rows/outcomes out rejected (creates thought import cycle); always-computed counts rejected (hot-path cost on pending reads).

## Testing Decisions

- External behavior only: priority order, FIFO within priority, terminal cleanup, snapshot counts.
- Modules: lifecycle table seam plus public schedule seam.
- Prior art: priority validity tests, lifecycle table tests, ordering postcondition tests, snapshot postcondition tests, same-id pins.
- Full suite green; mechanical move must show only move in diff.

## Out of Scope

- Outcome-type unification (belongs to M3); eviction handoff moves (belongs to M4); settlement retry changes; slot admission changes; public seam changes.

## Further Notes

- Independent of M1/M5/M6/M7; blocks M3 which needs a stable exchange shape, then M4. Respects single-source-of-truth queue, lifecycle-ownership, order-index-internal, and lock-order ADRs.
