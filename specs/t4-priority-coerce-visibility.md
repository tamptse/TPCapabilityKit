**Status:** verify-only (2026-09-28: DEBUG warn + isValidPriority already landed — ObjcMapper.swift:75-99, ObjcTaskDescriptor.swift:109-112; 78-test Bridge filter green).

## Problem Statement

The Bridge spells Task priority as a plain integer at the ObjC boundary, but the only documented priority contract lives on the Swift side as a five-case domain enum. When an ObjC caller passes an out-of-range raw value, the mapper silently coerces it to normal: the task still schedules, the read-back priority reports normal, and nothing anywhere records that coercion happened. A caller that typo'd a priority (or computed one from a bad mapping) cannot distinguish "my task genuinely runs at normal" from "my input was rejected and replaced with normal". Debugging a mis-prioritized task currently requires reading the mapper source; the runtime offers no signal.

## Solution

Keep the safe coercion exactly as-is in production (out-of-range still becomes normal, no crash, no drop, no `@objc` signature change) and make the coercion fail-visible in two additive ways: the single coercion point warns in DEBUG builds with the offending raw value, following the existing DEBUG-warning precedent in the codebase; and a new additive validity check, visible to ObjC, lets strict callers validate a raw priority before crossing the Bridge. Lenient callers see zero behavior change; strict callers gain a pre-flight check; debuggers gain a log line pointing at the bad input.

## User Stories

1. As an ObjC consumer passing a valid priority, I want my task to schedule exactly as before, so that no working call site changes behavior.
2. As an ObjC consumer passing an out-of-range priority, I want my task to still schedule at normal rather than crash or drop, so that a bad literal never loses work.
3. As an ObjC consumer debugging a mis-prioritized task in a DEBUG build, I want a warning naming the offending raw value, so that I can tell a coerced normal apart from a genuine normal.
4. As an ObjC consumer debugging in a release build, I want zero logging overhead or behavior change, so that diagnostics never cost production performance.
5. As a strict caller, I want to validate a raw priority before constructing a descriptor, so that I can reject or fix bad input on my side instead of silently scheduling at normal.
6. As a lenient caller, I want to keep calling the descriptor constructors exactly as today without any new required step, so that no call-site migration is needed.
7. As a scheduler maintainer, I want the valid range stated once and shared by both the coercion and the validity check, so that the next range change touches one place.
8. As a scheduler maintainer, I want the coercion point to stay the single mapping between ObjC integers and domain priorities, so that no second coercion path can drift.
9. As a reviewer, I want the existing `@objc` surface frozen (both descriptor constructors, the priority read-back, no new failure mode), so that ObjC call sites need no audit beyond the additive check.
10. As a reviewer, I want the DEBUG warning to follow the established warning style already used elsewhere in the codebase, so that log output stays greppable and consistent.
11. As a test author, I want the existing coercion suites to stay green without edits, so that the change is proven by pinned observable behavior rather than rewritten expectations.
12. As a test author, I want the new validity check pinned through the existing descriptor-observable seam, so that no new test seam is introduced.
13. As a future deepener, I want coercion-plus-visibility owned once in the mapper core with thin descriptor translators, so that the next Bridge-boundary concern lands in the same place.

## Implementation Decisions

- **Module**: the mapper module keeps owning the whole ObjC-to-domain priority mapping behind its interface; both descriptor creation paths stay thin translators. No new module is introduced; no logic moves into the Bridge view or the scheduler.
- **Interface**: the valid range is stated once. The coercion reader (raw to domain, out-of-range to normal) and the new validity check both read that single boundary — the check never restates the range with an independent condition.
- **Depth**: no depth change — the change adds a DEBUG-only side effect plus one additive query over the existing boundary, without adding a layer or a wrapper type.
- **Seam**: the highest seams stay where they are. Tests keep crossing the descriptor observable seam (constructed priority plus read-back priority) and the mapper interface. No new seam is created.
- **Diagnostics style**: the DEBUG warning follows the codebase precedent of `#if DEBUG`-guarded warning prints naming the offending input. It logs the raw value that was coerced, so the log line alone identifies the bad call site input. Release builds emit nothing.
- **Validation API shape**: strictly additive and ObjC-visible, so both Swift and ObjC strict callers can pre-validate. It reports validity only; it never coerces, schedules, or stores. Existing constructors keep their signatures verbatim and their lenient behavior.
- **`@objc` surface care**: both descriptor constructors and the priority read-back keep their signatures and semantics verbatim. The only surface addition is the validity check; no existing selector is renamed, removed, deprecated, or given a new failure mode in this change.
- **Prod behavior freeze**: out-of-range still coerces to normal on every build configuration. The DEBUG warning is observability only — it never alters the coerced value, never traps, and never reaches release.
- **Rejected alternatives**: a failable/throwing construction path was rejected because it breaks ObjC init compat and changes production behavior from schedule-at-normal to fail; edge-clamping (pin to nearest valid case) was rejected because it changes scheduling semantics — a large raw would jump the queue instead of taking the safe default; a release-build log was rejected because the scheduling path should stay quiet and allocation-free in production; keeping the coercion silent was rejected because that is the reported defect.
- **Respects vocabulary**: Bridge stays the single ObjC scheduling adapter; Tasks keeps its priority queues and dequeue order untouched; the descriptor keeps wrapping the Swift descriptor as its domain payload.

## Testing Decisions

- A good test pins externally observable priority behavior (valid raws round-trip, out-of-range still reads back as normal, the validity check agrees with the coercion boundary on every raw) through the descriptor observables, never the mapper internals or log output.
- Modules under test: descriptor observables (both constructors, read-back agreement with the underlying domain value) and the new validity check (boundary cases on both sides of the valid range, agreement with coercion). Prior art: the existing coercion suites pinning out-of-range-to-normal and read-back agreement are the models for any touched test.
- Verification for the change: full `swift test` green with zero edits to the existing coercion suites; those suites must pass unchanged, proving production behavior survived. New assertions cover only the additive check plus boundary agreement, and cross only the existing descriptor-observable seam.
- DEBUG-warning output itself is not asserted (log text is not a seam); its presence is verified by review against the codebase warning precedent, not by a test.

## Out of Scope

- Any change to production coercion semantics (out-of-range still becomes normal; no throw, no failable init, no drop, no edge-clamp).
- Any change to the valid priority range itself or to the Swift domain enum.
- Any change to the Swift-side descriptor shape, scheduler queues, dequeue order, retry, timeout, or slot admission.
- Any rename, removal, or deprecation of an existing `@objc` selector.
- Any release-build logging on the scheduling path.
- Unifying or touching the timeout fork, the registry wait interface, park mechanics, or settlement.

## Further Notes

- Self-review outcome (autonomous refinement): coerce-safe plus fail-visible is the load-bearing split — safety owns production, visibility owns DEBUG plus the additive check. Cut-now alternatives were challenged — (a) failing construction on bad input was rejected because the Bridge contract is lenient-by-design and ObjC inits cannot surface Swift errors without a compat break; (b) clamping to the nearest edge was rejected because it silently promotes a typo'd task to critical or demotes it to background instead of the neutral default; (c) logging in release was rejected because it taxes the hot scheduling path for a diagnostic need; (d) documenting the coercion without any runtime signal was rejected because docs do not help a caller staring at a normal-priority task wondering why. The load-bearing constraints are: single range statement shared by coercion and check, prod coercion byte-identical, `@objc` surface additive-only, DEBUG-only warning.
- Vocabulary: module (mapper priority detail, Bridge view, Tasks path), interface (mapper seam, descriptor-observable seam), depth (no new layer), seam (single coercion point, descriptor observables, additive validity query), adapter (Bridge as single ObjC adapter), leverage (existing coercion suites as the verification seam), locality (range once, coercion plus check adjacent).
- Source of decisions: the current Bridge files (single coercion point feeding one descriptor-building core reached by both constructors), the existing coercion test suites, and the DEBUG-warning precedent used elsewhere in the codebase.
