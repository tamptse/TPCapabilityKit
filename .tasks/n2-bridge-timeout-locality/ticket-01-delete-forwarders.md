# 01: Delete mapper forwarders; descriptor reads directly

**What to build:** descriptor display/explicitness readings going straight to the timeout form with no mapper hop, so the fork reads in one locality with no behavior change.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] Mapper display/explicitness forwarders deleted; descriptor `timeout`/`hasExplicitTimeout` read directly off the stored timeout form
- [ ] Mapper keeps capability/priority/descriptor assembly unchanged; Bridge view stays a thin translator
- [ ] Wire-to-domain behavior identical (wire-negative→unspecified, non-negative→explicit, display fallback, explicitness flag)
- [ ] Full test suite green with zero test-semantics edits
