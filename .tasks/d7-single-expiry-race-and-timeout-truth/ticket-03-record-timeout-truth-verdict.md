# 03: Record the ObjC single-truth verdict and close the collapse line

**What to build:** the stored-enum collapse line is closed as superseded with the verdict recorded, so a future reader finds one decided answer (single stored optional plus direct derivations; mirror pin standing; no ADR change) instead of an open revert, and the already-satisfied build-path and defaults-core follow-ups are verified closed with no source change.

**Blocked by:** None (can start immediately — Bridge-only verification, independent of the race tickets).

**Status:** ready-for-agent

- [ ] Verdict recorded and visible to future agents: stored-enum line closed as superseded by single stored optional plus direct derivations; mirror pin suite passes unmodified (proving no dual-store was re-landed); omitted-vs-negative-vs-explicit triple unchanged; `@objc` surface frozen; no ADR amendment proposed
- [ ] Build-path unification and single-defaults-core follow-ups verified already-satisfied on this head (shared descriptor-building core; single private construction core) and closed with verification only — no source edits
- [ ] Verify: `swift build` green plus full `swift test` green with zero test edits; no source files modified by this ticket
