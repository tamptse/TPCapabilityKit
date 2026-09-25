# 01: Carry the evict obligation in the exchange result and drain it in the funnel

**What to build:** the displacement-to-evict pairing made unforgetable: the table-owned exchange result carries the stale-evict obligation exactly when a non-terminal occupant was displaced, and a Tasks-owned drain step consumes it right after the row lock releases, so every displacement evicts once and every non-displacement evicts nothing. The unconditional stale-evict on every enqueue is deleted. The slot eviction primitive, admission, FIFO wake, cancellable wait, scope-exit release, settlement ordering, park handling, and lock discipline are behavior-identical.

**Blocked by:** None (can start immediately; assumes the fused exchange plus fused waiter-eviction post-state. Coordinate with the sibling enqueue-touching candidate so only one moves the funnel at a time — this ticket rebases onto whichever funnel lands first).

**Status:** ready-for-agent

- [ ] Exchange result carries evict obligation present iff a non-terminal occupant was displaced (fresh id and terminal reuse yield no obligation); Tasks-owned drain consumes it via the existing stale intent with the newcomer identity, after the row lock releases and never nested with the slot lock
- [ ] Unconditional stale-evict on the non-displaced path deleted; settle-first ordering preserved (stale resume lands on an already-terminal lease); waiter delivery plus park-waiter cancellation stay outside both locks; slot primitive untouched
- [ ] Overwrite still expires old exactly once with new completing, sequential reuse works, FIFO order plus counts agree, retry identity and schedule-wait guard unchanged
- [ ] `swift build` green and full `swift test` green with zero test-semantics edits; mechanical check shows no bare exchange without an evict drain and no unconditional stale-evict in the funnel
