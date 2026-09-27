# 03: Verify isolation and record D7 handoff

**What to build:** full verification of the decision-table isolation plus a recorded handoff confirming the D7 input assumption held, so a reviewer can confirm one decide site, untouched neighbor regions, and identical public behavior in a single pass.

**Blocked by:** 02 (Pin decision truth table and preservation guarantees); transitively hard-blocked by D7 single-expiry race and timeout truth (input assumption).

**Status:** ready-for-agent

- [ ] `swift build` green and full `swift test` green with zero test-semantics edits across all prior lifecycle, settlement, activation-gate, slot-hold, and waiter suites
- [ ] Mechanical greps confirm the end state: exactly one decide site (settle step reads only the named table, no resurrected inline budget/void/mapping branches), single error-mint site at apply, no new seam or protocol, shared-race region and drain/pump region unchanged
- [ ] Handoff records the D7 post-state consumed (one unified raced-decoded input adjacent to settlement) and the deletion test (removing the old inline decide spelling changes nothing observable through the public scheduling seam), with region ownership restated: settle plus Lease here, race topology D7, drain/pump D4
