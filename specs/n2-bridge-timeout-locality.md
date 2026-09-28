## Problem Statement

The ObjC timeout fork (wire-negative meaning unspecified vs explicit value vs omitted call arriving as a pinned compat literal, plus a display fallback) is smeared across three places: the internal mapper module owns the resolver plus thin forwarder spells for display/explicitness, the descriptor owns two creation paths (plain and client-id) that each resolve the wire and then translate through the mapper, and the display/explicitness readings bounce descriptor→mapper→timeout-form instead of reading directly. A reviewer asking "what does an omitted timeout mean after a scheduler reconfigure?" must hop mapper, descriptor, and the timeout form to prove the pin never follows the reconfigured default, and each hop is a drift risk: a second pin literal, a forwarder that subtly reinterprets explicitness, or a creation path that resolves differently from the other.

## Solution

Collapse the fork to one locality: delete the mapper forwarders so the descriptor reads display/explicitness directly off the timeout form, keep a single pin constant owned by the timeout form, and route both descriptor creation paths through the same resolve-then-build form. The Bridge view stays a thin translator; the whole wire-negative vs explicit vs pinned-omitted distinction continues to resolve once behind the timeout-form interface, with `nil` (scheduler default applies at Deadline construction) vs explicit traveling downstream unchanged. No behavior change: wire-negative stays unspecified, every non-negative wire (including the pin literal) travels as explicit, and display falls back to the pin only for unspecified.

## User Stories

1. As a Bridge maintainer, I want the timeout fork stated once on the timeout form, so that omitted vs wire-negative vs explicit reviews in a single hop.
2. As an ObjC caller, I want an omitted timeout to keep pinning the compat literal as explicit, so that reconfiguring the scheduler default never silently moves my behavior.
3. As a Swift scheduler consumer, I want wire-negative to keep arriving as `nil`, so that the configured default applies once at Deadline construction.
4. As a descriptor reviewer, I want both creation paths (plain and client-id) to share one resolve-then-build form, so that cancel-by-id and plain scheduling cannot disagree on timeout meaning.
5. As a UI caller, I want the display reading (stored value when explicit, pin fallback otherwise) plus the explicitness flag to read directly off the stored timeout, so that no forwarder can reinterpret them.
6. As a future contributor, I want exactly one pin constant, so that no second literal can drift out of sync with the compat promise.
7. As a Deadline integrator, I want the Bridge to keep delivering `nil`-vs-explicit downstream only, so that timeout-once resolution at construction stays the sole Swift resolver.
8. As a test author, I want timeout behavior asserted through descriptor creation plus Deadline construction, so that the collapse is proven by wire-to-domain behavior not by forwarder spelling.
9. As a time-module reviewer, I want live and virtual adapters plus the advance policy untouched, so that deterministic-time behavior is unaffected by the Bridge collapse.
10. As a Bridge view maintainer, I want the scheduling adapter to stay a thin translator, so that completion delivery and capability translation do not absorb timeout policy.
11. As a reviewer, I want the mapper forwarders gone rather than deprecated, so that no stale spelling can be re-imported by a new call site.
12. As an ADR reader, I want the change traceable to the pinned-omitted promise and Deadline-owned expiry, so that the collapse clearly respects prior decisions rather than reopening them.

## Implementation Decisions

- **Module**: the internal timeout form remains the single owner of the fork (wire-negative→unspecified, non-negative→explicit, pin literal→explicit pinned default, unspecified→nil domain reading, display fallback, explicitness flag, stored-value mapping). The mapper module keeps capability/priority/descriptor assembly; it loses timeout display/explicitness forwarding. No new module is introduced.
- **Interface**: the descriptor's public seam is unchanged (capabilities, priority with normal-coercion, timeout defaulting to the pin literal, maxRetries, metadata, client-id variant, `timeout`/`hasExplicitTimeout` display readings, underlying domain descriptor). The internal change is reader locality: descriptor reads go directly to the timeout form; the single pin constant is owned by the timeout form with the mapper spelling (if retained for source compatibility) aliasing it, removed at rest.
- **Depth**: depth decreases by two forwarders. No new abstraction is added; both creation paths call the same resolve-then-build sequence (resolve wire once, build domain descriptor from the resolved form) instead of each inlining its own hop through the mapper.
- **Seam**: the highest seam stays the Bridge scheduling adapter (`TPStoreBridge` taskScheduler live view) plus the domain scheduling facade. Tests cross descriptor creation and Deadline construction; no new seam is created. The timeout-form interface remains the one seam the Bridge view and descriptor cross for timeout meaning.
- **Adapter**: the Bridge remains the single ObjC scheduling adapter and stays thin: capability translation, priority coercion, descriptor assembly, and completion-queue hopping gain no timeout policy. Timeout policy lives entirely in the timeout form behind its interface.
- **Locality**: resolver, domain reading (`resolved`), display reading (`display`), explicitness flag (`isExplicit`), stored-value mapping (`fromStored`), and the pin literal sit adjacent on one form, so the full fork (including the deliberate explicit-30.0 vs omitted indistinguishability downstream) reads without hopping to the mapper or descriptor.
- **Leverage**: leverage is fork locality plus duplication removal: one pin to audit, one resolver to extend, zero forwarder sync. Blast radius is bounded because downstream only distinguishes `nil` from non-`nil`, so forwarder deletion cannot alter scheduling behavior once both creation paths share the form.
- **Respects ADRs**: ADR-0020 (omitted pins the compat literal as explicit; wire-negative stays unspecified resolved once at Deadline construction; whole fork reads once behind the mapper interface — this change tightens that locality from mapper-owned to form-owned without reopening the pin promise); ADR-0012/0023 (Deadline owns timeout-once resolution at construction plus the single race; live/virtual adapters and advance policy live in the time module — the Bridge collapse must not move resolution into the Bridge or fork virtual time).

## Testing Decisions

- A good test crosses descriptor creation and asserts wire-to-domain behavior (wire-negative→unspecified/`nil` domain with display falling back to pin and explicit flag false; pin literal→explicit pinned value; arbitrary non-negative→explicit unchanged; Swift `nil` round-trip→unspecified), plus Deadline-construction evidence that `nil` picks up the configured default while explicit does not follow reconfigure — never the spelling of the reader chain.
- Modules under test: timeout form (resolver, domain/display/explicitness readings, stored-value mapping), descriptor both creation paths (plain and client-id agree on every wire class), mapper retained assembly (capability/priority/descriptor build unchanged).
- Prior art: ObjC timeout/compat suites around the pinned literal, wire-negative, and reconfigure-independence plus Deadline construction tests; the collapse must keep every one green with zero test-semantics edits, plus one mechanical grep proving no forwarder or second pin literal remains.

## Out of Scope

- Any change to timeout semantics (pin value, wire-negative meaning, omitted-vs-explicit downstream indistinguishability, `nil`-vs-explicit downstream contract, Deadline-once resolution).
- Changing descriptor public defaults, priority coercion, capability translation, completion delivery queues, or the scheduling adapter shape.
- Touching Deadline race, time adapters, advance policy, slot admission, lifecycle/settlement, or State/registry internals.
- Renames beyond the collapse or formatting churn.

## Further Notes

- Pin-ownership tie-break: the timeout form owns the literal; if the mapper spelling must stay temporarily for source compatibility it aliases the form-owned constant (single source of truth) and is removed at rest — never two independent literals.
- Explicit-30.0 vs omitted indistinguishability downstream is intentional per the compat promise: both travel as explicit pinned value; only the scholar of the fork (the form) knows one arrived as omitted. Do not "fix" this into a third state.
- Source of prototype decisions: none — no prototype; decisions derive from the forwarder/descriptor inventory and ADR-0020/0012/0023.
