## Problem Statement

Plugin lifecycle ordering is comment-only and unpinned. Registration promises capabilities are visible inside `start` (register-before-start avoids a check-then-act race), but no behavior test fails if the two lines swap — the deletion test stays green. Unregistration cleans state and capabilities with no documented order or postcondition, so a future mover cannot tell which sequence is load-bearing. Empty-id rejection is owned once per domain by the state and registry seams, yet the identical no-op observable contract is not pinned at the facade, so a guard added at the facade or removed from an owner would drift silently.

## Solution

Keep the Store facade as the single lifecycle seam with no new type and no signature change. State the register-before-start and unregister postconditions once, beside the existing lock-order contract where reviewers already check Store-to-submodule discipline, and pin them with facade-only behavior tests. Land before any Store file split so the contract text moves with the facade verbatim.

## User Stories

1. As a plugin author, I want capabilities queryable synchronously inside `start`, so that initialization never races registration.
2. As a Store maintainer, I want register-before-start stated as a postcondition beside the lock-order contract, so that a line swap reads as a contract break.
3. As a Store maintainer, I want the unregister postcondition (state cleared, detached subscribers completed, capabilities detached) stated once beside register, so that order changes review against one text.
4. As a State consumer, I want unregister to leave no readable state and no live detached subscriber, so that re-registration starts fresh.
5. As a capability consumer, I want unregister to clear the plugin row and its reverse-index entries, so that queries and snapshots agree.
6. As a test author, I want register ordering pinned by a facade test where `start` queries its own capability, so that swapping the lines turns red.
7. As a test author, I want unregister pinned by a facade test asserting detach plus clear, so that a dropped cleanup step turns red.
8. As a test author, I want empty-id no-op pinned identically for state and capability paths through the facade, so that per-domain ownership cannot diverge.
9. As a reviewer, I want empty-id guards to stay at the owner seams with the facade delegating without guarding, so that new methods are safe by construction.
10. As a future splitter, I want the lifecycle contract adjacent to the lock-order contract, so that a file move carries both texts together.
11. As a Bridge consumer, I want no lifecycle signature change, so that ObjC capability-consumers are untouched.
12. As a Tasks integrator, I want no change to emission order or waiter behavior, so that per-Capability-before-snapshot and whole-set readiness are unaffected.

## Implementation Decisions

- **Module**: the Store facade remains the single lifecycle seam; the state helper owns update/get/remove/observe guards and the registry owns register/unregister/query-capabilities guards. No new module or type is introduced.
- **Interface**: no signature change to register, unregister, state, or capability queries. The facade keeps thin delegation without empty-id guarding; each owner rejects empty ids at its own seam.
- **Depth**: no depth change — one contract comment block plus behavior pins. Ordering rationale (register-before-start enables synchronous query inside `start`; unregister detaches state and clears capabilities) is stated once, not repeated per call site.
- **Seam**: the highest seam stays the Store facade. Contract text lives adjacent to the lock-order contract (no caller holds a Store lock across a submodule call; changes collected under lock and emitted after unlock), so lifecycle order and lock discipline review in one hop.
- **Adapter**: no adapter change. ObjC plugins stay capability-consumers only; timeout, lease, and scheduling paths are untouched.
- **Locality**: register postcondition, unregister postcondition, and empty-id ownership (one guard per domain, facade delegates) share one reviewable block. No per-method duplication.
- **Empty-id subtlety**: invoking the lifecycle entry with an empty id still runs `start` by delegation, but every state write/read and capability registration it can reach is a no-op at the owner seam, so the observable effect stays identical to doing nothing. The contract pins the observable no-op, not the `start` call itself.
- **Ordering constraint**: land before any Store file split, so the split (if triggered) relocates the contract text mechanically with zero test edits.
- **Respects ADRs**: Store-to-Tasks lock order and shared slot-domain split (counts sum, admission shares one domain) are untouched; state creation-vs-observation split (writers get-or-create, observation never creates, removal completes detached) and registry mutate-and-notify order (per-Capability notices before whole-snapshot publish) are restated as constraints, not reopened.

## Testing Decisions

- A good test crosses the public Store facade seam and asserts externally observable behavior (query inside `start`, state/capability absence after unregister, snapshot and observation deltas for empty ids), never internal call order, lock identity, or file placement.
- Modules under test: lifecycle entries (register, unregister) through the facade; state lifecycle (detached completion, fresh subject on next update) and registry detachment (reverse-index clear, snapshot clean) only as observed through the facade.
- Pinning tests (facade-only, all on fresh instances):
  - register/start ordering: a plugin whose `start` synchronously queries its own capability must observe true; fails if registration moves after `start`.
  - unregister detach plus clear: after unregister, per-plugin query is empty, per-capability query is false, state read is nil, detached state subscribers are completed, and a fresh update reaches only new subscribers.
  - empty-id no-op identical: register and unregister entries with an empty id leave queries, reads, per-capability observations, and whole-snapshot observations identical to before (no new values, no snapshot delta, state observation completes immediately).
- Prior art: facade register/unregister round-trip test, detached-completion removal test, guard-ownership suites (owner seams reject empty ids), observation-narrowing suite (identical no-op plus notice-before-snapshot order).
- Verification: full suite green with zero production-code edits after the pinning ticket; after the contract-comment ticket, identical green plus grep confirms lifecycle-order text appears once beside the lock-order contract and no test references internal helpers directly.

## Out of Scope

- Any semantics change to registration order, unregistration order, empty-id guard placement, state creation/observation/removal, registry emission order, generation prune, slot admission, Deadline/expiry, settlement, or Bridge mapping.
- New lifecycle API, new guard at the facade, new lock domain, new observation grain, or scheduler changes.
- The Store file split itself (parked pending its own trigger); this spec only requires the contract text sit where the split can carry it.
- Reformatting, renames, or prototype code.

## Further Notes

- Grill verdict (grill-with-docs, autonomous): proceed as specified. Strongest angles (swap-lines-stays-green, undocumented unregister order, unpinned identical no-op) all deepened into facade-only pins above; rejected: facade-level empty-id guard (would duplicate owner guards and violate safe-by-construction), new lifecycle type or ordering enum (leverage ~nil, adds seam for a two-line order), and per-method contract copies (drift risk — state once beside lock-order).
- Deletion evidence the pins must invert: swapping register lines, dropping either unregister cleanup, or removing one owner guard must turn at least one new test red.
- Source of prototype decisions: none — no prototype; decisions derive from the current facade/owner split and the domain glossary Plugin/Store sections.
