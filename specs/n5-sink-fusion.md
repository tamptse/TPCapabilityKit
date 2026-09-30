# N5 — Bridge sink lifetime fusion into the door

## Problem Statement

Both Bridge subscribe entries repeat the same lifetime tail: erase the publisher, attach a value sink, and box the resulting token in a cancellable. Boxing plus queue hop already live in the door behind a delivery adapter, but lifetime still lives outside it. A reader fixing a subscription leak must inspect two call sites; the given-or-main delivery contract is stated once yet re-enacted per subscribe grain. The Bridge view stays shallow — nearly as much interface to learn as implementation behind it — while the door holds depth that callers cannot reach.

## Solution

Deepen the door with a lifetime-owning factory: two narrow factory members, one per subscribe grain, that build the boxed sink, attach it, and return the lifetime token directly. The Bridge entries become thin translators that forward observer plus queue and return the token untouched. After the change the Bridge interface is unchanged for callers, but all sink construction, delivery hop, and lifetime ownership concentrate behind one seam with locality for maintainers and leverage for every subscribe site.

## User Stories

1. As an ObjC caller, I want state subscribe to keep its current signature and delivery, so that no call site migrates.
2. As an ObjC caller, I want capability subscribe to keep its current signature and delivery, so that no call site migrates.
3. As an ObjC caller, I want completions to keep arriving on the given queue or the main queue when omitted, so that I never learn per-site delivery rules.
4. As a Bridge reader, I want both subscribe entries to read as forwards, so that lifetime fixes obviously belong in the door.
5. As a door maintainer, I want sink boxing, queue hop, publisher attachment, and token ownership in one module, so that a leak or hop fix lands once.
6. As a door maintainer, I want one factory per grain over a shared sink core, so that state versus capability subscribes cannot diverge.
7. As a reviewer, I want the deletion test to pass — deleting the door factory redistributes lifetime duplication across Bridge entries — so that the factory earns its keep.
8. As a test author, I want existing delivery and single-view suites to prove the fusion, so that no new seam needs mocking.
9. As a future architect, I want the Bridge to stay the single scheduling adapter view with thin translators, so that no second scheduling path appears behind subscribe.
10. As a future architect, I want the capability-spelling versus descriptor-spelling funnel and the detach shape untouched, so that this fusion introduces no scheduling or detach drift.

## Implementation Decisions

- Module: the door stays the single scheduling door behind the Bridge live view. Its inner delivery adapter stays the single owner of queue policy plus sendable boxing; the new factory adds lifetime ownership beside boxing, not as a standalone module.
- Interface: Bridge public subscribe signatures unchanged. The door gains two narrow factory members, one per grain, each returning the lifetime token directly. The shared generic sink core stays private; no new public seam for callers to learn.
- Seam: highest seam preferred. Callers and tests keep crossing the Bridge public seam; construction plus hop plus lifetime cross the door seam. The publisher-attachment detail moves inward without widening any external interface.
- Adapter: delivery adapter role unchanged — queue policy plus boxing — extended only to own the token it already indirectly creates. No new adapter type; the door orchestrates through the same adapter.
- Depth and leverage: the Bridge entries become thinner while the door becomes deeper — more behavior per factory method learned. One factory implementation pays back across both subscribe sites and every future subscriber, which is leverage; fixes concentrate in the door, which is locality.
- Locality: given-or-main hop, boxing-once-then-hop-per-value, and now attach-plus-token ownership each live in exactly one place. Timeout fork stays in the mapper module; wait core versus hop split stays as is; detach stays identifier-only.
- Grill outcome (autonomous self-grill, best practice decided internally):
  - Q: Factory returns token directly versus returns sink for Bridge to attach? A: Returns token. Returning a sink keeps lifetime outside and preserves the duplication this change removes.
  - Q: One factory per grain versus one generic factory? A: One per grain over a shared core. The public grains differ in value type and ObjC adjacency, so two narrow members preserve signatures while the private core prevents divergence.
  - Q: Merge lifetime into the delivery adapter versus keep factory on the door? A: Keep factory on the door with the adapter underneath. The adapter owns hop plus boxing without Store knowledge; attachment needs observation, which belongs at door level.
  - Q: Fold into the in-flight door ticket versus sequence after it? A: Sequence after. The same door region is under active reshaping, so this fusion lands on a stable door to avoid conflicting edits.
- ADRs respected: Bridge exposes exactly one scheduling adapter through the live view; Bridge view plus descriptor paths stay thin translators; mapping, consumer-only plugin shape, and sendable boxing stay co-located with their users.
- CONTEXT terms unchanged: Bridge keeps its single-scheduling-adapter glossary meaning; State keeps creation-versus-subscription separation with detached completion; Capability keeps per-grain observation for UI-style subscribers.

## Testing Decisions

- What makes a good test here: external delivery behavior through the Bridge seam — boxed observer invoked per value on the given queue or main, cancellation tears down delivery — not assertions on factory internals or publisher plumbing.
- Modules under test: Bridge subscribe entries via the door factory seam.
- Prior art: delivery-unify suites and single-view suites must stay green; they already pin given-or-main routing and thin-translator behavior.
- Constraint: full suite green; no test file touched; no observable delivery or lifetime change except location of ownership.

## Out of Scope

- Delivery queue changes, boxing semantics changes, descriptor translation changes, wait core changes, detach adapter changes.
- Timeout fork or pin-literal changes, sync versus wait agreement changes, new ObjC APIs, Core scheduling or registry or state prod changes.
- Removing or widening the Bridge public seam; introducing a new public seam.

## Further Notes

- Blocked by the in-flight door reshaping tickets n2-01 and n2-02 touching the same door region; this fusion starts only once that region is stable, then proceeds as its own two-ticket chain.
- Assumptions: strict concurrency; token type keeps its cancel-on-deinit contract, so moving construction inward changes no lifetime semantics.
- Risk: same-region edit collision if the door reshaping is still green-but-unlanded — mitigated by the explicit block plus a rebase check at factory-ticket start.
- No new ADR; no glossary change.
