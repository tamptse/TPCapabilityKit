# 01: Fold expiry result box to single call site

**What to build:** The Deadline execution path records its race result in a holder that lives exactly where it is used: the nested box type disappears from the Deadline module interface and a locally-scoped lock-guarded holder inside the execution path takes over, with no change to what the scheduler delivers — operation win still delivers its value (including stored nil into the retry policy), timeout still delivers expired with an empty result.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] Nested box type removed from the Deadline module interface; holder is constructed per execution and never escapes its scope
- [ ] Winner-branch write and post-race read stay mutually excluded with sendability preserved; loser write stays ignored by the race outcome
- [ ] Stored-nil vs never-stored distinction preserved via the won-gated read (timeout path never consults the slot)
- [ ] Expiry suite (resolve-once construction, execution-expiry delivery, operation-wins race) passes unchanged with no test naming the removed type
