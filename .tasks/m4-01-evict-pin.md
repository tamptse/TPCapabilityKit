# M4-01: Slot eviction handoff pin

**What to build:** Pin the insert-to-finish-exchange-to-slot-note chain with no ownership move, adding a lock-order comment so future waves keep the note outside the scheduler lock and avoid a second generations evict path.

**Blocked by:** M3-01 Exchange fan-out unify (needs the single helper to exist).

**Status:** ready-for-agent

- [ ] Obligation still minted in insert, noted in the single helper after waiter delivery, evicting at most one stale waiter by identifier plus owner
- [ ] No controller or generations surface change, no retry or deadline change
- [ ] `swift test` green (at least displacement pairing, same-id exchange, shared domain, fair wake plus slot hold)
