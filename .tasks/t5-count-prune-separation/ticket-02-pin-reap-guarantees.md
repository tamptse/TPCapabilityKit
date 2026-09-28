# 02: Pin reap guarantees through the facade seam

**What to build:** behavior pins through the public Store scheduling seam proving the named reap pass keeps every count and drain guarantee: sums hold across two live generations under one shared limit, drained generations release so the generation count returns to one after natural drain, reaping is idempotent, and the current generation is never reaped.

**Blocked by:** 01 (Extract named reap pass with lock-safe crossing).

**Status:** ready-for-agent

- [ ] Two-live-generations pin: pending/active sums aggregate across generations while admission shares the one Store-owned domain (reconfigure never doubles the configured limit during drain)
- [ ] Drained-release pin: after in-flight work completes with no further reconfigure, pending/active reach zero and generation count returns to one via the unchanged getter path
- [ ] Reap-safety pins: repeated reads agree exactly (idempotent reap), and reconfiguring over a drained store keeps a single live generation (current-never-reaped)
- [ ] All pins cross the public schedule/reconfigure/count seam asserting observable outcomes only; full `swift test` green with prior suites untouched
