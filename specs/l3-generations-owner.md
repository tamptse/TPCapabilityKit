# L3 — Generations owner injection + scheduler narrow seam

## Problem Statement
`StoreSchedulingGenerations` is owned by Store yet every call threads `owner: DynamicStore` (`current`, `reconfigure`, `enableDeterministicTime`). `scheduler` exposes whole `TaskScheduler`, letting Fire bypass the facade. Deterministic gate spreads across facade/generations/Clock.

## Solution
Inject `owner` once at generations construction; drop per-call `owner` params. Hide `scheduler` behind narrow scheduling seam (schedule/cancel/counts only); Fire funnels internally. Keep deterministic gate in one place (generations emptiness + Clock enable-once), blocked by L1 adapter split.

## User Stories
1. As a Store author, I want generations to own its scheduler factory, so that call sites pass no owner.
2. As a Fire author, I want a narrow scheduling seam, so that I cannot bypass slot/settlement.
3. As a test author, I want deterministic gate on fresh instances only, so that shared singleton never crashes.

## Implementation Decisions
- Module: Store owns generations; generations owns scheduler factory closure + shared slots + shared clock (per CONTEXT reconfigure-drains + shared-domain).
- Interface: `init(owner:configuration:clock:)` captures owner; `current()`, `reconfigure(_:)`, `enableDeterministicTime()` take no owner. Remove public `scheduler` exposure; keep `schedule/cancel/pending/active/configure` facade.
- Preserve reconfigure semantics: old generation drains, new work on new, counts sum, slot domain shared (ADR-0021). No Store-to-Tasks lock-order change (ADR-0022).
- Grill (auto): factory closure over direct Store ref to avoid retain cycle (weak where hook needs); precondition messages unchanged.
- Blocked by L1 (deterministic rendezvous must be off prod Clock first).

## Testing Decisions
- External: reconfigure preserves in-flight, counts sum, deterministic precede-first-use preconditions, Fire still agrees. Prior art: generations/drain/reconfigure tests.
- Full suite green.

## Out of Scope
- Clock VirtualTime logic, registry wait, settlement vocab, Bridge.

## Further Notes
- Sequential after L1. File-local change; no public Store API shape change.
