# N2 — Detach by identifier (id-keyed unregister seam)

## Problem Statement

Detaching a plugin today requires a full plugin value even though detach reads only the identifier. The Bridge therefore mints a fake plugin adapter with a no-op start just to carry the identifier across the seam, plus a factory that builds that fake on every detach call. Readers must learn a whole plugin shape to perform an identifier-keyed teardown, and reviewers must verify that the fake never provisions capabilities or runs start side effects. Two identifier-carrier adapters already exist in the Bridge lineage, duplicating one meaning.

## Solution

Offer an identifier-keyed detach entry on the Store module that clears state and detaches the capability row by identifier string. Keep the existing plugin-shaped detach as a thin forwarder that extracts the identifier and delegates, so current Swift callers see no behaviour change. The Bridge door calls the identifier entry directly with the string it already holds, and the fake detach adapter plus its factory disappear. Empty-identifier handling stays owned per domain as today, so the observable no-op contract does not move.

## User Stories

1. As an Objective-C author, I want register and unregister symmetric by identifier, so that lifecycle is learn-once.
2. As a Swift author passing a plugin value, I want detach to keep working unchanged, so that no call-site churn is forced on me.
3. As a Swift author holding only an identifier, I want to detach without fabricating a plugin, so that teardown needs no fake start implementation.
4. As a Bridge author, I want to pass the identifier string straight through, so that no adapter class exists only to satisfy a parameter type.
5. As a reviewer, I want detach to provably never provision capabilities, so that I never audit a fake start body again.
6. As a reviewer, I want state clearing with detached-subscriber completion plus capability-row detach readable as one path, so that Store and State detachment review stays local.
7. As a Store reader, I want a deeper detach interface with fewer shapes to learn, so that leverage rises while the surface shrinks.
8. As a Registry maintainer, I want capability detach keyed by identifier behind the existing owner seam, so that empty-identifier guards stay where they already live.
9. As a State maintainer, I want state removal keyed by identifier with fresh-subject postconditions untouched, so that detach semantics do not drift per caller.
10. As a test author, I want register then detach then query to read as identifier in and clean state out, so that lifecycle tests pin behaviour without adapter scaffolding.
11. As a future architect, I want the rejection of retained adapter maps recorded, so that I do not re-propose ownership tracking that contradicts detach-by-identifier.
12. As a future architect, I want the forwarder direction recorded, so that I do not invert it and push teardown policy into the Bridge.

## Implementation Decisions

- Module: the Store stays the deep module behind registration and detachment; the Bridge door stays the single scheduling and lifecycle adapter behind the Objective-C view, with no new module introduced.
- Interface: the identifier-keyed detach becomes the canonical seam; the plugin-shaped detach stays as a thin forwarder that extracts the identifier and delegates, preserving the existing shape while removing its policy content.
- Seam: the seam moves from plugin-shaped to identifier-shaped at the Store boundary, matching the already identifier-keyed read, write, subscribe, and remove entries; the Bridge crosses that seam with the string it already holds.
- Adapter: the fake detach adapter role disappears entirely rather than being fused or shared, because one real identifier parameter replaces the whole adapter slot; no adapter remains whose only job is carrying a string.
- Depth: one identifier parameter behind which state clearing plus capability-row detach plus empty-identifier no-op semantics hide gives more leverage than a plugin parameter that exposes start and capabilities surface for no benefit on this path.
- Locality: teardown knowledge concentrates in the Store implementation, so Bridge callers cannot drift empty-identifier handling or fake provisioning semantics per site.
- Grill (internal, no user quiz): sharing one lightweight carrier adapter across register and detach rejected — it keeps a fake type alive to satisfy a parameter that should be a string; retaining adapters in a map rejected — the Store explicitly does not retain plugins, and a map would invent ownership and leak semantics contradicting detach-by-identifier; moving empty-identifier guards into the facade rejected — ownership stays per domain so new entries are safe by construction; deleting the plugin-shaped entry outright rejected — it breaks existing Swift callers for no behavioural gain, while a thin forwarder preserves compatibility at negligible depth cost.
- Respects the identifier-carrier lineage and the Store and State detachment vocabulary: state cleared with detached subscribers completed and next update starting fresh, capability row plus reverse-index entries cleared, and empty-identifier lifecycle entries observably identical to no-op.

## Testing Decisions

- A good test crosses the public detach seam with real registration and asserts externally observable cleanup, never adapter type identity or factory call counts.
- Modules under test: the Store detach path through both the identifier entry and the plugin-shaped forwarder, plus the Bridge detach delegation.
- Coverage pins: register then detach then query reads absent, remove then read returns absent, empty identifier stays an observable no-op, detach never provisions capabilities, plugin-shaped and identifier-shaped detach agree, and Bridge detach matches direct Store detach.
- Prior art: existing plugin lifecycle order suites, Bridge unregister and remove suites, and detach postcondition pins, extended with identifier-entry agreement cases.

## Out of Scope

- Fire entries, scheduling policy, State boxing, registry wait, scheduler internals, or timeout handling.
- Public Objective-C shape changes beyond internal delegation.
- Retained plugin ownership, lifecycle retention maps, or Sample teardown changes.
- Lock, emission, or concurrency changes.

## Further Notes

- Docs-only wave: no production behaviour change beyond seam shape plus Bridge delegation plus adapter deletion; full suite must stay green.
- Deletion test: deleting the identifier entry would force every identifier-only caller to fabricate a plugin again, so the entry earns its keep; deleting the fake adapter removes complexity with no caller-visible loss.
- Sequence: the identifier entry lands before Bridge cleanup so the tree stays green throughout; no new decision record is needed beyond this spec.
