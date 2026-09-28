# 02: Fold OrderIndex into deepened LifecycleStore

**What to build:** a deepened lifecycle table owning one invariant (counts plus place plus order agree on every transition) with the order index as private mechanics, so Path reads as the only flow reader with ordering and counts identical to today.

**Blocked by:** 01 (Collapse Deadline into Path-private race helper).

**Status:** ready-for-agent

- [ ] OrderIndex ceases to be a separately addressable nested type; enqueue/dequeue/remove become private mechanics of the single table transition with one Place transition stating the invariant once
- [ ] Preserved verbatim: priority FIFO order, double-park refusal, waiter-cancel on terminal, terminal removal cleaning order, single counts snapshot derivation, single-writer row-plus-Lease pairing
- [ ] Speculative guard: land only if the single-transition review reads strictly shorter while ADRs 0007/0017/0025/0026 stay unreopened (no fourth lock domain, no Store-level split); otherwise drop this ticket and keep 01
- [ ] Full test suite green with zero test-semantics edits; grep proves no separately addressable OrderIndex remains
