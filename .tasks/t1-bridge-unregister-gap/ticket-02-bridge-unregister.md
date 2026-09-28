# 02: Bridge full-detach entry (unregister slice)

**What to build:** the Bridge full-detach entry working end to end: an ObjC consumer registers through the Bridge, writes and subscribes through the Bridge, then unregisters by Plugin id string and observes full detach — State cleared with detached completion plus Capability-row detach — while consumer-only (never provides Capabilities) stays pinned.

**Blocked by:** 01 (Bridge State-removal entry — partial-detach delegation and its State pins must be green first so this slice reviews as removal-plus-row-detach, not a re-implementation of removal).

**Status:** verify-only — landed in 87456d2 (do not re-implement; verify pins green + deletion red)

- [ ] Bridge exposes one ObjC-visible full-detach entry keyed by Plugin id string (no plugin-object identity, no Capabilities parameter); thin delegation to the existing Store full-detach entry via the existing transient-adapter path, no Store signature change, no guard, no new type
- [ ] Slice pin (Bridge seam only, fresh instance, rendezvous not sleeps): register → update + subscribe → unregister by id → read nil, detached subscribers completed, fresh update reaches only new subscribers, per-plugin capability row empty and per-Capability queries false exactly as before unregister (consumer-only preserved)
- [ ] Empty-id identical no-op for this entry: empty-id unregister leaves queries, reads, per-Capability observations, and whole-snapshot observations identical to before; consumer-only restated once beside the new entries so a future Capabilities parameter reads as a contract break
- [ ] Full `swift test` green with no existing-test semantics edits; deletion checks (drop the Store delegation; add a Capabilities parameter) each turn at least one new pin red
