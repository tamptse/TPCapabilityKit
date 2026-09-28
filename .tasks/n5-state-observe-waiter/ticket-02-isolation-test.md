# 02: Prove waiter isolation through the facade seam

**What to build:** behavioral proof that parked observe-before-write subscribers resolve exactly on their own plugin id's creation (and complete sanely on removal), so the extracted waiter is verified by lifecycle not by spelling.

**Blocked by:** 01 (collapse rendezvous enums and extract the waiter).

**Status:** ready-for-agent

- [ ] Observe-before-write resolves on first update for that plugin id only; unrelated ids do not wake parkers
- [ ] Multiple parked observers on the same id all resolve; removal before creation leaves parkers completing rather than hanging; next update mints a fresh subject for new subscribers
- [ ] All assertions cross the public Store update/observe/remove seam; `swift build` + full `swift test` green
- [ ] No lifecycle-semantics change: get-or-create, observe-never-creates, lock order, and notice ordering unchanged
