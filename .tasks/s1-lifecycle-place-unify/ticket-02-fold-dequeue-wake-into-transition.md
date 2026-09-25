# 02: Fold dequeue-to-parked and wake-clear into the transition vocabulary

**What to build:** the Path flow stops performing its own place and waiter patches — dequeue-to-parked placement and wake clearing cross the single transition vocabulary like activate, retry, and terminal — so every place change is auditable in one reviewable block with identical order, counts, and delivery.

**Blocked by:** 01 (demote insert, delete dead park overload — the table entries must already be consolidated before the Path call sites migrate).

**Status:** ready-for-agent

- [ ] Dequeue-to-parked move reads as a transition case: order pop plus place write plus counts update happen in one locked step with identical priority FIFO order and identical skip-missing-row behavior; order index stays internal mechanics
- [ ] Wake clearing reads as a transition case: waiting flag plus waiter reset on identity match; terminal-take still removes the row so wake-clear versus terminal-take cannot double-clear
- [ ] Factory park untouched as the single park seam; Path call sites perform no place or waiter patch outside transition; lock discipline preserved (one scheduler lock, never nested; factory non-suspending; slot evict, delivery, cancellation, expiry race, registry wait, slot hold outside the lock)
- [ ] `swift build` green and full `swift test` green with zero test-semantics edits; grep shows no Path-side place write or waiter patch outside the transition vocabulary
