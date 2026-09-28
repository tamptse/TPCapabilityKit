# R1 — StoreState late-subscriber rendezvous locality

## Problem

`StoreState` (`Sources/TPCapabilityKit/DynamicStore.swift:278-379`) implements one
domain fact — late-subscriber rendezvous (observe-before-create meets the first
write losslessly) — scattered across 4 hops: `creationSequence` + `creationClock`
state (:281-282), 3-case `CreationRendezvous` enum (:284-288) +
`creationRendezvous(pluginId:createIfMissing:)` (:290-303), `awaitCreation`
4-op Combine chain (:305-315), and two callers `update` (:317-328) /
`observe` Deferred chain (:357-378) with different shapes. A reviewer answering
"why can't a late subscriber miss its subject?" must hold the ordering
(`creationClock.send` before `subject.send` in the `.created` arm), the
`filter { $0 > after }` replay guard, and the `Deferred` re-entry reason
together — none stated at one site. Helpers are pure-ish but bugs hide in
callers; the module reads shallow.

## Seam / Interface

- Public seam unchanged: `DynamicStore.updateState/getState/removeState/
  observeState` keep exact signatures; `StoreState.update/get/remove/observe`
  owner shape unchanged.
- No new module, no file split, no new public API. Deepen `StoreState` only:
  state the rendezvous once beside `observe`/`update`; fold the 3-case enum +
  4-op chain into private mechanics of a single transition
  (lookup-or-await-creation). Typed filtering (`compactMap { $0 as? T }`) stays
  at the observation edge, outside the rendezvous.
- Lock discipline unchanged: locked section covers only index/counter
  read-or-insert; both publishes (`creationClock`, subject value) emit after
  unlock; no caller holds a Store lock across a submodule call.

## Behavior postconditions (all through facade, identical to today)

1. Writers get-or-create: `update` creates the per-id subject if absent, wakes
   pending observers, delivers the value.
2. Observe-never-creates: `observe` before any write pends without creating
   visible state (`getState` stays nil).
3. Lossless wakeup: every pending observer at write time receives the write;
   `creationClock.send(notice)` precedes `subject.send(newState)` so no
   `filter`-gated waiter can sleep through its subject.
4. Isolation: a creation notice for id A never resolves a waiter on id B
   (per-notice index re-check, first-hit then switch-to-subject).
5. Remove-completes-detached: `remove` deletes the index entry and completes
   the detached subject; next `update` creates a fresh subject for new
   subscribers; stale subjects are never resurrected.
6. Empty-id fails closed: writes/removals no-op, reads nil, observations
   complete immediately.
7. Type mismatch delivers nothing and creates nothing.

## Non-goals

- No semantic change to lifecycle, typed filtering, empty-id rejection,
  generation prune, slot admission, park/Deadline/activate/settle, registry
  emission order, whole-set readiness, Bridge mapping/timeout.
- No versioned-notice payload (targeted wakeup carrying plugin identity):
  deferred until measured fan-out pressure; this refactor keeps the one
  caller-pair the redesign would touch.
- No file split, no scheduler protocol, no new lock domain, no new observation
  granularity, no glossary/ADR edits, no reformatting beyond the locality move.

## Test plan (public facade seam only)

- Good test = facade-level subscribe/write/remove asserting observable values
  and completion; never asserts helper existence, counter values, clock
  topology, or enum cases.
- Must-stay-green with zero edits: `TPCapabilityKitStateLifecycleTests`
  (incl. `concurrentObserversBeforeWriteRendezvous`),
  `TPCapabilityKitStateWaiterIsolationTests`,
  `TPCapabilityKitObservationNarrowingTests` (empty-id arm).
- New coverage (ticket-02): ordering postcondition — N facade observers attach
  before any write, single write follows, all receive it AND `getState` reads
  the write AND an unrelated-id waiter stays pending; plus no-create invariant
  re-asserted. Same facade-only style as prior art; no reference to
  `StoreState`/helper/enum/clock.
- Commands: `swift build`, `swift test`; grep confirms no test references the
  private rendezvous mechanics directly.

## ADR / conflict notes

- Respects `CONTEXT.md` Store (facade + owner seams, lock ownership) and State
  (writers get-or-create, observe-never-creates, remove-completes-detached +
  fresh subject); uses glossary vocabulary (`creation notice`, not `snapshot`).
- ADR-0015 (explicit State lifecycle), ADR-0022 (Store→Tasks lock order),
  ADR-0014 (registry ordered emission) constrain; none amended.
- C1 / ADR-0025 / ADR-0026: file split stays PARKED — this candidate is
  colocation-preserving by construction; under a triggered C1 cut the
  deepened rendezvous travels with the State split file.
- Relation to `specs/c2-state-rendezvous.md`: compatible refinement, not a
  fork — C2 names the lookup-or-await seam; R1 deepens it in place (single
  transition + load-bearing ordering comment) with zero topology change.

## Rollout order

1. Ticket-01: locality refactor + ordering comment (zero test edits, suites green).
2. Ticket-02: ordering postcondition test via facade (new test green + full green).
3. Ticket-03: full verify (`swift build` + `swift test` + grep for seam leaks).

## Further notes (grill-with-docs, autonomous self-grill; decided, no questions asked)

- R1-Q1 Is no-create negotiable? No — load-bearing per glossary + ADR-0015 +
  `observationAloneNeverCreates`. Preserve exactly. Adopted.
- R1-Q2 Hidden depth or real feature? One fact (per-id creation) as two
  mechanisms (global counter+broadcast + per-id index, no named seam);
  capture-filter-relookup-first-switch is the symptom. Adopted: name it once.
- R1-Q3 Extraction (C2) vs deepen-in-place (R1)? Deepen in place: fold enum +
  chain into one transition's mechanics beside observe/update; smaller diff,
  one review surface, split-travels-with-State preserved. Adopted.
- R1-Q4 Ordering comment load-bearing? Yes — `creationClock.send` before
  `subject.send` + `filter > after` is the lossless proof; state it once at
  the transition. Strong angle, adopted into ticket-01 acceptance.
- R1-Q5 `Deferred` needed? Yes — re-entry re-runs lookup so a
  subscribe-racing-create lands on `.existing` instead of parking on a stale
  generation. Keep + comment. Adopted.
- R1-Q6 Removal notice? No — removal completes detached + deletes index; the
  per-notice re-check already prevents resurrection; a removal notice would
  wake sleepers for no possible match. Adopted.
- R1-Q7 Term collision (`snapshot`, Tasks rendezvous)? Use `creation notice`
  and always qualify `State creation rendezvous` vs `Tasks result rendezvous`.
  Adopted.
- Verdict: Worth — converts 4-hop coupling into one review surface at near-zero
  risk; ordering test closes the only lifecycle concurrency gap.
