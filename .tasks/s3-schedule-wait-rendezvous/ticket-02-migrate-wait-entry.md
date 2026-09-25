# 02: Migrate schedule-and-wait entry to the single rendezvous seam

**What to build:** the schedule-and-wait entry crossing the fused rendezvous once, so the two-lock insert-then-attach protocol plus the wedged gap disappear from the entry with wait behavior identical to today.

**Blocked by:** 01 (fuse table-owned enqueue-and-park rendezvous beside legacy).

**Status:** ready-for-agent

- [ ] Schedule-and-wait entry hands new-lease intent with its continuation waiter through the fused transition in one scheduler-lock crossing: parked pumps the pending path, settled-early resumes immediately with the returned settled lease without pumping and without attaching elsewhere
- [ ] Entry keeps result-shaping only (completed resumes with the typed value, every other terminal resumes nil); no identity-guard or settled-early patch logic remains in the entry
- [ ] Legacy standalone attach-after-enqueue spelling deleted from the entry; mechanical check proves no caller-side attach protocol remains and no park-fusion or exchange seam renamed or re-spelled
- [ ] Fire-and-forget schedule path, cancel path, deadline expiry, registry wait value-passing, activation, settlement, slot scope-exit, retry identity unchanged; no lease-shape edit
- [ ] Build green and full test suite green with zero test-semantics edits
