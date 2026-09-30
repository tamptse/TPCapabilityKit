# 03: Bridge detach symmetry + Sample teardown

**What to build:** Single id-carrier detach path in Bridge door plus Sample register/demo/unregister+removeState teardown with no stale leak comment.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] One detach adapter type (no duplicate start-noop classes); public Bridge shapes unchanged
- [ ] Sample cleans shared singleton and asserts getState nil after detach
- [ ] `swift test` green + sample target builds
