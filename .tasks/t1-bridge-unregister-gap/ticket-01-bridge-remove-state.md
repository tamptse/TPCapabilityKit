# 01: Bridge State-removal entry (partial detach slice)

**What to build:** the Bridge State-removal entry working end to end: an ObjC consumer registers a Plugin through the Bridge, writes State through the Bridge, removes that State through the new Bridge entry, and observes the Store contract — reads go nil, detached subscribers complete, the next update starts a fresh subject for new subscribers only.

**Blocked by:** None (can start immediately).

**Status:** verify-only — landed in 5ee4845 (do not re-implement; verify pins green + deletion red)

- [ ] Bridge exposes one ObjC-visible State-removal entry keyed by Plugin id string (mirrors existing read/write addressing); thin delegation to the existing Store State-removal entry with no guard, no policy, no new type
- [ ] Slice pin (Bridge seam only, fresh instance, rendezvous not sleeps): register → update → remove → read nil; pre-removal subscriber completed; post-removal update reaches only new subscribers
- [ ] Empty-id identical no-op for this entry: empty-id removal leaves reads, per-Capability observations, and whole-snapshot observations identical to before (no values, no snapshot delta)
- [ ] Consumer-only untouched: no Capabilities parameter, capability queries unchanged by this entry; full `swift test` green with no existing-test semantics edits; deletion check (drop the delegation line) turns the new pin red
