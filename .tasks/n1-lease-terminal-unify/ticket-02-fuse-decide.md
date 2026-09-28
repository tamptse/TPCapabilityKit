# 02: Fuse decide into the single row-transition site

**What to build:** the outcome decision (retry vs complete vs fail vs expire, including void-completion policy) reading adjacent to the lifecycle-table transition that applies it, so decide-then-transition reviews as one locked path.

**Blocked by:** 01 (unify terminal vocabulary to one owned type).

**Status:** ready-for-agent

- [ ] `Decision` enum deleted; budget check, void policy, and retry re-queue live inside the single locked settle step
- [ ] Retry re-uses the same Lease identity through the shared re-queue path; waiters preserved across retry, delivered exactly once at terminal
- [ ] Failed-error handling and cancelled-to-expired mapping stated once at the fused site
- [ ] Retry/cancel/timeout/void-completion/waiter suites green with zero semantics edits
