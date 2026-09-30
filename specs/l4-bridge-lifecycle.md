# L4 — Bridge detach symmetry + Sample teardown

## Problem Statement
Bridge register builds a local `PluginObjcAdapter` then drops it (Store is id-keyed, no retain); detach builds a second `BridgeDetachAdapter` just to carry the id. Two id-carrier adapters duplicate meaning. Sample leaves `SampleObjcPlugin` registered on shared singleton with stale "no unregister seam" comment.

## Solution
Keep id-keyed Store contract (no Store change). Delete `BridgeDetachAdapter` reuse: detach reuses a lightweight id-carrier owned by the Bridge door (single adapter type). Fix Sample to `register → demo → unregister + removeState`, delete stale leak comment, assert `getState == nil` after detach.

## User Stories
1. As an ObjC author, I want register/unregister symmetric by id, so that lifecycle is learn-once.
2. As a test author, I want Sample to clean shared state, so that no cross-test contamination.
3. As a maintainer, I want one id-carrier adapter, so that duplicate start-noop classes vanish.

## Implementation Decisions
- Module: Bridge door remains single scheduling adapter (ADR-0003, ADR-0016); detach adapter is door-private mechanics.
- Interface: no public Bridge change (`register/unregister/removeState` shapes stay). Internal: `makeDetachAdapter` returns shared lightweight carrier; delete duplicate class if trivial, else fuse.
- Sample: injected store where possible, `.shared` only in `runExample`; teardown per `run*Example`; drop RunLoop fragility only if trivial (else keep, note).
- Grill (auto): do NOT add retained `[String: Adapter]` map — Store explicitly does not retain plugins by design; retained map would create new ownership/leak semantics and contradict detach-by-id. Symmetry via shared carrier, not retain.
- Respect ADR-0003/0016 (single scheduling adapter).

## Testing Decisions
- External: register→query→unregister→query false; removeState→getState nil; Sample teardown asserts. Prior art: bridge unregister/removeState pins (t1).
- Full suite green; sample target still builds.

## Out of Scope
- Fire entries, State boxing, registry wait, scheduler internals.

## Further Notes
- Independent of L1/L2; touches same Sample file as L5 — land L4 before L5 or fuse sample edits.
