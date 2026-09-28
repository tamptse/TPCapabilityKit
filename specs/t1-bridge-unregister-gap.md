**Status:** verify-only — both entries landed (removeState in 5ee4845, unregister in 87456d2). Do not re-implement; verify pins only.

## Problem Statement

An ObjC consumer can bring a Plugin to life through the Bridge but can never take it down again. The Bridge exposes the birth half of the lifecycle — register a Plugin, write and read its State, subscribe to State, query and observe Capability — with no symmetric death half. The Store facade already owns the full lifecycle: full detach clears State and detaches the Capability row, while State removal alone clears one State subject with detached-subscriber completion. The Bridge exposes neither, so every State value written through the Bridge lives forever: reads keep returning the last value, detached subscribers are never completed, and a re-registration with the same Plugin id inherits stale State instead of starting fresh. The leak is silent precisely because ObjC Plugins are capability-consumers only and never create a Capability row — nothing in capability queries turns red, only State accumulates.

## Solution

Give the Bridge the symmetric death half it is missing: two Plugin-id-keyed detach entries that mirror the existing State read/write entries. One entry removes a single State value; the other performs full Plugin detach (State cleared with detached completion plus Capability-row detach). Both are thin translators that delegate straight to the existing Store detach entries with no policy of their own, preserving the consumer-only contract: ObjC Plugins still declare no Capabilities, still never satisfy capability queries, and still consume Capabilities only through query and scheduling. Empty-id handling stays owned once per domain at the State and registry seams — the Bridge delegates without guarding, so the observable empty-id no-op stays identical to doing nothing.

## User Stories

1. As an ObjC consumer, I want to remove one Plugin's State through the Bridge, so that a discarded screen or session leaves no readable residue.
2. As an ObjC consumer, I want to unregister a Plugin through the Bridge by its id string, so that teardown does not require holding the original plugin object alive.
3. As an ObjC consumer, I want re-registration after detach to start fresh, so that a returning Plugin never inherits a previous incarnation's State.
4. As a State subscriber, I want detach to complete my detached subscription, so that I never hang on a Plugin that is gone.
5. As a State subscriber, I want the next update after detach to reach only new subscribers, so that old and new incarnations never share a subject.
6. As a capability consumer, I want Bridge detach to leave capability queries provably untouched, so that consumer-only teardown cannot fake provision.
7. As a Bridge maintainer, I want both detach entries keyed by Plugin id string like the existing read/write entries, so that callers learn one addressing rule.
8. As a Store maintainer, I want the Bridge to reuse the existing Store detach entries with zero Store signature change, so that the Store facade stays the single lifecycle seam.
9. As a Store maintainer, I want empty-id detach through the Bridge observably identical to no-op, so that per-domain guard ownership cannot diverge.
10. As a test author, I want detach pinned through the public Bridge seam on fresh instances, so that a dropped cleanup step turns red.
11. As a reviewer, I want the consumer-only promise restated once beside the new entries, so that a future Capabilities parameter reads as a contract break.
12. As a future contributor, I want no new lock domain, observation grain, or scheduling path, so that this change reviews as lifecycle symmetry only.

## Implementation Decisions

- **Module**: the Bridge stays the single ObjC adapter; the Store facade stays the single lifecycle seam. No new module or type is introduced and no Store signature changes — the Bridge reuses the existing Store full-detach and State-removal entries.
- **Interface**: two new ObjC-visible entries, both keyed by Plugin id string to match the existing State read/write/subscribe addressing. The State-removal entry mirrors State-removal spelling; the full-detach entry mirrors full-detach spelling. No Capabilities parameter appears on either entry — the consumer-only contract is preserved by construction.
- **Depth**: no depth change. Each entry is one thin translation layer (id string in, Store detach out) with no timeout, descriptor, delivery-queue, or emission policy of its own.
- **Seam**: the highest seam stays the Bridge object delegating to the Store facade. Tests cross that seam only; no internal State helper or registry helper is named from the Bridge or the tests.
- **Adapter**: full detach reuses the existing transient-adapter path (the same adapter construction the register entry already uses) because Store detach reads only the Plugin id — no `start` side effect runs on the detach path, so a fresh adapter carrying the same id is behaviorally identical to the registration-time one. Rejected alternative: adding a new id-keyed detach overload on the Store facade — leverage near nil for a consumer-only row that is always empty, and it would widen the Store's public surface for Bridge convenience against the fewest-seams rule.
- **Locality**: the symmetry rationale (birth half vs death half, State-removal vs full detach, consumer-only untouched) is stated once beside the new entries and referenced, not restated per entry.
- **Empty-id subtlety**: the Bridge adds no id guard; empty ids delegate straight through so the State helper (writes/removals no-op, reads nil, observations immediately completed) and the registry (register/unregister/query no-op) reject once at their owner seams. The pinned contract is the observable no-op, identical to the Store facade's.
- **Ordering constraint**: State-removal lands as the first slice and full detach as the second, so each slice is independently demoable and the full-detach review reads as removal-plus-row-detach.
- **Respects ADRs**: Store-to-submodule lock discipline (no caller holds a Store lock across a submodule call; changes collected under lock, emitted after unlock) is untouched — both entries delegate synchronously like the existing register/update entries. State creation-vs-observation split (writers get-or-create, observation never creates, removal completes detached with fresh subject on next update) and registry mutate-and-notify order are restated as constraints, not reopened. Consumer-only (ObjC Plugins provide no Capabilities) is restated, not relaxed.

## Testing Decisions

- A good test crosses the public Bridge seam on a fresh instance and asserts externally observable behavior (reads, subscriber completion, fresh-subject isolation, capability queries), never adapter identity, internal call order, or lock behavior.
- Modules under test: the two new Bridge entries through the Bridge-to-Store seam; State lifecycle (detached completion, fresh subject on next update) and registry detachment only as observed through the Bridge.
- Pinning tests (Bridge-seam-only, fresh instance per test, rendezvous instead of sleeps):
  - State-removal slice: register via Bridge, update via Bridge, remove via Bridge, then read is nil through the Bridge; a pre-removal subscriber is completed and a post-removal update reaches only new subscribers.
  - Full-detach slice: register via Bridge, update plus subscribe via Bridge, unregister via Bridge by id string, then read is nil, detached subscribers are completed, fresh update reaches only new subscribers, and capability queries plus per-plugin capability rows stay empty as before (consumer-only preserved).
  - Empty-id identical no-op (folded into both slices): detach entries with an empty id leave reads, queries, per-Capability observations, and whole-snapshot observations identical to before — no new values, no snapshot delta, State observation completes immediately.
- Prior art: Bridge single-view suites (fresh-instance Bridge pins with continuation rendezvous), facade register/unregister round-trip test, detached-completion removal test, guard-ownership suites (owner seams reject empty ids), observation-narrowing suite (identical no-op plus notice-before-snapshot order).
- Verification: full suite green with no test-semantics edits to existing suites; each new pin fails under its matching deletion (drop the Store delegation line, or swap detach for no-op) before being kept green.

## Out of Scope

- Any change to Store signatures, State creation/observation/removal semantics, registry emission order, whole-set readiness, generation draining, slot admission, Deadline/expiry, settlement, Lease lifecycle, or scheduling/timeout/delivery policy.
- Capability provision for ObjC Plugins (new Capabilities parameter, provider adapter, reverse-index writes from the Bridge).
- Object-identity detach (taking the plugin object instead of the id string), bulk detach, or automatic lifetime tracking.
- Sample changes, renames, formatting churn, or prototype code.

## Further Notes

- Grill record (autonomous self-grill, no user round-trips per task instructions — user instructions take precedence over interactive grilling):
  - Q: Why id-keyed detach instead of object-keyed? A: All existing Bridge State entries address by id string; the teardown object is often already deallocated at detach time, while the id string survives. Id-keying is also the only spelling that mirrors read/write addressing with one rule.
  - Q: Why two entries instead of unregister alone? A: The Store already documents the split (State-removal is partial, full detach is State plus row-detach); collapsing them would hide the partial step ObjC consumers need for session reset without full teardown, and would break symmetry with the Store seam the Bridge mirrors.
  - Q: Why no Store change? A: Store full detach reads only the Plugin id, so the Bridge's existing transient adapter already satisfies it with zero new public surface; an id-keyed Store overload adds a seam for an always-empty consumer row.
  - Q: Why is the consumer-only pin load-bearing if the row is always empty? A: Exactly because it is always empty today — without the pin a future Capabilities parameter would land silently; the pin turns that relaxation red.
  - Q: Where does the deletion test bite? A: Dropping either Store delegation line leaves State readable and subscribers uncompleted after the matching Bridge entry — the corresponding slice pin turns red.
  - Rejected: facade-level empty-id guard on the Bridge (would duplicate owner guards and violate safe-by-construction); caching the registration-time adapter for later detach (adds identity state to a stateless view for zero behavioral difference); rebuilding detach out of remove-plus-manual-registry calls from the Bridge (relearns emission ordering across modules instead of reusing the Store seam).
- Dependency: none. No Store split, timeout, or scheduling companion gates this change; it lands independently on the current Bridge-to-Store seam.
- Source of prototype decisions: none — no prototype; decisions derive from the current Bridge/Store seam inventory and the domain glossary Plugin/Store/State/Capability/Bridge sections.
