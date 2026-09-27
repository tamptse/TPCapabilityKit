## Problem Statement

The State creation rendezvous behind the Store seam wakes globally for a
per-Plugin interest: one creation counter plus one creation-notice broadcast
wakes every pending observer on every creation, and each woken observer
re-checks the per-Plugin subject index through a filter plus re-lookup plus
first-hit chain, keeping only the matching id and going back to sleep for the
rest. A reviewer answering "how does an observe-before-create subscriber meet
its subject, and why can't id A wake id B?" must hold three pieces together
(counter, broadcast, index) to prove isolation by re-check rather than by
construction. No behavior bug is alleged — the no-create contract holds, the
lifecycle and isolation suites are green — but the rendezvous scales wake-ups
with unrelated creations, and the late-subscriber proof (notice-before-value,
replay, re-lookup) reads as broadcast mechanics instead of per-identity
mechanics.

## Solution

Keep every lifecycle contract exactly and move the rendezvous from a global
clock to a per-identity waiter table with targeted wake-up and zero semantic
change. The State owner keeps one creation seam (lookup-or-await-creation)
with the same two callers (writer get-or-creates, observer looks-up-or-parks);
only the waiting mechanics change: an observer parks on its own Plugin
identity, a writer drains only its own identity's parkers, and the global
counter plus global broadcast are deleted. Isolation becomes structural — an
id-A creation has no path to an id-B waiter — instead of a per-notice
re-check. The late-subscriber proof is restated once at the drain site.
Observable behavior through the Store facade stays identical.

## User Stories

1. As a Plugin author subscribing before any writer has created my Plugin
   state, I want my subscription to receive the first write, so that
   observe-before-create keeps working exactly as today.
2. As a Plugin author writing state, I want my write to get-or-create the
   per-Plugin subject and wake only my identity's pending subscribers, so
   that early and late subscribers converge on the same value without
   waking unrelated ids.
3. As a Plugin author observing a Plugin id that is never created, I want my
   subscription to stay pending without creating visible state, so that
   observation alone never creates.
4. As a Plugin author parking beside observers of other ids, I want their
   creations to never resolve, disturb, or complete my waiter, so that
   isolation holds by construction rather than by re-check.
5. As a Plugin author holding a subscription across removal, I want removal
   to complete my detached subscription, so that I am never silently stalled
   on a dead subject.
6. As a Plugin author parked before creation when a removal races in, I want
   the remove-before-create to stay a no-op for my waiter and the next write
   to still resolve me, so that removal never steals a pending rendezvous.
7. As a Plugin author re-subscribing after removal plus a fresh write, I want
   to observe the fresh subject's value, so that removal-then-recreate reads
   as a new lifecycle rather than a resurrected one.
8. As a Plugin author cancelling a pending observation, I want cancellation
   to drop my waiter silently with no leak and no effect on survivors, so
   that parking has no lifetime cost.
9. As a Plugin author observing with the wrong type, I want to receive
   nothing (rather than a crash or a phantom creation), so that the typed
   observation edge stays safe.
10. As a Plugin author passing an empty Plugin id, I want writes and removals
    to no-op, reads to return nil, and observations to complete immediately,
    so that invalid usage fails closed at the owner seam.
11. As a State maintainer, I want exactly one creation seam plus one waiter
    table to audit for the lookup-park-drain rule, so that the next
    lifecycle change has one place to review instead of a counter plus a
    broadcast plus an index.
12. As a State maintainer, I want the per-notice filter plus re-lookup plus
    first-hit chain gone, so that no second copy-pasted waiter can drift out
    of sync with the drain.
13. As a reviewer, I want the late-subscriber proof stated once at the drain
    (lookup-before-park, insert-before-drain, resolve-with-value ordering),
    so that losslessness no longer reads as broadcast mechanics.
14. As a test author, I want all coverage to cross the public Store facade
    seam, so that this mechanism change breaks zero tests by construction
    and proves itself by lifecycle behavior, not by table spelling.
15. As a future splitter under the colocation-park trigger, I want the waiter
    table to travel with the State owner, so that a triggered cut is a pure
    move with no design debate about where the rendezvous belongs.
16. As a Tasks integrator, I want generation prune, slot admission, park,
    Deadline, activation, and settlement untouched, so that this candidate
    cannot leak into scheduling behavior.
17. As a Bridge consumer, I want no mapping or timeout behavior change, so
    that this mechanism change stays invisible from Objective-C.

## Implementation Decisions

- **Module**: the Store module remains the sole public interface; the waiter
  table is private mechanics of the State owner, not a new module and not a
  facade-level API. No public signature changes.
- **Interface**: the Store public seam is unchanged (register/update/get/
  observe/remove state). The State owner seam keeps its existing shape
  (update/get/remove/observe); the internal creation seam keeps its two
  callers (writer get-or-create, observer lookup-or-park) while its waiting
  mechanics change from global-notice to per-identity drain.
- **Seam**: the highest seam stays the Store facade. The creation seam is
  still the single internal seam for lookup-or-await; tests and the Bridge
  continue to cross only the facade. No new seam is created.
- **Adapter**: no adapter change. The Bridge and Tasks cross only the Store
  facade; deterministic-time spelling and registry wait seams are untouched.
- **Depth**: depth decreases — one fact (per-Plugin creation) previously
  reviewed as two mechanisms (global counter plus broadcast, plus per-Plugin
  index with a re-check chain) now reviews as one (subject index plus waiter
  table with a drain). No new broadcast, no new counter, no new subject type.
- **Leverage**: leverage is targeted wake-up plus isolation by construction:
  one drain list to audit, zero per-notice re-checks to verify, fan-out
  proportional to same-id parkers instead of all parkers. Risk is bounded
  because the lifecycle topology (get-or-create, never-create-on-observe,
  complete-detached-on-remove, fresh-subject-on-next-update) is unchanged;
  only the wake-up address changes.
- **Locality**: the subject index, the waiter table, the park step, and the
  drain step sit adjacent in one helper beside the writer and observer paths,
  so creation reviews in one scroll. Under a triggered colocation-split the
  table travels with the State owner; it never belongs to the facade or the
  scheduling-generations owner. This candidate touches the State region only
  and never the scheduling-generations region.
- **Rendezvous shape** (decision shape only): lookup-hit returns the subject;
  lookup-miss on the writer inserts the subject then drains that identity's
  parkers; lookup-miss on the observer parks on that identity. Drain copies
  the identity's parker list under lock and resolves it after unlock.
- **Late-subscriber proof restated at the drain**: lookup-before-park under
  one lock means a create racing a subscribe lands on existing instead of
  parking stale; insert-before-drain under one lock means a subscribe racing
  a create parks before the drain copies it, so no parker is skipped; waiter
  resolution is emitted adjacent to the subject value publish after unlock,
  so no waiter can sleep through its subject without a replay guard. The
  per-subscription re-entry plus waiter-to-subject switch topology is
  preserved, so the subscribe-racing-create case keeps its existing
  re-lookup guarantee without a global replay.
- **Lock discipline preserved**: the locked section covers only the index
  read-or-insert plus the waiter park-or-drain-list copy; all publishes
  (waiter resolution, subject value) emit after unlock, as today. No caller
  holds a Store lock across a submodule call; the Store-to-Tasks order is
  untouched.
- **Removal interaction preserved out of band**: removal still deletes the
  index entry and completes the detached subject; it does not touch the
  waiter table and publishes no wake-up. Parked waiters therefore survive a
  remove-before-create no-op and resolve on the next creation, while a
  removal racing a creation can never resurrect a stale subject because the
  drain resolves parkers only against the live index entry.
- **Cancellation without leak**: a cancelled parker is dropped without
  resolving and without disturbing survivors; waiter entries for
  never-created ids hold no visible state (reads still return nil). The
  table never becomes a second source of truth for values — the subject
  index stays the only value store.
- **Empty-id guard stays at entry**: validation remains at the State owner
  seam entries (update/get/remove/observe); the creation seam and the table
  assume a validated id and add no second guard.
- **Typed filtering stays at the edge**: type-erased meeting stays inside
  the seam (per-Plugin subject plus waiter table keyed by Plugin id); typed
  filtering stays at the observation edge, outside the seam, unchanged.
- **Rejected alternative (deleted, not deferred)**: a versioned
  creation-notice payload carrying the changed Plugin identity would narrow
  the match predicate but keep the global wake-up — every observer still
  wakes per creation and filters by identity, so fan-out cost and the
  re-check audit remain. Rejected in favor of the table because isolation by
  filter is weaker than isolation by address for the same behavior gain.
- **Respects records**: the State lifecycle record (writers get-or-create,
  observation never creates, removal completes detached, next update makes a
  fresh subject), the Store-to-Tasks lock-order record, the Store colocation
  park record with its pre-drawn seams, and the facade-only test rule all
  constrain this change; none is amended. Glossary vocabulary is used
  throughout (`creation notice`, `waiter table`, `State creation
  rendezvous` qualified against the Tasks result rendezvous); the avoided
  term for State is never used.

## Testing Decisions

- A good test crosses the Store facade seam and asserts externally
  observable behavior (early subscriber receives the late write; unrelated
  creation disturbs nothing; pending subscriber creates no visible state;
  removal completes detached; fresh re-subscribe sees the fresh value;
  cancelled parkers stay silent while survivors resolve), never table
  existence, drain ordering internals, or wake-up counts — except mechanical
  greps proving the global counter plus broadcast spelling is gone and the
  scheduling-generations region is undiffed.
- Modules under test: State lifecycle through the Store facade
  (update/get/observe/remove plus cancellation). Prior art:
  `TPCapabilityKitStateLifecycleTests` — removal-completes-fresh-subject,
  observe-remove-update-delivers, concurrent-rendezvous, never-creates —
  plus `TPCapabilityKitStateWaiterIsolationTests` — distinct-ids isolate,
  remove-noop-before-creation, same-id parkers resolve — plus
  `TPCapabilityKitObservationNarrowingTests` (empty-id and type-narrowing
  arms) establish the through-facade patterns this verification follows.
- New coverage (ticket 02) pins the mechanism change at the facade:
  interleaved same-id and unrelated-id parkers with creations in both
  orders (unrelated waiter stays pending while same-id resolves, then
  resolves on its own creation); remove-before-create no-op with a parker
  present resolving on the next write; park-then-cancel leaving survivors
  resolving and reads nil before creation. Same facade-only style as the
  prior art; no reference to the State owner, the table, or any counter or
  broadcast.
- Verification per ticket: `swift build` green plus full `swift test` green;
  ticket 01 lands with zero test edits (semantics preservation); ticket 02
  lands the new pins green alongside the full suite; ticket 03 greps the
  absence of the old global spelling and the absence of any
  scheduling-generations-region diff.

## Out of Scope

- Any semantic change to the State lifecycle (get-or-create, never-create
  on observe, complete-detached on remove, fresh subject on next update),
  typed filtering, cancellation completion semantics, or empty-id rejection.
- Any change to generation prune, slot admission, park/Deadline/activate/
  settle, registry emission order, whole-set readiness, or Bridge mapping
  and timeout.
- A new public API, a new lock domain, a scheduler protocol, new
  observation granularity, caching of values inside the table, or new
  value storage beside the subject index.
- File split, renames beyond the rendezvous mechanics, reformatting, or
  glossary/ADR edits beyond the records cited above.

## Further Notes

- Self-grill verdict (autonomous self-grill; decided, no questions asked):
  - D5-Q1 Per-identity waiter table versus versioned-notice payload versus
    keep-global-clock? Adopted waiter table. Keep-global preserves the
    thundering herd the candidate exists to remove; versioned-notice keeps
    global wake-up with a narrower predicate, so fan-out and the re-check
    audit survive. The table gives isolation by address for the same
    contracts with one drain to review.
  - D5-Q2 Removal out of band or removal-publishes-wake? Adopted out of
    band preserved: removal deletes the index entry and completes the
    detached subject, never touches the table. A removal wake-up would wake
    parkers for no possible match, and completing parkers on removal would
    steal the observe-remove-update-delivers guarantee.
  - D5-Q3 Where does the late-subscriber proof live now? Adopted restated at
    the drain: lookup-before-park plus insert-before-drain under one lock
    plus resolve-adjacent-to-value after unlock, with per-subscription
    re-entry preserved. The old notice-before-value plus replay-filter
    reading is deleted with the broadcast; no proof lives in callers.
  - D5-Q4 Cancelled parkers leak or explicit drop? Adopted explicit drop
    without resolving and without disturbing survivors; never-created table
    entries hold no visible state. A leak would turn parking into hidden
    retention proportional to churn.
  - D5-Q5 Table as second value store? Rejected. The subject index stays the
    only value store; the table holds waiters only. Storing values in the
    table would fork the get-versus-observe truth.
  - D5-Q6 Terminology collision (`snapshot`, Tasks rendezvous)? Adopted
    glossary-safe spelling: `creation notice` and `waiter table` only, and
    always qualified `State creation rendezvous` versus `Tasks result
    rendezvous`. The two share a shape (await-then-meet) but never a seam.
  - D5-Q7 Expand-contract or single migration? Adopted single migration in
    the State region (ticket 01) because the old broadcast has exactly one
    writer pair and one waiter chain — no external caller reads the counter
    or clock, so no dual-publish phase is needed to stay green; the full
    suite proves preservation.
  - D5-Q8 Touch the scheduling-generations region for lock symmetry? Adopted
    never: the generations owner belongs to its own candidate, and this
    change needs no lock-domain move. Tickets constrain the diff to the
    State region by acceptance criterion.
  - Rejected: global-clock retention, versioned-notice payload, removal
    wake-ups, value-caching table, new public seam.
- Source of prototype decisions: none — no prototype; decisions derive from
  the current State owner implementation, the cited records, and the
  glossary.
- Verdict: Worth — converts global fan-out plus re-check isolation into
  targeted wake-up with isolation by construction for one contained
  mechanism change, and the new pins close the interleaved-id gap the old
  topology could only prove by re-check.
