# 01: Unify terminal vocabulary to one owned type

**What to build:** one Terminal vocabulary for the Lease lifecycle so reviewers read completed/failed/expired once instead of reconciling four enums, with no behavior change.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] Single Terminal type owned by one side (Lease side preferred); the other spelling kept only as a typealias during migration
- [ ] All Settlement/Terminal/Decision terminal cases spell through the unified vocabulary; public `State` seam unchanged
- [ ] Cancelled stays input-only mapping explicitly to expired at the single site
- [ ] Full test suite green with zero test-semantics edits
