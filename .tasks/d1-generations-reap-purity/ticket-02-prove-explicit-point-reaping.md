# 02: Prove explicit-point reaping while getters still reap

**What to build:** explicit-point reaping proven reviewable before the flip: reconfigure append-plus-reap and the settle-triggered entry both route to the named pass with pins for release, idempotence, and current-never-reaped, while getters still delegate to the reaping snapshot so every existing suite stays green with zero semantics edits.

**Blocked by:** 01 (needs the pure view and settle entry beside the live path to pin against).

**Status:** ready-for-agent

- [ ] Reconfigure append-plus-reap pinned with in-flight preservation and aggregated counts; settle entry pinned to release a drained non-current generation, to no-op idempotently on repeat, and to never reap the current generation even when drained
- [ ] Precede-first-use gate pinned reading the same numbers; cancel fan-out and Bridge count agreement unchanged; slot admission still on the one shared domain so the configured limit never doubles during drain
- [ ] D4 sequencing note recorded at the settle entry: the entry consumes (not defines) the D4 settle/drain notification and the D4-re-proven monotonic-drain invariant; no pump internals invented
- [ ] `swift build` green and full `swift test` green with zero test-semantics edits (new pins only additive)
