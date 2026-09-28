## Problem Statement

`DynamicStore.swift` (458 lines) colocates three lock domains behind one Store facade: the facade itself (~271 lines, `DynamicStore`), `StoreState` (~86 lines), and `StoreSchedulingGenerations` (~99 lines). The registry (`CapabilityRegistry`) already lives in its own module; State and generations are co-resident in-file. Readers reviewing the Store→Tasks lock-order contract (ADR-0022) currently get it in one reviewable place, but continued growth (a fourth lock domain, prune-logic churn, review friction) could flip the trade-off toward a split.

## Solution

PARK by default: keep State + generations colocated behind the Store facade. The two split seams stay pre-drawn at facade→State and facade→generations delegation but are not cut. Revisit only on trigger: a fourth lock domain appears, prune logic stays stable for one full cycle, or renewed review friction (file > ~600 lines or lock-order reviews start hopping painfully). If cut, split into `DynamicStore+State.swift` + `DynamicStore+Generations.swift` with the lock-order contract comment duplicated in each file. No semantics change either way.

## User Stories

1. As a Store maintainer, I want the lock-order contract readable in one file, so that Store→Tasks reviews need a single hop.
2. As a State consumer, I want writers to get-or-create and observation alone to never create, so that subscription lifecycle stays explicit per the State glossary.
3. As a scheduling consumer, I want reconfigure to preserve in-flight generations with summed counts and one shared slot domain, so that limits never double during drain.
4. As a Tasks integrator, I want park/Deadline/activate/settle to stay in Tasks while set-matching stays in the registry, so that whole-set readiness crosses one registry wait seam.
5. As a test author, I want all tests to cross the public Store facade seam, so that a future mechanical split breaks zero tests.
6. As a reviewer, I want the split seams pre-drawn at facade delegation points, so that a triggered cut is a pure file move with no design debate.
7. As a Bridge consumer, I want deterministic-time spelling to stay on the facade, so that the Time test surface does not churn.
8. As a future splitter, I want each split file to carry the lock-order contract comment, so that no file reads lock-free in isolation.

## Implementation Decisions

- **Module**: `DynamicStore` remains the single Store module and sole public interface; `StoreState` and `StoreSchedulingGenerations` remain internal helpers, whether colocated or split. No new module is introduced.
- **Interface**: the Store public seam is unchanged (register/update/get/observe state, query/observe capability, scheduling facade: schedule/schedule-and-wait/cancel/pending/active/configure plus the two fire entries). Internal owner seams (`StoreState.update/get/remove/observe`, generations `current/reconfigure/cancel/snapshot` plus deterministic-time spelling) are preserved verbatim across any split.
- **Depth**: no depth change — the split, if triggered, adds zero abstraction. Both candidate files are spelling-only relocation of existing types; the facade keeps thin delegation, generations keep prune-then-loop snapshot, State keeps get-or-create + detached-completion removal.
- **Seam**: the highest seam stays the Store facade. Tests and Bridge cross only the facade; the registry wait seam (`waitForAllCapabilities`) and the single generations snapshot remain the only cross-domain seams. No new seam is created; the two pre-drawn cut points are facade→State and facade→generations.
- **Adapter**: no adapter change. The Bridge remains the single ObjC scheduling adapter behind `TPStoreBridge`; deterministic-time spelling (`enableDeterministicTime/advanceTime/waitForDeterministicWaiters`) stays on the Store facade and delegates without logic.
- **Leverage**: leverage of a split now is ~nil (pure move, no behavior, no deduplication, no test enablement) — the quantified reason to park. The one-hop lock-order review locality outweighs three-file navigation while prune churn has only just settled (R4–R8).
- **Locality**: colocation keeps the lock-order contract (no caller holds a Store lock across a submodule call; Store→Tasks order per ADR-0022; prune holds one generations lock while reading drain state) adjacent to the two lock owners it governs. If cut, locality is restored by duplicating the contract comment header in each new file.
- **Lock-order contract preserved**: `StoreState` owns its lock, generations own theirs, registry owns its own; changes collected under lock and emitted after unlock; prune never removes the current generation. Split must not introduce lock nesting or cross-file lock acquisition.
- **Trigger definition**: cut only when (a) a fourth lock domain lands in the Store file, OR (b) prune logic is untouched for one full release cycle AND (c) review friction recurs (file > ~600 lines or ≥2 reviewers flag hop cost). Any single trigger re-opens ADR-0025/0026.
- **Respects ADRs**: ADR-0025 (colocation parked, seams pre-drawn) and ADR-0026 (facade revisit parked, deterministic-time spelling stays) remain authoritative; ADR-0022 (Store→Tasks order) and ADR-0021 (shared slot domain) constrain any split.

## Testing Decisions

- A good test crosses the Store facade seam and asserts externally observable behavior (state round-trip, observation completion on remove, pending/active sums across reconfigure, generation drain), never internal file placement or lock identity.
- Modules under test: Store facade (register/update/get/observe/unregister), State lifecycle (get-or-create, observe-never-creates, remove-completes-detached), generations (reconfigure-drain, snapshot sum-vs-share, prune-keeps-current). Prior art: `TPCapabilityKitStateLifecycleTests`, `TPCapabilityKitGenerationsTests`, `TPCapabilityKitGenerationsWiringTests`, `TPCapabilityKitSharedSlotDomainTests`, `TPCapabilityKitStoreDeterminismTests`.
- Verification for PARK: `swift build` green + full `swift test` green with zero file moves; grep confirms no test references `StoreState`/`StoreSchedulingGenerations` directly (only the facade), so placement is unobservable.
- Verification for a triggered SPLIT: identical `swift test` green with zero test edits; diff must show pure relocation (no logic delta) plus duplicated contract comment headers.

## Out of Scope

- Any semantics change to State lifecycle, generation prune, slot admission, Deadline/expiry, registry emission order, or Bridge mapping.
- Extracting `CapabilityRegistry` (already separate) or touching Tasks/Settlement/Lifecycle internals.
- Introducing a scheduler protocol, new public API, or new lock domain.
- Reformatting or renaming beyond the mechanical file move.

## Further Notes

- Grill verdict (grill-with-docs, autonomous): PARK. Cut-now was rejected — spelling-only files would triple the hop for every lock-order review for no current friction, while generation prune churn has only just settled with shared-slot coupling still adjacent.
- Seam placement if triggered: `DynamicStore+State.swift` (facade ~270 stays in `DynamicStore.swift`) + `DynamicStore+Generations.swift`; each new file opens with the lock-order contract comment.
- Source of prototype decisions: none — no prototype; decisions derive from ADR-0025/0026 and the current 458-line file (facade ~271 + State ~86 + generations ~99).
