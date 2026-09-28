# 01: Collapse rendezvous enums and extract the waiter

**What to build:** a single-lock creation rendezvous with one named pending waiter, so observe-before-write resolves through one reviewable helper with lifecycle semantics identical to today.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] Inner `Decision` deleted into the single `CreationRendezvous` (existing/created/pending); locked lookup vs unlocked assembly split stays in one function with no lock held across publisher assembly
- [ ] Pending branch extracted to one named waiter helper (clock-filter + lock-safe re-read + first-semantics); observation path calls it instead of inlining
- [ ] Preserved verbatim: get-or-create writers, observe-never-creates, remove-completes-detached with fresh-subject-after-remove, `Deferred` + `switchToLatest` topology, empty-id rejection, writer impossible arm as assertion
- [ ] Full test suite green with zero test-semantics edits; grep proves no inner `Decision` remains
