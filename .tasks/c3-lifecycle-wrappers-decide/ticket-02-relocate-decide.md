# 02: Relocate outcome decision next to the settlement step

**What to build:** Move the free outcome-decision function into the Tasks path
scope as a private member immediately above the settlement step, so
decide-then-transition reviews as one path in one scroll. The decision logic
itself (retry budget check, void-completion policy, terminal mapping) is
untouched, and the settlement call-site spelling stays equivalent. All
existing settlement, retry, cancel, and lifecycle-agreement tests pass
unchanged, proving the move is semantics-preserving.

**Blocked by:** 01 (Inline activation wrapper and delete dead lifecycle
wrappers) — the settlement step must already cross only the single transition
seam before decision and application are read as one path.

**Status:** ready-for-agent

- [ ] Outcome decision lives in the Tasks path scope adjacent to the
  settlement step; no free-function decision site remains
- [ ] Decision logic (budget, void policy, terminal mapping) byte-for-byte
  equivalent in behavior
- [ ] No existing test file modified; full suite green
- [ ] No new seams, no behavior change through any public interface
