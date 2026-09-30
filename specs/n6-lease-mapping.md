# N6 — Lease mapping single truth

## Problem Statement

The lifecycle state of a scheduled unit of work is translated to integers in two places: a computed integer view beside the Swift lifecycle type, and the integer-backed state enum inside the Bridge live-view adapter. The two must be kept in sync by hand whenever a case is added, reordered, or removed, and the compiler cannot catch drift between them — a wrong number compiles silently. Production never reads the Swift-side integer; its only consumer is a test matrix that uses it as a dictionary key. The lifecycle module therefore carries a shallow duplicate integer vocabulary for a single test-only convenience.

## Solution

Delete the Swift-side integer view and let the test key by the lifecycle enum directly. Exactly one integer mapping remains: the exhaustive translation co-located with the Bridge live view, where the compiler forces every lifecycle case to be handled visibly. Integer knowledge then has one home, drift becomes unrepresentable, and the public terminal vocabulary is otherwise untouched.

## User Stories

1. As a Lease consumer, I want the terminal vocabulary unchanged (pending, active, completed, failed, expired), so that no lifecycle reading breaks.
2. As a Bridge consumer, I want state reads through the live view unchanged, so that terminal observations stay stable once seen.
3. As a test author, I want the transition matrix keyed by the lifecycle enum itself, so that I never depend on an integer intermediary.
4. As a maintainer adding a lifecycle case, I want the compiler to force me to handle it in exactly one translation, so that a missed mapping fails visibly instead of drifting silently.
5. As a reviewer, I want integer translation readable in exactly one place, so that audits take seconds instead of cross-checking two tables.
6. As a test author covering settlement, I want the decision matrix still exercised through the public settle seam, so that refactors do not force call-site churn.
7. As a future architect, I want the single-truth direction recorded, so that nobody reintroduces a second integer table for convenience.

## Implementation Decisions

- Module: the lifecycle module loses its duplicate integer view; the Bridge adapter keeps the sole integer translation. Terminal ownership, equality ignoring associated error values, retry-budget views, and the single-writer lifecycle table are all untouched per the pinned terminal-vocabulary contract.
- Interface: no lifecycle case added, removed, or renamed; no signature change beyond removing the integer view. The Bridge adapter interface is unchanged.
- Seam: work at the highest seam — the public terminal read plus the Bridge state view. No new seam is introduced; the existing exhaustive translation seam is the one the compiler already guards.
- Adapter: the Bridge live view stays the single scheduling adapter for integer translation, with its exhaustive mapping co-located beside the live read so new states fail visibly at that site.
- Depth: removing the parallel integer view deepens the lifecycle module — one fewer spelling of the same ending for newcomers to trip over.
- Leverage: leverages the existing exhaustive seam and the existing decision-matrix coverage rather than adding machinery; the test migration rides the matrix suite that already pins accepted-vs-rejected transitions.
- Locality: integer knowledge lives in exactly one place (the Bridge adapter); the lifecycle module owns meaning, the adapter owns numbering, never both.
- Grill (self-grilled, no user input per task constraints): delete-vs-deprecate decided as delete, because production has zero readers and the only consumer is the test matrix — a deprecated alias would preserve the shallow seam instead of deepening it. Add-Hashable-to-keep-dict-shape rejected as new public API for a test-only need; the matrix instead looks up by enum identity through equality, which needs no new surface. Keep-for-compat rejected since verification shows no production reader.
- Respect: the pinned terminal-vocabulary contract — public terminal language stays owned by the lifecycle type, input-with-cancel maps to expired at the single settle site, the directive stays private, and the pre-admission gate never terminalizes. Settlement keeps the retry-budget check and waiter preservation; this change moves no decision.

## Testing Decisions

- What makes a good test here: pin the seam, not the numbering — external behavior through the settle seam (terminal rejects second settle, cancel lands expired, retry reuses identity, gate refusal frees without executing) plus Bridge state reads, never integer literals.
- Modules under test: the Lease terminal seam plus the Bridge lifecycle view. Prior art: decision-table tests, the transition-matrix suite, activation-gate tests, and Bridge lifecycle coverage.
- The migrated matrix asserts identical accepted-vs-rejected outcomes as today, keyed by enum rather than integers; no new test files required.
- Constraint: full suite green; docs-and-test-only change apart from the single deleted view, verified with build plus targeted decision, matrix, and Bridge lifecycle filters.

## Out of Scope

- Any change to the terminal vocabulary itself, to equality semantics, to retry identity, or to the scheduler lock and slot mechanics.
- Priority, capability, or descriptor mappings, and the timeout-compat fork.
- New public API including hashability additions; new integer values; new lifecycle cases.
- Merging the input, directive, or gate vocabularies into the terminal language.

## Further Notes

- Independent of the fire-alias cleanup; neither blocks the other and they may land in any order.
- Assumption: zero production readers of the Swift-side integer view (verified by search — only the matrix suite keys by it), so deletion breaks no shipped path. Successor to the deferred pure-resolver note only in that it removes a different duplicate; the pure-resolver precondition is unaffected.
