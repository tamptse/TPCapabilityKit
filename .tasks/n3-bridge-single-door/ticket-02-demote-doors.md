# 02: Demote Bridge runTask doors to deprecated forwarders; migrate sample

**What to build:** Bridge-level `runTask`/`runTaskWhenAvailable` kept only as deprecated policy-free forwarders to the crowned view, and the sample demonstrating the view door only — so ObjC callers migrate mechanically with no flag-day break.

**Blocked by:** 01 (crown-view).

**Status:** ready-for-agent

- [ ] Bridge-level pair demoted to deprecated forwarders delegating to the view with zero scheduling policy
- [ ] Forwarder parity proven behaviorally (same result, same delivery queue as the view spelling)
- [ ] Sample migrated off the deprecated entry onto the view door; deprecated Store entry itself untouched
- [ ] Full test suite green with zero test-semantics edits
