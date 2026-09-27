# 03: Flip getters to pure reads fed by reconfigure/settle

**What to build:** getters become pure reads: pending, active, and generation count delegate to the pure view with no drain question and no mutation, and drained generations release only at the explicit reconfigure/settle points fed by the settle/drain notification, with linger-then-release (drained visible until the explicit reap, gone after) pinned as designed behavior.

**Blocked by:** 01, 02, and D4 pump single-drain-owner — requires (a) one reviewable pump drain lifecycle with a single kick entry, (b) a settle/drain notification callable from reconfigure/settle points, (c) the re-proven non-current-generations-drain-monotonically invariant under coalesced pumping. Do not land without all three.

**Status:** ready-for-agent

- [ ] Read-path reap deleted: all three getters read only the pure view; mechanical grep shows no drain-state read and no mutation on the count-read path, and exactly two reap call sites remain (reconfigure plus the settle entry)
- [ ] Linger-then-release pinned through the public scheduling seam (drained generation counted until the explicit reap, released after; steady-state counts at explicit points identical to before); pins that previously relied on getter-triggered release now drive an explicit point — the only permitted test-semantics edits
- [ ] Current-never-reaped, sum-vs-share single statement, precede-first-use gate meaning, cancel fan-out, and Bridge agreement preserved; no drain redefinition, no slot/admission/delivery/expiry change
- [ ] `swift build` green and full `swift test` green; deletion test holds (removing the old read-path reap spelling changes steady-state counts not at all)
