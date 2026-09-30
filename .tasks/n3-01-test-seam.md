# N3-01: Relocate deterministic trio to test-only seam

**What to build:** Prod scheduling facade exposes only schedule, schedule-and-wait, cancel, and counts; deterministic enable, advance, and waiter-wait cross a test-only seam owned by the time module with identical virtual-time behavior.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] Prod facade interface narrowed to scheduling contract; deterministic trio reachable only through test seam
- [ ] Generations module keeps thin delegation with no deterministic policy of its own; one time instance still shared across live generations
- [ ] Full suite green; deterministic advance plus expiry plus generations drain suites prove no wake or drain drift
