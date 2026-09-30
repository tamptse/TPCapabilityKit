# 04: State contract docs + DEBUG warn

**What to build:** State typed-edge contract stated once (wrong-type reads as absent, removals complete, never nil) with DEBUG-only warn on ObjC grain mismatch.

**Blocked by:** None (can start immediately, sequence sample-doc edit after 03 if both touch Sample).

**Status:** ready-for-agent

- [ ] Headers on StoreState + ObjcStoreBridge state the grain in one line each
- [ ] DEBUG warn fires when non-nil subject value fails NSObject coercion; release behavior unchanged
- [ ] `swift test` green
