# N1-02: Migrate snapshot tests to waiter plus query

**What to build:** Every existing snapshot-subscribing verification now proves the same behaviour through the whole-set waiter plus per-capability query and observation, so the suite pins only supported grains.

**Blocked by:** N1-01 privatize snapshot observation behind whole-set wait

**Status:** ready-for-agent

- [ ] No test subscribes to whole-snapshot observation directly
- [ ] Ordering, empty, already-satisfied, multi-capability simultaneity, and expiry-win pinned via waiter plus query forms
- [ ] Reentrant queries from sinks stay safe under migrated forms
- [ ] Full test suite green
