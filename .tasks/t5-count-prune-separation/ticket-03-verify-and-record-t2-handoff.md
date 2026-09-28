# 03: Verify hardening and record T2 handoff for getter purity

**What to build:** full verification of the hardening plus a recorded handoff stating the getter-purity follow-up (pure reads with reaping only at explicit reconfigure/settle points) is blocked by T2 pump-coalesce, with the monotonic-drain invariant written down as the assumption T2 must re-prove.

**Blocked by:** 02 (Pin reap guarantees through the facade seam); for the follow-up only — hard edge on T2 pump-coalesce drain lifecycle (settle/drain notification plus drain redefinition under coalesced pumping).

**Status:** ready-for-agent

- [ ] `swift build` green and full `swift test` green with zero test-semantics edits across all prior generation, snapshot-postcondition, slot-domain, and determinism suites
- [ ] Mechanical greps confirm the end state: old anonymous prune spelling absent, exactly one Store-to-Tasks crossing at the named reap pass, drain-state reads outside the scheduling lock
- [ ] Handoff records the follow-up scope (getters pure, reap at explicit reconfigure/settle points fed by a settle/drain notification) with its blocked-by-T2 edge, and states the monotonic-drain invariant (non-current generations drain only: new work lands solely on current, cancel only removes, retry stays in-generation) as the assumption T2 must re-prove before the sweep shape changes
- [ ] No drain redefinition, no public seam change, and no slot/Lease/Settlement/Deadline/registry edits leaked into this work
