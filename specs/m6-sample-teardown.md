# M6 — Sample teardown helper (single cleanup seam)

## Problem Statement

Each sample example copies four to five cleanup lines (unregister plus remove-state plus cancellable drain, ObjC adds bridge detach plus state asserts, scheduling adds config restore). Shared singletons mean one missed line leaks capabilities or subjects into the next example; scattered timing pumps mix demo sequencing with async semantics.

## Solution

Add one small private teardown helper in the sample module that clears the plugins and state it created, and call it at the end of each example with explicit plugin and state lists plus in-out cancellables. Keep setup order, per-example durations, scheduler restore adjacency, and all printed output unchanged.

## User Stories

1. As a reader, I want each example to end clean on the shared store, so that repeated runs never observe stale capabilities.
2. As a maintainer, I want to add a new example without copying cleanup lines, so that teardown cannot be forgotten.
3. As an ObjC reader, I want detach plus remove-state plus nil assert still explicit per example, so that the bridge lifecycle stays teachable.
4. As a scheduler reader, I want configure-then-restore adjacent, so that global config leaks are impossible to miss.

## Implementation Decisions

- Module: sample module only; no prod change. Helper is private static with explicit plugin list, state identifier list, and in-out cancellables; optional bridge overload for ObjC detach.
- Interface: no public change; all sample types stay internal.
- Setup and register order untouched (order-agnostic demo preserved); per-example wait durations stay explicit at call sites (no single-pump constant).
- Scheduler restore stays at the scheduling call site adjacent to configure, not hidden in the generic helper.
- Legacy run spelling demo untouched in this slice; compat replacement is a separate ticket.
- Grill (auto): setup-gathering helper rejected (hides ordering demo); singleton-capturing helper rejected (breaks injection); single-duration pump rejected (flaky or slow); hidden scheduler restore rejected (leak on early return); legacy-API swap rejected (doc-behavior change, needs compat window).

## Testing Decisions

- Sample has no tests; verify with build of the sample target plus one manual run observing all four sections plus zero pending/active plus nil states after run.
- No new test files; prod suite must stay green untouched.

## Out of Scope

- Demo API modernization; setup consolidation; timing consolidation; public helper; any Bridge or Store prod edit.

## Further Notes

- Independent, lowest risk, do first to ease reading for later waves. Monorepo build excludes sample from default prod build; verify with explicit sample target if needed.
