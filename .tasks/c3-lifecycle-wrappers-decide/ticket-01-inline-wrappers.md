# 01: Inline activation wrapper and delete dead lifecycle wrappers

**What to build:** Collapse the fake depth around the lifecycle table's single
locked transition seam. The activation gate calls the transition directly with
no delegating wrapper in between; the caller-less retry wrapper and the
divergent row-removal-only wrapper are gone, so the transition is visibly the
only writer. The one table-level test that drained through the removed path
now drains through the transition's terminal move, keeping its counts
assertions. Every activation, retry, cancel, and reuse behavior observed
through the scheduling facade is unchanged.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] Activation gate crosses the single transition seam directly, with its
  three-way outcome shape and lock scope preserved
- [ ] Retry and terminal-removal wrappers deleted with no replacement and no
  remaining callers
- [ ] Table-level double-park test drains through the single transition seam
  and still asserts pending/queued/parked counts
- [ ] No production path mutates a Lease outside the single transition
- [ ] Focused lifecycle plus settlement suites green, then full suite green
