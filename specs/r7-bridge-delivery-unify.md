## Problem Statement

The ObjC consumer faces one promised delivery story but two shipped ones. The Bridge view (`taskScheduler` live view) is crowned as the single scheduling adapter with one documented delivery story, yet `schedule` fires its completion on the Tasks execution context with no hop while every value-returning wait (`scheduleAndWait`, `runWhenAvailable` sharing the single `waitThenRun` core) plus both subscription entries (`subscribe`, `subscribeCapability`) hop to the given queue or the main queue through the single given-or-main helper. An ObjC caller cannot predict the thread a completion arrives on without reading two implementations, and the no-hop path is hard to test deterministically.

## Solution

Unify every Bridge completion through the single given-or-main delivery seam, so the adapter ships exactly the story it promises. The `schedule` completion joins the same hop the wait core and the subscription entries already cross; the delivery contract is stated once beside the single core and referenced, not restated, everywhere else. Scheduling semantics do not move: Lease lifecycle, slot admission, Deadline/expiry resolution, retry, cancel, counts, and descriptor/timeout behavior stay identical — only the delivery thread becomes predictable. The Sample stays untouched.

## User Stories

1. As an ObjC consumer, I want every Bridge completion to arrive on the given queue or the main queue, so that I never branch on which entry I called to know my thread.
2. As an ObjC consumer, I want the `schedule` completion to follow the same given-or-main rule as the wait-then-run completions, so that fire-and-forget and wait-then-run agree by construction.
3. As an ObjC consumer, I want an omitted delivery queue to mean the main queue everywhere, so that the default is learnable once.
4. As an ObjC consumer, I want existing `schedule` calls to keep compiling, so that the unify is mechanical not flag-day.
5. As a Bridge maintainer, I want exactly one delivery seam behind the Bridge, so that there is one place to audit and one place to extend.
6. As a Bridge maintainer, I want the delivery contract stated once beside the single core, so that no second paraphrase can drift apart.
7. As a Bridge maintainer, I want the subscription entries to keep crossing the same seam unchanged, so that state and capability observation prove the unify by example.
8. As a Tasks maintainer, I want Lease identity, retry re-queue, Settlement outcome, slot admission, and Deadline expiry untouched, so that delivery unification cannot alter scheduling behavior.
9. As a Store consumer, I want the Swift scheduling facade unchanged, so that Swift callers observe zero behavior delta.
10. As a test author, I want delivery asserted through public Bridge/view behavior on explicit queues, so that the unify is proven by thread behavior not by helper spelling.
11. As a test author, I want deterministic rendezvous instead of sleeps, so that delivery tests are stable under load.
12. As a sample reader, I want the Sample untouched, so that no excluded-target churn masks the product diff.
13. As an ADR reader, I want the change traceable to the single-adapter and single-view promises, so that the unify clearly completes prior decisions rather than reopening them.
14. As a future contributor, I want a mechanical check proving no second delivery path remains at rest, so that no bypass can be re-imported silently.

## Implementation Decisions

- **Module:** the Bridge view remains the single scheduling adapter behind the Bridge; no new module is introduced. The given-or-main helper stays a thin translator-local seam — it gains no scheduling, timeout, descriptor, or retry policy.
- **Interface:** the `schedule` entry joins the given-or-main rule (given queue when supplied, main queue when omitted) and routes its completion through the single delivery seam alongside the wait core and both subscription entries. The wait-then-run pair, subscription entries, cancel, and counts keep their current spellings; any new delivery-queue parameter is additive with an omitted-means-main default so existing callers keep compiling. No Swift Store facade signature changes.
- **Depth:** depth decreases by one delivery story. The no-hop completion path is deleted as a second story; the single seam becomes the only completion path behind the Bridge.
- **Seam:** the highest seam stays the Bridge view plus the Store scheduling facade. The private scheduler instance stays hidden; no new seam is created.
- **Adapter:** the view stays a thin translator (capability translation, descriptor assembly, completion-queue hopping); the unify adds no timeout, descriptor, or delivery-default policy beyond routing through the existing seam.
- **Locality:** the delivery contract (given queue or main when omitted; stated once) lives beside the single delivery core and is referenced, not restated, by the `schedule` entry and the subscription entries, so the whole Bridge delivery story reviews in one hop.
- **Leverage:** leverage is delivery locality plus drift removal: one seam to audit, one contract to extend, zero cross-entry thread sync. Blast radius is bounded because downstream scheduling (Lease lifecycle, Settlement decision, slot release, Deadline race, retry re-queue) runs before delivery, so re-routing the completion hop cannot alter scheduling outcome — only the thread it arrives on.
- **Fallback rejected:** documenting the no-hop path as load-bearing beside the core was considered and rejected — it would enshrine the two-story violation the single-view promise forbids. There is exactly one story at rest.
- **Respects ADRs:** single scheduling adapter (exactly one adapter; duplicate conveniences removed) constrains the unify to the view; single view (every Bridge scheduling call crosses the single view with one documented delivery story) is the promise this change completes; no scheduler protocol (vary via Configuration values) forbids introducing a delivery protocol or second adapter around the view.
- **Respects glossary:** Bridge stays the single scheduling adapter behind the live view; Tasks keeps park, Deadline expiry, activation, and the Settlement step; Lease keeps its lifecycle table; State and Capability observation keep their granularities.

## Testing Decisions

- A good test crosses the public Bridge/view seam and asserts externally observable behavior (completion arrives on the requested queue; omitted queue arrives on the main queue; value, timeout-nil, cancel, and counts agree before and after), never the spelling of the hop or the absence of a duplicate as an implementation detail — except one mechanical check proving no second delivery path remains at rest.
- **Modules under test:** view `schedule` delivery (given queue and omitted-to-main), wait-then-run delivery parity across both wait spellings, subscription delivery as unchanged regression guard, scheduling-behavior invariance (Lease state, cancel, pending/active counts, retry).
- **Prior art:** Bridge single-view suites (view-crossing pins for schedule/wait-then-run/cancel/counts/sync fast-path with continuation rendezvous instead of sleeps), fire-agreement suites (sync-vs-wait parity), scheduler integration suites; the unify must keep every one green with zero test-semantics edits to scheduling outcome — only delivery-thread assertions are new.
- Deterministic rendezvous (continuations, expectation queues) replaces sleeps and polls; queue identity is asserted via the delivering queue, not via timing.

## Out of Scope

- Any change to scheduling semantics (fire-vs-wait contract, Lease lifecycle, slot admission, Deadline/expiry resolution, retry, generation draining, Configuration variation).
- Timeout fork locality, descriptor creation paths, priority coercion, capability translation, or display/explicitness readings.
- Changing Swift Store facade signatures, delivery-queue defaults for Swift callers, descriptor defaults, or time adapters/advance policy.
- Touching State creation/observation, registry emission order, whole-set wait, or settlement internals.
- Any change to the Sample target (slices, sleeps, singletons, documented ObjC-plugin leak) — explicitly non-goal; no harness, no sleep-to-rendezvous migration, no cleanup change.
- Renames beyond the unify or formatting churn.

## Further Notes

- **Grill record (grill-with-docs, autonomous — no prototype, decisions derive from the delivery inventory plus single-adapter/single-view promises and the do-not-deepen Sample rule):**
  - Q: Why unify rather than document no-hop as load-bearing? A: The single-view promise commits to one delivery story; documenting two stories would ratify the violation instead of completing the promise. Unify is the only rest state.
  - Q: Why is this safe if the completion thread changes? A: Scheduling outcome (Lease terminal state, retry, cancel, counts) is decided upstream of delivery; re-routing the hop changes only the arrival thread, which is exactly the unpredictability being fixed. Full suite green proves invariance.
  - Q: Does `schedule` need a queue parameter? A: Only if required to express given-or-main; if added it is additive with omitted-means-main so existing callers keep compiling. Either way every completion crosses the single seam at rest.
  - Q: Why is the helper not a deep module? A: It owns no policy beyond given-or-main hopping; deepening it would add interface without leverage. It stays a thin seam.
  - Q: Why is the Sample explicitly non-goal? A: The Sample is excluded from the product build and governed by its own shallows rule (readability slices only, ObjC-plugin leak documented not worked around); touching it here would mix product delivery semantics with demo churn.
  - Q: What proves no second path at rest? A: One mechanical check that every Bridge completion crosses the single seam, plus behavior pins that schedule and wait-then-run arrive on the asserted queues.
- Dependency: none. Companion timeout-locality work is independent — this change moves no timeout semantics.
- Source of prototype decisions: none — no prototype; decisions derive from the no-hop vs hop inventory and the single-adapter/single-view promises.
