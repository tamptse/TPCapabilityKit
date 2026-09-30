# N2-01: Add identifier-keyed detach seam with thin forwarder

**What to build:** Detach by identifier string works end to end with state cleared plus capability row detached; the existing plugin-shaped detach keeps working by extracting the identifier and delegating, with identical observable behaviour including the empty-identifier no-op.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] Detach by identifier clears state with detached-subscriber completion and fresh-subject postcondition
- [ ] Detach by identifier clears capability row plus reverse-index entries
- [ ] Plugin-shaped detach and identifier-shaped detach agree on all observable outcomes
- [ ] Empty identifier stays observably identical to no-op on both entries
- [ ] Detach never provisions capabilities and runs no start side effect
- [ ] Full test suite green
