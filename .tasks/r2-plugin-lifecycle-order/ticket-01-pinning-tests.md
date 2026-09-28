# 01: Pin lifecycle order with facade-only tests (TDD, no prod edits)

**What to build:** failing-first behavior pins proving register-before-start ordering, unregister detach-plus-clear, and identical empty-id no-op — all crossing only the public Store facade seam, with zero production-code changes.

**Blocked by:** None (can start immediately).

**Status:** done (2026-09-28: 3 facade-only pins green in TPCapabilityKitPluginLifecycleOrderTests, zero prod edits)

- [ ] Register ordering pin: plugin whose `start` synchronously queries its own capability observes true through the facade; verify it fails if registration moves after `start` (swap-lines deletion check)
- [ ] Unregister pin: after facade unregister, per-plugin query empty, per-capability query false, state read nil, detached state subscribers completed, fresh update reaches only new subscribers
- [ ] Empty-id identical no-op pin: facade register/unregister with empty id leave queries, reads, per-capability observations, and whole-snapshot observations identical to before (no values, no snapshot delta)
- [ ] Facade-only discipline: no direct references to internal state/registry helpers in new tests; full `swift test` green with zero prod edits (red-green: confirm each pin fails under the matching deletion before keeping it green)
