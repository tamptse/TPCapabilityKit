# 03: Single defaults source behind both descriptor constructors

**What to build:** Both descriptor entries delegate to one private construction core that owns every default: the auto-id and client-id constructors keep their current `@objc` signatures verbatim but forward to the core, so priority, omitted-timeout pin, retry count, and metadata defaults cannot diverge silently while ObjC call sites see zero churn.

**Blocked by:** 02 (Route run-when-available through the shared descriptor-building core) — lands last so defaults consolidation reviews against the already-unified build path.

**Status:** already-satisfied-on-HEAD (self-grill 2026-09-27: single private init core already owns resolve+build; c6 CLOSE per specs/FAILURES.md 2026-09-26 entry)

- [ ] One private construction core owns all defaults; both `@objc` constructors delegate to it with no duplicated default literals in logic
- [ ] `@objc` signatures frozen (both constructors keep current selectors and default spellings; live-view wrap of a Swift-nil descriptor preserved with identity intact)
- [ ] Auto-id vs client-id agreement holds: same capabilities, same coerced priority, same timeout triple, same retries and metadata; client-id identity still survives the round-trip
- [ ] Full `swift test` green with zero test edits; omitted-pinned-regardless-of-default and client-id suites confirm the pin still ignores reconfigured defaults
