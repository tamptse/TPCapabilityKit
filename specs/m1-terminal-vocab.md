# M1 — Terminal vocabulary contract (Lease + Tasks path)

## Problem Statement

One lifecycle ending is spelled in four places (public terminal language, terminal input language with a cancel case, internal directive language, pre-admission gate language). Newcomers perceive duplication and are tempted to add a fifth spelling or merge phases that have different meanings.

## Solution

Pin the current shape as intentional. The public terminal language stays owned by Lease with a typealias in the Tasks path. The input language keeps its cancel-only case mapping to expired at the single settle site. The directive stays a private decision output read adjacent to the row transition it applies. The gate stays a pre-admission tri-state that never terminalizes. Docs state the phase table once so future waves do not re-suggest blind fusion.

## User Stories

1. As a Tasks author, I want exactly one place to add a new terminal case where the compiler forces exhaustiveness, so that I do not miss a switch.
2. As a reviewer, I want decide-then-transition to read as one path, so that retry-identity review stays local.
3. As a test author, I want the decision matrix covered through the public settle seam, so that refactors do not force call-site churn.
4. As a Lease consumer, I want cancel to land as expired deterministically, so that terminal reads stay tri-state.
5. As a gate reader, I want refused to stay silent without settling, so that slot release semantics stay obvious.
6. As a future architect, I want the deferred pure-resolver direction recorded, so that I do not re-propose it without the test-migration precondition.

## Implementation Decisions

- Module: Lease owns the public terminal language and the read-only retry-budget view; the lifecycle table is the single writer with each Lease mutation together with its row write in one locked transition.
- Interface: no signature change. Input language keeps cancel as input-only; directive stays private static; gate stays private with refused as silent no-settle plus scope-exit release.
- Same-Lease retry identity preserved with waiter preservation; budget checks live in Settlement, not in Lease.
- Custom equality ignoring associated Error values unchanged.
- Grill (auto): fusion of input into terminal rejected (would bloat terminal with cancel); promotion of directive to public resolver rejected (second seam for one decision); merge of gate into settlement rejected (breaks gate-never-terminalizes invariant); move of terminal owner rejected (cross-module reference for no file saved).

## Testing Decisions

- External behavior only through the settle seam: terminal rejects second settle, cancel lands expired, retry reuses identity and repumps, refused frees slot without executing.
- Modules: Lease terminal seam plus Tasks settle/gate seam.
- Prior art: decision-table tests, activation-gate tests, settlement guard tests, same-id exchange pins.
- Full suite must stay green; docs-only change verified with build plus targeted decision/gate filters.

## Out of Scope

- Public pure resolver type; merging gate into settlement; changing Lease equality; changing retry to fresh-Lease identity; any scheduler lock or slot change.

## Further Notes

- Depends on nothing; blocks nothing. Successor to the deferred settlement note: revisit pure resolver only after registry waiter test migration lands. Respect single-settlement, retry-ownership, single-rendezvous, and unified-lifecycle ADRs.
