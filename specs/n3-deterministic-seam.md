# N3 — Deterministic rendezvous test-only seam plus facade hygiene

## Problem Statement

The Store facade carries a deterministic-time trio on its prod interface that prod callers never need. Each member is a shallow pass-through across two modules: the facade spells the operation only to forward it, and the generations module spells it only to forward it again into the time module. A prod reader must learn three extra operations plus their ordering preconditions only to discover they are test-only.

Behind that trio sits a second shallow module: a deterministic probe that wraps a single registry call, then polls on the wall clock for up to five seconds and crashes when the count never arrives. Timing tests therefore depend on a sleep-and-retry loop instead of a true waiter rendezvous, so they are flaky by construction and every timing failure points at the probe rather than at the behavior under test.

## Solution

Narrow the prod facade to the scheduling contract prod actually uses — schedule, schedule-and-wait, cancel, and pending/active counts — and relocate the deterministic trio onto a test-only seam owned by the time module. Collapse the probe into a single test-only rendezvous method on the time module that reads the true waiter registry instead of polling the wall clock. After the change a prod caller learns a smaller interface with more leverage per method, while a test author crosses one explicit test seam with deterministic settlement and no hidden timeout.

## User Stories

1. As a Store reader, I want the prod facade to expose only scheduling work, so that I never wonder when prod enables deterministic time.
2. As a prod caller, I want no deterministic preconditions on the interface I learn, so that misuse is impossible by construction rather than a runtime crash.
3. As a test author, I want one explicit test-only seam for deterministic control, so that test setup reads as test setup and never as prod usage.
4. As a test author, I want advancing virtual time to settle through a true waiter count, so that timing tests are deterministic instead of poll-and-hope.
5. As a Tasks maintainer, I want park, expiry, activation, and settlement to keep crossing one sleep seam, so that waiter and executor still share one expiry path.
6. As a Deadline reader, I want timeout resolution to stay once at construction with a single race shared by waiter and executor, so that the expiry story does not fork.
7. As a time-module maintainer, I want live and virtual adapters plus the advance policy and the rendezvous to live in one module, so that wake-loss, duplication, and advance fixes land in one place.
8. As a generations reader, I want reconfigure to keep draining naturally while new work enters the new generation, so that in-flight work is never orphaned.
9. As a generations reader, I want counts to keep summing across live generations while slot admission shares one Store-owned domain, so that reconfigure never doubles the configured limit during drain.
10. As a reviewer, I want the deletion test to pass — deleting the probe removes polling complexity rather than redistributing it — so that the new module earns its keep.
11. As a future architect, I want the test-only seam to be the highest seam that still separates prod from test, so that no new seam is introduced deeper in the stack.

## Implementation Decisions

- Module: the time module stays the deep module behind one sleep seam. It owns live and virtual adapters, the advance policy, and after this change the deterministic rendezvous as a test-only adapter facet. The Store facade and the generations module keep no deterministic policy of their own.
- Interface: prod facade keeps the scheduling contract only. The deterministic trio moves to a test-only interface on the time module side; the probe interface disappears as an independent module and reappears as one rendezvous method with explicit expected-count semantics.
- Seam: highest seam preferred. Prod callers and prod tests cross the same narrow facade seam. Test-only control crosses a separate test seam owned by the time module, so prod and test never share preconditions.
- Adapter: live adapter and virtual adapter remain the two adapters that make the sleep seam real. The rendezvous is a test facet of the virtual adapter, not a third adapter and not a standalone module.
- Depth and leverage: removing three pass-through members deepens the facade — less interface to learn for the same scheduling behavior — and gives leverage to every prod caller and every facade test. Collapsing the probe deepens the time module — one rendezvous method with real registry depth behind it instead of a thin polling wrapper.
- Locality: deterministic enable-once, precede-first-use, virtual-only, and waiter-count rules concentrate in the time module. Queue-hop, park, Deadline expiry, activation, and Settlement stay where they are; this change moves no waiting, expiry, or settlement policy.
- Grill outcome (autonomous self-grill, best practice decided internally):
  - Q: Keep trio on the facade marked test-only versus relocate to a separate test seam? A: Relocate. A mark still teaches prod readers test preconditions; a separate seam removes them from the prod interface entirely.
  - Q: Keep the probe as a wrapper versus collapse into a rendezvous method? A: Collapse. One adapter means a hypothetical seam and two adapters means a real one — the probe has only one underlying registry, so it is a hypothetical seam that adds interface without variation.
  - Q: Keep wall-clock polling with a bounded wait versus read the true waiter registry? A: Read the registry. Polling trades determinism for a timeout constant; the registry already knows the count, so polling is accidental complexity.
  - Q: Split into two tickets versus one? A: Two. First relocate the seam so callers cross the right interface, then collapse the probe so the rendezvous changes under one roof with the seam already stable.
- ADRs respected: time module owns adapters and advance policy with thin spelling-only delegation from the Store; Deadline keeps only once-at-construction resolution plus the single shared race; one time instance stays shared across live generations so reconfigure never forks virtual time.
- CONTEXT terms unchanged: Store keeps its scheduling facade; Tasks keeps park, expiry, activation, and settlement behind one result rendezvous; Deadline keeps the single race for both the capability wait and the execution path; Time keeps live and virtual adapters plus the advance policy behind one sleep seam.

## Testing Decisions

- What makes a good test here: external behavior through the public seams — scheduling still schedules, advance still wakes exactly the expired waiters, cancellation still resumes, rendezvous still settles without wall-clock dependence — never assertions on forwarding chains or private registry shape.
- Modules under test: Store facade scheduling contract plus the time-module sleep seam and the test-only rendezvous facet.
- Prior art: deterministic advance suites, single-expiry suites, race-value proofs, timeout-contract suites, and generations drain suites must stay green; they already prove the wake semantics this change must preserve.
- Constraint: full suite green at each ticket boundary; no prod behavior change is observable except the absence of test-only members on the prod interface.

## Out of Scope

- Deadline race changes, capability-wait changes, park-and-wait changes, Settlement outcome changes, slot admission or wake-order changes, registry lock or emission changes.
- Timeout default or pin-literal changes, reconfigure drain semantics changes, lifecycle table changes, Bridge or Sample changes.
- New timing features, new scheduler configuration, new public scheduling entries.

## Further Notes

- Assumptions: strict concurrency; virtual registry already tracks the true waiter set, so the rendezvous can read it without new synchronization.
- Risk: tests currently crossing the facade trio need re-pointing at the test seam — mitigated by doing the seam move first as its own ticket before touching rendezvous internals.
- Independent group; no blocking edges beyond the internal two-ticket order. No new ADR; no glossary change.
