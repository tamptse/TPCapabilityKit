# 02: Collapse the pin duplicate to one owner

**What to build:** exactly one pinned compat literal owned by the timeout form, so no second constant can drift out of sync with the omitted-timeout promise.

**Blocked by:** 01 (delete mapper forwarders; descriptor reads directly).

**Status:** ready-for-agent

- [ ] Single pin constant owned by the timeout form; any mapper spelling aliases it during migration and is removed at rest
- [ ] Omitted call still arrives as the pin literal collapsing to explicit; never follows a reconfigured Swift default
- [ ] Grep evidence: one pin literal definition, no forwarder remains
- [ ] Compat/reconfigure-independence suites green with zero semantics edits
