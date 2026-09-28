# 02: Disambiguate rendezvous naming and tidy determinism tests

**What to build:** Each expiry seam names its own role so reviewers never confuse the public synchronization point with the internal registry gate: the adapter-level gate keeps its current spelling, the deterministic-registry-internal rendezvous takes the `awaitWaiterRegistered` spelling, and the determinism tests read cleanly against those names — multi-waiter tests keep their explicit count gate, single-waiter advance keeps its internal gate, all green with zero public spelling churn.

**Blocked by:** 01 (Fold expiry result box to single call site) — lands after the box fold so the expiry review surface changes one at a time.

**Status:** ready-for-agent

- [ ] Registry-internal rendezvous renamed; adapter gate and Store facade spellings unchanged (internal-only blast radius)
- [ ] Internal advance gate still guarantees one waiter parked; callers and tests need no migration
- [ ] Multi-waiter determinism tests keep their explicit count gate (no removal in favor of the internal single-waiter gate)
- [ ] Time-adapter suite (non-positive sleep parity, wake-only-expired advance) and expiry suite pass unchanged
