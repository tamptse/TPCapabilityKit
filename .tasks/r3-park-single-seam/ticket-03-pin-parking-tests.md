# 03: Pin double-park, cancel-while-parked, and terminal behavior

**What to build:** behavior pins proving the fuse changed only atomicity, so double-park refusal, cancel-while-parked terminal delivery with waiter cancel, and wake-clear hold without touching production code.

**Blocked by:** 02 (migrate Path caller to the single park seam).

**Status:** ready-for-agent

- [ ] Double-park pin: second park of the same row refused through the public seam (parked counts agree, no duplicate waiter)
- [ ] Cancel-while-parked pin: cancel lands terminal-expired with exactly-once waiter delivery and the parked waiter cancelled; same-id reschedule still works after terminal
- [ ] Wake/terminal clear pin: woken row no longer looks waiting (re-park behaves) and terminal take leaves no residual waiter; retry identity and waiter preservation unchanged
- [ ] `swift build` green and full `swift test` green; production code untouched in this ticket except test files
