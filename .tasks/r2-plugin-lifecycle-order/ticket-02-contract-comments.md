# 02: State lifecycle contract once beside lock-order

**What to build:** a single lifecycle-order contract block adjacent to the existing lock-order contract stating register-before-start, unregister postconditions, and per-domain empty-id ownership — comment-only, no behavior change.

**Blocked by:** 01 (Pin lifecycle order with facade-only tests — pins must be green first so the comment states pinned behavior, not aspiration).

**Status:** ready-for-agent (verify-only — contract block already present at DynamicStore.swift:14-17 beside lock-order at :7-12; do not re-add, only grep-verify once + confirm zero test edits)

**Refinement note (verify-only):** text already states register-before-start, unregister postconditions, and per-domain empty-id ownership. Agent task is verify-only: grep once beside lock-order, confirm no per-method copies, keep diff empty unless pins from 01 expose wording drift.

- [ ] One contract block beside the lock-order text: register-before-start (start can query synchronously) plus unregister postconditions (state cleared with detached completion, capabilities detached with snapshot clean)
- [ ] Empty-id ownership restated once in the same block: state helper owns update/get/remove/observe guards, registry owns register/unregister/query-capabilities guards, facade delegates without guarding; observable effect of empty-id lifecycle entries stays identical to no-op
- [ ] No new type, no signature change, no guard added at the facade, no per-method contract copies; placed so a future Store split carries it with the facade mechanically
- [ ] Full `swift test` green with zero test edits (comment-only diff); grep confirms contract text appears once beside lock-order and no test crosses internal helpers
