# N1-01: Privatize snapshot observation behind whole-set wait

**What to build:** Whole-snapshot observation is no longer reachable outside the waiter; the whole-set wait remains the single whole-set seam with empty and already-satisfied shortcuts plus re-query per emission intact.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] Snapshot observation is private mechanics subscribed only by the whole-set wait implementation
- [ ] Per-capability query plus per-capability observation remain the UI grain; whole-set wait remains the Tasks grain
- [ ] Empty set resolves true without subscribing and already-satisfied resolves true without waiting
- [ ] Per-capability-before-snapshot ordering preserved as observed through public seams
- [ ] Full test suite green without new snapshot-subscribing callers
