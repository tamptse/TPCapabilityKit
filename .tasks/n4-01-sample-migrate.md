# N4-01: Migrate sample and callers to documented fire entries

**What to build:** Every demo and remaining caller uses only the two documented fire entries — sync check-and-run for point-in-time execution, schedule-and-wait (or its single-capability convenience) for queued waiting — while the legacy alias still exists, so behavior is pinned before removal.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] Sample demos and usage docs call only sync check-and-run or the waiter/convenience; no demo exercises the legacy spelling
- [ ] Test callers of the legacy spelling migrated to the matching entry with identical observable outcomes (ran vs nil, waited vs immediate)
- [ ] Full suite green with the legacy alias still present but unreferenced outside its definition
