# 02: Additive strict priority validity check

**What to build:** Strict callers can pre-validate a raw ObjC priority through a new additive ObjC-visible check before crossing the Bridge, so bad input can be rejected or fixed caller-side — while lenient callers keep the unchanged coerce-to-normal constructors with no migration.

**Blocked by:** 01 (Warn in DEBUG when priority coercion fires — the valid range must be single-sourced before the check reads it).

**Status:** ready-for-agent

- [ ] New validity check is additive and ObjC-visible; it reports validity only and never coerces, schedules, or stores
- [ ] Check and coercion read one shared range statement — no independent restatement of the boundary that could drift
- [ ] Existing constructors and priority read-back keep signatures and lenient semantics verbatim; ticket-01 DEBUG warning behavior preserved
- [ ] New assertions pin the check through the existing descriptor-observable seam (boundary raws on both sides, agreement between check result and coercion outcome); full `swift test` green with zero edits to existing suites
