# N1 — Registry snapshot privatize (whole-set wait only)

## Problem Statement

The Registry module currently exposes whole-snapshot observation beside the whole-set wait, so any caller can subscribe to the full dictionary and rebuild readiness out of snapshot plus re-query. That rebuild re-learns emission ordering and drifts the empty-set and already-satisfied fast paths per call site, which the whole-set wait decision rejects. The Store module mirrors the leak one level up with its own snapshot observation entry, widening the interface that every Store reader must learn. Test suites subscribe to the snapshot directly, pinning the leaky seam in place and teaching future authors that snapshot subscription is a supported grain.

## Solution

Narrow the Registry module to two grains: the per-capability pair for UI-style subscribers and the whole-set waiter for the Tasks waiter. Snapshot observation becomes private mechanics inside the Registry, subscribed only by the whole-set wait implementation, which re-queries per emission. The Store module lowers its snapshot entry to private for the same reason and keeps the waiter as the sole whole-set seam. Existing snapshot-subscribing tests migrate to the waiter plus per-capability query and observation, so the public test surface proves the supported grains only.

## User Stories

1. As a UI subscriber, I want one per-capability Boolean publisher, so that I never parse a whole dictionary to render one toggle.
2. As a UI subscriber, I want point-in-time query paired with per-capability observation, so that initial render and live updates agree without learning snapshot mechanics.
3. As a Tasks waiter with an empty required set, I want immediate success without subscribing, so that no waiter pays setup cost for vacuous readiness.
4. As a Tasks waiter with an already-satisfied set, I want immediate success without waiting, so that hot-path scheduling never parks unnecessarily.
5. As a Tasks waiter with multiple required capabilities, I want success only when all are simultaneously available, so that partial availability never launches work early.
6. As a Tasks waiter whose expiry wins, I want a clean negative resolution, so that park, expiry, activation, and settlement stay in Tasks while set-matching stays in the Registry.
7. As a Tasks author, I want whole-set readiness behind one wait interface with an injected expiry race, so that I never name the expiry owner from inside the Registry.
8. As a Store reader, I want a small interface with two grains only, so that learning cost stays flat as scheduling grows behind it.
9. As a Registry maintainer, I want snapshot emission ordering owned in one place, so that per-capability-before-snapshot fixes land once and hold everywhere.
10. As a test author, I want to pin ordering, shortcuts, and multi-capability simultaneity through the public waiter and query seams, so that refactors of private snapshot mechanics never break the suite.
11. As a reviewer, I want no caller able to rebuild the wait from snapshot plus re-query, so that contract review stays local to the waiter.
12. As a future architect, I want the privatization rejection of snapshot-as-public-grain recorded, so that I do not re-propose widening without the drift cost.

## Implementation Decisions

- Module: the Registry remains the deep module behind query, per-capability observation, and the whole-set wait; the Store remains the facade that delegates thinly without owning set-matching.
- Interface: snapshot observation leaves the visible interface of both modules; the whole-set wait becomes the single whole-set seam with set-matching plus empty and already-satisfied shortcuts living once inside the Registry.
- Seam: snapshot mechanics move to an internal seam used only by the wait implementation; the external seam offers per-capability grain for UI-style callers and whole-set grain for the Tasks waiter, with no third grain.
- Depth: shrinking the interface while keeping all readiness behaviour behind the waiter increases depth; callers gain leverage because one waiter method replaces snapshot subscribe plus manual re-query plus local shortcut logic.
- Locality: emission ordering, shortcut semantics, and re-query-per-emission concentrate in the Registry implementation, so ordering fixes land once instead of fanning across call sites.
- Adapter: no new adapter is introduced; the existing expiry-race injection stays the variation point, so the Registry never names the Tasks type that owns expiry.
- Grill (internal, no user quiz): keeping snapshot observation visible but documented as waiter-only rejected — prose does not stop subscription and tests keep pinning the leak; exposing a filtered snapshot variant rejected — it reintroduces a third grain with the same drift; moving set-matching into Tasks rejected — it splits the waiter across the seam and duplicates shortcuts per waiter; fusing per-capability observation into the waiter rejected — it forces UI callers to learn whole-set semantics for single toggles.
- Respects the whole-set wait decision and the Registry, Tasks waiter, and two-grain vocabulary: per-capability observation serves UI-style subscribers and whole-registry observation serves the Tasks waiter only.

## Testing Decisions

- A good test crosses the public interface only and asserts externally observable readiness, never private snapshot emissions or subject identity.
- Modules under test: the Registry wait behaviour through the Store waiter seam plus the per-capability query and observation pair; no direct snapshot subscription.
- Coverage pins: empty set resolves true without subscribing, already-satisfied resolves true without waiting, multi-capability resolves true only on simultaneous availability, expiry win resolves false, per-capability-before-snapshot ordering holds as observed through query and per-capability observation, and reentrant queries from sinks stay safe.
- Prior art: existing Registry wait suites, Store determinism suites, and emission-order pins, migrated from snapshot subscription to waiter plus query forms.

## Out of Scope

- State, Time, Slot, Settlement, park, activation, Deadline, or lifecycle changes.
- New public readiness API beyond narrowing; lock, emission, or concurrency changes.
- Bridge, Sample, or scheduling facade reshaping.
- Glossary reshaping beyond two-grain wording.

## Further Notes

- IndependentDocs-only wave: no production behaviour change beyond visibility narrowing plus test migration; full suite must stay green.
- Deletion test: deleting the whole-set wait would force set-matching plus shortcuts to fan out across waiters, so the waiter earns its keep; deleting snapshot mechanics removes no caller-visible capability.
- Follow-up kept out: a narrower expiry-racer abstraction owned by the Registry stays a possible future and needs no decision here.
