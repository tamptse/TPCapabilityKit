## Problem Statement

The State owner behind the Store seam implements one domain fact — per-Plugin
creation — through two coupled mechanisms: a global creation counter plus a
global creation-notice broadcast, combined with a per-Plugin subject index.
The writer path get-or-creates under lock and publishes the notice after
unlock; the observer path captures the counter under lock, filters the global
broadcast for anything newer, re-looks-up the per-Plugin index on every
notice, and takes the first hit before switching to the subject. A reviewer
trying to answer "how does an observe-before-create subscriber meet its
subject?" must hold all three pieces (counter, broadcast, index) together,
even though the subscriber's interest is per-Plugin while the wake-up is
global: every creation wakes every pending observer only for most of them to
re-check and go back to sleep. No behavior bug is alleged — the no-create
contract holds and the existing lifecycle tests are green — but the State
creation rendezvous carries hidden depth: one creation event reviewed as two
mechanisms with no named seam.

## Solution

Keep the no-create contract exactly and give the rendezvous one named seam
with zero semantic change. Extract a single State-owned creation seam
(lookup-or-await-creation) so the writer path and the observer path become
two callers of the same seam instead of two independent implementations of
the same idea. The mechanism is preserved: global creation notice plus
per-Plugin index lookup, first-hit plus switch-to-subject topology
unchanged. The wider redesign (a versioned creation-notice payload carrying
the changed Plugin identity) is explicitly deferred — it would widen the
blast radius for no behavior gain today. Observable behavior through the
Store facade stays identical.

## User Stories

1. As a Plugin author subscribing before any writer has created my Plugin
   state, I want my subscription to receive the first write, so that
   observe-before-create keeps working exactly as today.
2. As a Plugin author writing state, I want my write to get-or-create the
   per-Plugin subject and wake pending subscribers, so that late subscribers
   and early subscribers converge on the same value.
3. As a Plugin author observing a Plugin id that is never created, I want my
   subscription to stay pending without creating visible state, so that
   observation alone never creates.
4. As a Plugin author holding a subscription across removal, I want removal
   to complete my detached subscription, so that I am never silently stalled
   on a dead subject.
5. As a Plugin author re-subscribing after removal plus a fresh write, I want
   to observe the fresh subject's value, so that removal-then-recreate reads
   as a new lifecycle rather than a resurrected one.
6. As a Plugin author observing with the wrong type, I want to receive
   nothing (rather than a crash or a phantom creation), so that the typed
   observation edge stays safe.
7. As a Plugin author passing an empty Plugin id, I want writes and removals
   to no-op, reads to return nil, and observations to complete immediately,
   so that invalid usage fails closed at the owner seam.
8. As a State maintainer, I want exactly one creation seam to audit for the
   lookup-or-await rule, so that the next lifecycle change has one place to
   review instead of two coupled mechanisms.
9. As a State maintainer, I want the writer and the observer to read as two
   callers of that seam, so that a change to creation semantics cannot land
   in one path and be forgotten in the other.
10. As a reviewer, I want the global-wake plus per-Plugin re-check to read as
    one documented rendezvous (wake globally, match per Plugin), so that the
    broadcast fan-out no longer looks like an accident.
11. As a test author, I want all coverage to cross the public Store facade
    seam, so that this refactor breaks zero tests by construction and a
    future mechanical split stays unobservable.
12. As a future splitter under the C1 trigger, I want the creation seam to
    travel with the State owner, so that a triggered cut is a pure move with
    no design debate about where the helper belongs.
13. As a Tasks integrator, I want generation prune, slot admission, park,
    Deadline, activation, and settlement untouched, so that this candidate
    cannot leak into scheduling behavior.
14. As a Bridge consumer, I want no mapping or timeout behavior change, so
    that this refactor stays invisible from Objective-C.

## Implementation Decisions

- **Module**: the Store module remains the sole public interface; the
  creation seam is an internal State-owned helper, not a new module and not
  a facade-level API. No public signature changes.
- **Interface**: the Store public seam is unchanged (register/update/get/
  observe/remove state). The State owner seam keeps its existing shape
  (update/get/remove/observe); the new helper is private to the State owner
  and called only from the writer and observer paths.
- **Depth**: no depth change — the extraction removes apparent depth (two
  implementations of one idea) without adding abstraction. The helper names
  the seam that already exists implicitly; it introduces no new broadcast,
  no new counter, and no new subject type.
- **Seam**: the highest seam stays the Store facade. The creation seam is
  the single internal seam for lookup-or-await: the writer calls it for
  get-or-create, the observer calls it for lookup-or-await. Tests and the
  Bridge continue to cross only the facade.
- **Creation semantics preserved**: type-erased matching stays inside the
  seam (per-Plugin subject index keyed by Plugin id); typed filtering stays
  at the observation edge, outside the seam. The global-wake plus
  per-Plugin re-check topology (capture notice generation under lock,
  await newer notices, re-look-up the index per notice, take the first hit,
  switch to the subject) is preserved verbatim — only its spelling moves
  behind the helper.
- **Lock discipline preserved**: the locked section covers only the
  index/counter read (and, on the writer, the index insert); all publishes
  (creation notice, subject value) are emitted after unlock, as today. No
  caller holds a Store lock across a submodule call; the Store→Tasks order
  is untouched.
- **Removal interaction preserved**: removal still deletes the index entry
  and completes the detached subject; it does not touch the creation
  notice. The await path re-checks the index after every notice, so a
  notice for an unrelated Plugin id, or a removal racing a creation, can
  never resurrect a stale subject.
- **Empty-id guard stays at entry**: validation remains at the State owner
  seam entries (update/get/remove/observe); the helper assumes a validated
  id and adds no second guard.
- **Locality**: the helper lives colocated with the State owner it serves,
  adjacent to the writer and observer paths, so creation reviews in one
  scroll. Under a triggered C1 split it travels with the State owner (see
  Further Notes); it never belongs to the facade or the generations owner.
- **Rejected alternative (deferred, not deleted)**: a versioned
  creation-notice payload carrying the changed Plugin identity would narrow
  the wake-up from global to targeted, but it changes the broadcast shape
  for zero behavior gain today and collides with the glossary avoidance of
  the snapshot term for State. Deferred until measured fan-out pressure or
  a second creation consumer appears; the helper extraction keeps that door
  open by giving the redesign exactly one call site pair to change.
- **Respects records**: the State lifecycle record (writers get-or-create,
  observation never creates, removal completes detached, next update makes
  a fresh subject), the Store→Tasks lock-order record, the Store colocation
  park record with its pre-drawn seams, and the C1 facade-only test rule
  all constrain this change; none is amended.

## Testing Decisions

- A good test crosses the Store facade seam and asserts externally
  observable behavior (early subscriber receives the late write; pending
  subscriber creates no visible state; removal completes detached; fresh
  re-subscribe sees the fresh value), never helper existence, counter
  values, or broadcast topology.
- Modules under test: State lifecycle through the Store facade
  (update/get/observe/remove). Prior art:
  `TPCapabilityKitStateLifecycleTests` — removal-completes-fresh-subject,
  observe-remove-update-delivers, observation-alone-never-creates —
  establishes the through-facade patterns this verification follows.
- New coverage (ticket 02) adds the missing concurrent
  observe-before-update rendezvous proof: multiple facade-level observers
  attached before any write all receive the single subsequent write, plus
  the no-create invariant re-asserted around them. It uses the same
  facade-only style as the prior art; no direct references to the State
  owner or the helper.
- Verification: `swift build` green plus the State lifecycle suite green
  after the extraction with zero test edits (ticket 01 proves
  semantics-preservation); then the new rendezvous test green alongside
  the full suite green (ticket 02). Search confirms no test references the
  State owner or the helper directly.

## Out of Scope

- Any semantic change to the State lifecycle (get-or-create, never-create
  on observe, complete-detached on remove, fresh subject on next update),
  typed filtering, or empty-id rejection.
- Any change to generation prune, slot admission, park/Deadline/activate/
  settle, registry emission order, whole-set readiness, or Bridge mapping.
- The deferred versioned-notice payload redesign, new public API, new lock
  domain, scheduler protocol, or new observation granularity.
- Reformatting, renaming beyond the extraction, or glossary/ADR edits
  beyond the records cited above.

## Further Notes

- Grill record (grill-with-docs, autonomous self-grill; all open questions
  resolved by the refining agent, recommendations adopted):
  - Round 1, Q1 — Is the no-create contract negotiable? No: it is load-
    bearing per the State lifecycle record, the domain glossary, the C1
    park story, and the observation-alone-never-creates test. The fix must
    preserve it exactly. Adopted.
  - Round 1, Q2 — What is the actual hidden depth? One fact (per-Plugin
    creation) reviewed as two mechanisms (global counter + global
    broadcast + per-Plugin index with no named seam). The observer's
    capture-filter-relookup-first-switch chain is the symptom, not a
    second feature. Adopted.
  - Round 1, Q3 — Helper extraction now versus versioned-notice redesign
    now? Extraction now: same mechanism behind one named seam, minimal
    diff, zero topology change; redesign deferred for blast-radius reasons
    and the glossary snapshot-term collision. Adopted.
  - Round 1, Q4 — Where does the helper live? State-owner scope,
    colocated, per the C1 park: if the C1 split trigger fires, it travels
    with the State split file, never the facade or generations. Adopted.
  - Round 1, Q5 — Lock-scope risk from the extraction? None: locked work
    stays lookup-or-insert plus counter read; all publishes stay after
    unlock; verified by keeping the before/after lock boundaries textually
    identical. Adopted.
  - Round 2 (domain-modeling pass), Q6 — "Snapshot" for the redesign?
    Rejected as a term: the State glossary explicitly avoids snapshot, so
    the deferred design is recorded as "versioned creation-notice payload",
    and today's mechanism as "global creation notice + per-Plugin index".
    Adopted with glossary vocabulary used throughout this spec.
  - Round 2, Q7 — "Rendezvous" collision with the Tasks result rendezvous?
    Resolved by qualification: this spec always says "State creation
    rendezvous" where Tasks says "Tasks result rendezvous"; the two share
    a shape (await-then-meet) but never a seam. Adopted.
  - Round 2, Q8 — Does removal need to publish a creation notice? No:
    removal completes the detached subject and deletes the index entry;
    the await path's per-notice re-check already prevents resurrection,
    and a removal notice would wake sleepers for no possible match.
    Adopted.
- C1 placement mapping: this spec states placement as State-owner scope;
  concretely, under a triggered C1 cut the helper lands in the State split
  file alongside the writer and observer paths, with the lock-order
  contract header duplicated per the C1 rule. No move happens in this
  candidate.
- Source of prototype decisions: none — no prototype; decisions derive
  from the current State owner implementation, the cited records, and the
  glossary.
- Verdict: Worth — the extraction converts unreviewable coupling into one
  named seam for near-zero risk, and the rendezvous test closes the only
  lifecycle concurrency gap without touching any other domain.
