# N4-02: Remove legacy fire alias

**What to build:** The legacy async immediate spelling disappears entirely, leaving exactly two public fire ways (sync check-and-run plus async schedule-and-wait with its single-capability convenience) over the one internal core whose bypass contract is stated once.

**Blocked by:** N4-01 (callers migrated first so removal breaks nothing).

**Status:** ready-for-agent

- [ ] Legacy spelling gone with no replacement signature; only sync plus waiter plus convenience remain public
- [ ] Sync still bypasses Lease/slot/expiry by construction while queued waits funnel through the one waiter (slot-pressure divergence holds)
- [ ] Full suite green; no caller references the removed spelling
