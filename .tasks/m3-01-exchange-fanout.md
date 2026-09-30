# M3-01: Exchange fan-out unify

**What to build:** Keep plain insert canonical, wrap wait rendezvous around it without field mirroring, and funnel both schedule entries through one finish-exchange helper delivering displaced waiters plus eviction note plus pump kick outside the lock.

**Blocked by:** M2-01 Lifecycle ordering extract (needs stable exchange shape).

**Status:** ready-for-agent

- [ ] Wait wrapper guards terminal identity, delegates to insert, re-guards freshness, wraps canonical result
- [ ] Both schedule entries share one tail with no duplicate deliver-plus-kick and no lock held across delivery
- [ ] `swift test` green (at least same-id exchange, displacement pairing, fire agreement, rendezvous plus retry identity untouched)
