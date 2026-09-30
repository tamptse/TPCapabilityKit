# M7 — Descriptor mapper thin contract (keep middle mapping)

## Problem Statement

Descriptor construction reads as three layers (ObjC wrapper with two initializers, middle mapper function, pure domain struct) for one value mapping. Readers propose inlining the middle function or merging the two initializers to save a forward.

## Solution

Keep all three and document why: the wrapper owns ObjC shape plus identifier policy, the mapper owns capability, priority, and timeout forks in one place, the domain stays a pure struct with nil-timeout semantics. No prod change.

## User Stories

1. As an ObjC caller, I want omitted timeout to pin as explicit while wire-negative means scheduler default, so that both initializer spellings agree.
2. As a Swift author, I want one shared priority range for coercion plus strict query, so that new priority cases touch one place.
3. As a reviewer, I want every string-to-capability conversion through one function, so that mapping cannot drift per call site.
4. As a future architect, I want the inline rejection recorded, so that field-change cost is judged correctly.

## Implementation Decisions

- Module: mapper owns capability, priority, and timeout forks; wrapper owns ObjC shape plus auto-identifier versus client-identifier policy for cancel-by-identifier; domain owns value semantics.
- Interface: no ObjC selector change. Two initializers stay separate (auto vs client identifier); validity query stays as a forward preserving the public selector; internal live-view initializer stays for Swift-to-ObjC read coverage.
- Timeout pin stays singly owned in the mapper and never follows a reconfigured scheduler default; display lossiness stays accepted with explicitness flag preserving the distinction.
- Grill (auto): inlining mapper rejected (forces descriptor to own three forks plus duplicates for scheduler and bridge query paths); merging initializers rejected (ObjC overload plus cancel-by-identifier break); moving timeout type rejected (inverts door-to-mapper layering); duplicating range rejected (drift on new cases); deleting live-view initializer rejected (loses Swift-to-ObjC read coverage without public API savings).

## Testing Decisions

- No test changes. Verify through timeout resolver suites (omitted, wire-negative, explicit, both-paths, wait-share, display, round-trip, client identifier, agreement, collapse) plus priority coercion tests.
- Any real thin must keep all resolver tests green and keep the pinned literal accessible to tests.

## Out of Scope

- Middle-function inline; initializer merge; timeout-type move; pin-to-default merge; priority validation throw change.

## Further Notes

- Independent; pairs with M5. Revisit only on priority-range change or ObjC major-break window. Respects omitted-timeout-pin ADR. No new ADR.
