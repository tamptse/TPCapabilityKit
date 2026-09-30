# N3-02: Collapse probe into true-count rendezvous

**What to build:** Deterministic waiter wait settles through the true waiter registry instead of wall-clock polling, so timing tests rendezvous deterministically with no hidden timeout crash.

**Blocked by:** n3-01 (needs stable test-only seam before changing rendezvous internals).

**Status:** ready-for-agent

- [ ] Probe module removed as independent interface; single test-only rendezvous method on time module reads true waiter count
- [ ] No wall-clock poll loop remains; expired-only wake, no-loss, no-duplicate, and cancel-resume semantics preserved
- [ ] Full suite green; deterministic advance plus single-expiry plus timeout-contract suites prove stable settlement
