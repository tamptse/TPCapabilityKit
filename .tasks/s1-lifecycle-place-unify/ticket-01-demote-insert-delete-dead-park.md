# 01: Demote insert to private exchange helper and delete dead park overload

**What to build:** the standalone insert entry becomes a private helper reachable only from exchange and the uncalled Task-accepting park overload disappears, so the only new-row entry is exchange and the only park entry is the factory park, with zero observable change through the public scheduling seam.

**Blocked by:** None (can start immediately; read the same-id exchange and park-single-seam specs first and keep transition naming consistent with their seams).

**Status:** ready-for-agent

- [ ] Insert demoted to private helper of exchange: no caller outside exchange can install a row; exchange displacement atomicity, settled-then-evicted ordering, and outside-lock delivery unchanged
- [ ] Dead Task-accepting park overload deleted: factory park remains the single park seam with the non-suspending factory constraint under the single lock untouched; no caller migrates because none exists
- [ ] Dequeue-to-parked placement, wake clearing, activation gate, settlement policy, slot admission/release, retry identity, Deadline expiry, registry whole-set wait unchanged; no Lease edit
- [ ] `swift build` green and full `swift test` green with zero test-semantics edits; grep shows insert private with exchange as its only caller and no Task-accepting park overload remaining
