# 03: Pin place unification through the public scheduling seam

**What to build:** the unified place vocabulary proven by behavior — parked reachability, displacement, cancel-while-parked, wake clearing, order cleanup, and retry — all green through the public schedule/cancel/wait seam, so S3/S5 build on one verified vocabulary.

**Blocked by:** 01 (demote insert, delete dead park overload) and 02 (fold dequeue/wake into transition — pins the finished shape, not the intermediate steps).

**Status:** ready-for-agent

- [ ] Full `swift test` green with zero test-semantics edits across lifecycle table suites, same-id exchange pins, transition suites, path locality proof, determinism suites, and slot-hold suites
- [ ] Behavior pins hold through the public seam: parked reachable with counts agreeing and no execution; double-schedule keeps a single row with displaced expired delivery; cancel-while-parked lands expired once with waiter cancelled and reschedule working; wake clears to activation and re-park behaves; terminal removal cleans order with same-id reschedule; retry restores pending
- [ ] Mechanical greps confirm the end state: insert private with exchange as sole caller, no Task-accepting park overload, every place change through transition plus the insert helper plus the private row-take helper, counts writer called only from table-internal row writes
- [ ] No public seam change: schedule/schedule-and-wait/cancel/pending/active plus result rendezvous and registry whole-set wait behave identically; S3/S5 unblocked
