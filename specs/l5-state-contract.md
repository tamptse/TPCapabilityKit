# L5 — State observation contract + DEBUG type warn

## Problem Statement
`StoreState.observe` uses `compactMap(coerce)` — nil and wrong-type both filter silently. Swift struct state is invisible to ObjC `NSObject` grain and vice versa, with no log. Removals complete without emitting nil, forcing long Sample comments to teach the implicit contract.

## Solution
Declare the typed-edge contract once at the Bridge door + StoreState header: wrong-typed reads as absent, removals complete, never emit nil. Add DEBUG-only warn when a non-nil subject value fails `NSObject` coercion (ObjC grain). No behavior change in release.

## User Stories
1. As a plugin author, I want a mistyped observe to warn in DEBUG, so that I don't debug silent absence for hours.
2. As an ObjC author, I want the NSObject-grain rule stated once, so that struct invisibility is by design not a bug.
3. As a Sample reader, I want one-line contract pointer, so that long remove semantics comments vanish.

## Implementation Decisions
- Module: State owns update/get/remove/observe (CONTEXT); Bridge door only orchestrates hop, coercion policy lives with `StoreState.coerce`.
- Interface: no signature change. Docs on `observeState/getState/subscribe` + `ObjcStoreBridge.subscribe/getState` state the grain. DEBUG warn in door/bridge when `subject.value != nil && !(value is NSObject)` on ObjC path.
- No NSSecureCoding/dictionary boxing seam now (deferred; would be new module).
- Grill (auto): warn-only, never throw/emit; keep `compactMap` semantics.

## Testing Decisions
- External: mistyped get returns nil; removed observe completes; DEBUG warn is manual (no assert on print). Prior art: State rendezvous/removal pins.
- Full suite green.

## Out of Scope
- New boxing, scheduler, registry, fire.

## Further Notes
- Independent of L1/L2; sample-doc edit overlaps L4 — sequence after L4.
