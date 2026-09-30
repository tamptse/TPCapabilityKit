# M4 — Slot eviction handoff pin (no-move plus lock doc)

## Problem Statement

Same-id displacement mints an eviction obligation inside the lifecycle insert, but enforcement lives two hops away in the scheduler delivery path that must remember to notify the slot controller outside both locks, never nested. Forgetting the call leaks a stale waiter; the owning slot tests stay green in isolation, hiding the coupling.

## Solution

Pin the current chain as intentional with no ownership move: insert mints the obligation, the single finish-exchange helper delivers waiters then notes eviction then kicks the pump, the slot controller evicts at most one stale queued waiter keyed by waiter-side index plus owner. Add a three-line lock-order comment at the helper so future waves do not move the note inside the scheduler lock or centralize a second evict path in generations.

## User Stories

1. As a scheduler author, I want exactly one helper to audit for eviction, so that I never wonder which entry forgot the note.
2. As a slot reader, I want stale-only eviction keyed by owner, so that a fresh waiter with the same identifier is never yanked.
3. As a reconfigure reader, I want generations free of evict logic, so that shared-domain drain review stays separate.
4. As a test author, I want the same-id plus slot-pressure matrix green through public seams, so that handoff regressions surface immediately.

## Implementation Decisions

- Module: lifecycle table mints obligation; scheduler helper owns delivery plus note plus kick; slot controller owns stale-only eviction; generations own caps update plus drain reap only, no evict logic.
- Interface: no surface change. Obligation keeps waiter-side identifier plus owner; controller keeps scoped-hold, cancellable wait, scope-exit release, first-fit FIFO with skip.
- Lock order: outside scheduler lock, controller self-locks, waiter delivery outside lock; never holds scheduler lock across delivery or controller calls.
- Note after delivery in the same batch: stale waiter drains before newcomer admission is considered, avoiding flaky keeps-new.
- Fresh identifiers carry no obligation and hit the absent-match no-op; no special-case branch per entry.
- Grill (auto): generations-central deliver rejected (second evict path, double-evict with fan-out cancel); direct table-to-controller call rejected (nested lock plus layering violation); note-before-deliver rejected (stale admits before old settlers); dropping owner field rejected (fresh yank race).

## Testing Decisions

- External behavior only through public schedule seams under slot pressure: stale drained plus newcomer completes; parked cancelled once never runs; no-displacement preserves FIFO; concurrent storm expires all-but-one exactly once.
- Modules: schedule seam plus slot admission seam.
- Prior art: displacement pairing tests, same-id exchange pins, shared-domain tests, fair-wake tests, slot-hold tests.
- Full suite green; no controller or generations surface change.

## Out of Scope

- Moving obligation minting; moving note ownership; generations reap changes; slot admission policy changes; retry or deadline changes.

## Further Notes

- Blocked by M2 then M3 (needs the single helper to exist). Independent of M1/M5/M6/M7. Respects single-settlement, scoped-hold, first-fit FIFO, shared-domain, and lock-order ADRs.
