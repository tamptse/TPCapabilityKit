# 01: Extract named reap pass with lock-safe crossing

**What to build:** the anonymous prune hidden inside the generations snapshot becomes one named reap pass that states the Store-to-Tasks order once and asks drain state outside the scheduling lock, with zero observable change through the public scheduling seam (same counts, same reconfigure drain behavior, same deterministic-time gate).

**Blocked by:** None (can start immediately; sequencing note: T2 pump-coalesce owns the drain definition — this ticket must not redefine when a generation counts as drained, only relocate where the question is asked).

**Status:** ready-for-agent

- [ ] One named reap pass owns the only Store-to-Tasks crossing: copy generation list under lock, ask drain state with no scheduling lock held, sweep under lock removing only still-present non-current generations flagged drained; current is never reaped
- [ ] Old anonymous prune spelling deleted: snapshot delegates to the named pass; mechanical grep shows no drain-state read under the scheduling lock outside the pass
- [ ] Module header doc names the reap pass as the single allowed Store-to-Tasks crossing so documentation matches behavior in one place
- [ ] Pending/active/generation-count values, reconfigure append-plus-reap, cancel fan-out, precede-first-use gate, and the sum-vs-share split unchanged; `swift build` green and full `swift test` green with zero test-semantics edits
