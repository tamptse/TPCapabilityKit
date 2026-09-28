## Problem Statement

The ObjC consumer faces two scheduling doors that promise the same two fire entries: the Bridge object exposes check-and-run (`runTask`) plus schedule-and-wait (`runTaskWhenAvailable`) directly, while the `taskScheduler` live view exposes the same pair (`runIfAvailable`, `runWhenAvailable`/`scheduleAndWait`). A reviewer asking "which door is canonical, and do sync fire and wait-then-run agree?" must bounce across three modules — Bridge door to view door to Store facade — to prove one answer, and each hop is drift risk: the Bridge `runTask` is a one-line adapter over the view's `runIfAvailable` (so shallow it survives deletion), three spellings of the same two entries each restate the bypass-Lease/slot-admission/Deadline contract in their own words, the view is allocated fresh and stateless on every access with no statement of why freshness is safe, and the sample still calls the deprecated Store `runTask`, teaching the old door.

## Solution

Crown the `taskScheduler` live view as the single scheduling adapter: every ObjC scheduling call — sync fire, wait-then-run, schedule, cancel, counts — crosses the view, which owns descriptor building, timeout compat, queue hopping, and defaults with one delivery story. Demote the Bridge-level `runTask`/`runTaskWhenAvailable` to deprecated forwarders that delegate to the view with no policy of their own, unify `runWhenAvailable` plus `scheduleAndWait` on the single `waitThenRun` delivery core with one contract comment, and migrate the sample off the deprecated entry onto the view. No behavior change: sync fire stays synchronous and bypasses Lease/slot/Deadline by contract; wait-then-run keeps the one Tasks waiter with identical delivery.

## User Stories

1. As an ObjC consumer, I want one scheduling door (`taskScheduler` live view) to learn, so that I never choose between two same-named fire entries.
2. As an ObjC consumer, I want sync check-and-run on the view, so that capability-gated fire stays synchronous without awaiting.
3. As an ObjC consumer, I want wait-then-run on the view with timeout plus delivery-queue completion, so that capability arrival resolves through the one Tasks waiter.
4. As an ObjC consumer, I want existing Bridge-level calls to keep compiling with a deprecation nudge toward the view, so that migration is mechanical not flag-day.
5. As a bridge maintainer, I want the bypass-Lease/slot-admission/Deadline contract stated once beside the single core, so that three paraphrases cannot drift apart.
6. As a bridge maintainer, I want `runWhenAvailable` and `scheduleAndWait` sharing one delivery core, so that descriptor building and completion hopping agree by construction.
7. As a bridge maintainer, I want the Bridge doors to hold zero scheduling policy, so that descriptor building, timeout compat, and queue hopping live only in the view.
8. As a bridge maintainer, I want the fresh-per-access stateless view allocation stated as the safe default, so that no caller caches a stale scheduler.
9. As a Store consumer, I want the two-entry fire table (sync `runIfAvailable` vs async `scheduleTaskAndWait`) readable in one hop, so that the view's agreement claim is checkable.
10. As a sample reader, I want the sample to demonstrate the view door only, so that no deprecated entry is taught as current.
11. As a test author, I want door agreement asserted through public Bridge/view behavior, so that the crowning is proven by fire parity not by forwarder spelling.
12. As a future contributor, I want the deprecated Bridge doors gone at rest (remove after migration window), so that no second door can be re-imported.
13. As an ADR reader, I want the change traceable to the single-adapter and single-view promises, so that the crowning clearly completes prior decisions rather than reopening them.

## Implementation Decisions

- **Module**: the Bridge view remains the single scheduling adapter behind the Bridge; the Bridge object keeps state, capability, and subscription APIs plus deprecated forwarders only. No new module is introduced; the Store facade keeps the two documented fire entries with the deprecated legacy entry untouched by this change.
- **Interface**: the view seam (sync fire, wait-then-run pair, schedule, cancel, pending/active counts) is unchanged and becomes the only documented ObjC scheduling seam. The Bridge-level pair keeps its signature during migration as deprecated forwarders, then is removed at rest — expand-contract, never a flag-day break.
- **Depth**: depth decreases by one door. The one-line Bridge-over-view adapter is deleted as policy (forwarder keeps delegation only); `runWhenAvailable` stops building its own wait path and shares the single delivery core with `scheduleAndWait`.
- **Seam**: the highest seam stays the Bridge view plus the Store scheduling facade. Tests cross that seam; no new seam is created. The private scheduler instance stays hidden behind the Store facade per the no-protocol variation rule.
- **Adapter**: the view stays a thin translator (capability translation, descriptor assembly, completion-queue hopping); the Bridge forwarders gain no timeout, descriptor, or delivery policy. Timeout resolution locality is owned by the companion timeout-locality change (external blocker, recommended first) — this change moves no timeout semantics.
- **Locality**: the bypass-Lease/slot-admission/Deadline contract is stated once beside the single delivery core and referenced (not restated) by the forwarder and sync entries, so sync-vs-wait agreement reviews without hopping three paraphrases.
- **Leverage**: leverage is door locality plus drift removal: one door to audit, one contract to extend, zero cross-door sync. Blast radius is bounded because forwarders delegate without policy, so demotion cannot alter scheduling behavior once both wait spellings share the core.
- **Respects ADRs**: ADR-0003 (exactly one scheduling adapter; duplicate conveniences removed) constrains the crowning to the view; ADR-0016 (all Bridge scheduling crosses the single view with one delivery story) is the promise this change completes; ADR-0002 (no scheduler protocol; vary via Configuration values) forbids introducing a scheduling protocol or second adapter around the view.

## Testing Decisions

- A good test crosses the public Bridge/view seam and asserts externally observable behavior (sync fire returns value when capability present else nil; wait-then-run delivers value on the requested queue, nil on timeout; schedule/cancel/counts agree through either spelling during migration), never the spelling of the forwarder or the absence of a duplicate as an implementation detail — except one mechanical grep proving no second scheduling path or restated contract remains at rest.
- Modules under test: view sync fast-path agreement with Store check-and-run, view wait-then-run agreement across both wait spellings (descriptor-built and capability-built arrive identically), deprecated forwarder parity during migration (same result, same delivery queue), sample door usage.
- Prior art: Bridge single-view suites (view-crossing pins for schedule/wait-then-run/cancel/counts/sync fast-path with continuation rendezvous instead of sleeps), fire-agreement suites (sync-vs-wait parity), timeout-pin suites (wire-negative vs explicit vs pinned-omitted, reconfigure-independence — owned by the companion change, referenced here only for no-regression), scheduler integration suites; the crowning must keep every one green with zero test-semantics edits.

## Out of Scope

- Any change to scheduling semantics (fire-vs-wait contract, Lease lifecycle, slot admission, Deadline/expiry resolution, retry, generation draining, Configuration variation).
- Timeout fork locality itself (resolver ownership, pin constant, display/explicitness readers) — owned by the companion timeout-locality change, noted as an external blocker recommended before implementation.
- Changing view public signatures, delivery-queue defaults, descriptor defaults, capability translation, or priority coercion.
- Touching State creation/observation, registry emission order, whole-set wait, or time adapters.
- Renames beyond the crowning or formatting churn.

## Further Notes

- Grill record (simulated `/grill-with-docs`, autonomous — no prototype, decisions derive from the door inventory plus ADR-0003/0016/0002):
  - Q: Why crown the view instead of the Bridge object? A: The view already mirrors the Store facade seam (schedule/wait/cancel/counts) and owns descriptor building plus delivery; the Bridge object door is the one-line shallow adapter, so crowning the object would move policy upward against ADR-0016.
  - Q: Why deprecate rather than delete the Bridge doors immediately? A: Expand-contract keeps ObjC callers compiling; deletion passes today only because the adapter is shallow, but external callers need the migration window — remove at rest.
  - Q: Why keep fresh-per-access view allocation? A: The view holds no queue or count state (every read delegates live), so freshness is the no-stale-cache default; caching would add identity without benefit.
  - Q: Where does the bypass contract live at rest? A: Once, beside the single delivery core / two-entry table; every other spelling references it instead of restating.
  - Q: What about the sample's deprecated `runTask` call? A: Migrated to the view door inside this change so the sample teaches the crowned door; the deprecated Store entry itself is untouched.
  - Q: Ordering vs the timeout-locality companion (N2)? A: N2 first is recommended: both changes touch the view's wait path, and timeout-reader locality lands cleaner before the wait-core unify re-states the contract once.
- Dependency: N2 (bridge timeout locality) is an external blocker — recommended before implementation, not implemented here.
- Source of prototype decisions: none — no prototype; decisions derive from the two-door/three-spelling inventory and ADR-0003/0016/0002.
