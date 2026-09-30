# 02: Lifecycle single insert seam + counts assert

**What to build:** Fuse exchange-forwarder into single locked insert seam and localize counts with a DEBUG invariant over rows/queues/snapshot.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] No `exchange` forwarder; callers use single insert seam, same-id displace still terminalizes old
- [ ] Counts stay O(1) incremental with debugInvariant asserting agreement after mutations
- [ ] `swift test` green (lifecycle/park/dequeue subsets + full at end)
