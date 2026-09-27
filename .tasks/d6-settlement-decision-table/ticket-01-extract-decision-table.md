# 01: Extract pure settlement decision table beside the locked apply

**What to build:** the Settlement outcome decision (retry budget check, void-completion policy, cancelled normalization) becomes one pure table beside the single locked row-application step, so decide-then-apply reviews as one table plus one apply span with all scheduling outcomes identical to today.

**Blocked by:** D7 single-expiry race and timeout truth (hard edge — the table consumes the unified raced-decoded input, not the legacy double-optional split between flow decode and settle policy; do not start before D7 lands).

**Status:** ready-for-agent

- [ ] One pure decision table maps the unified raced-decoded input plus the Lease read-only budget view and active-ness to one directive (retry, complete, fail, expire); cancelled normalizes to expired once at the table boundary and the table emits abstract fail with no error mint inside
- [ ] Single locked apply owns the row transition, mints the fresh execution error once on fail, re-queues retries through the same Lease identity, preserves waiters across retry with claim-once terminal delivery, never releases the slot, and re-pumps on retry; inline decide branches deleted so the settle step reads only the named table
- [ ] Settle region plus Lease budget view only — shared-race topology region (D7-owned) and drain/pump region (D4-owned) untouched; `swift build` green and full `swift test` green with zero test-semantics edits
