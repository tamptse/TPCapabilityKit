# 01: Collapse triple check into one documented availability gate

**What to build:** the Tasks availability checks read as one gate beside activation with the entry-vs-recheck window stated once, so reviewers can answer which check decides without holding three sites together; behavior is identical, only locality plus prose moves.

**Blocked by:** None (can start immediately). Note: assumes R4 race-carries-value post-state (waiter keeps Bool specialization, registry receives the Bool race as an opaque value without naming the expiry owner); lands before ticket-02 in this spec.

**Status:** ready-for-agent

- [ ] Availability gate stated once beside activation: terminal refusal, availability re-check, and row activation read as one decide-then-apply path with settling kept in the caller; the hold-suspension window (entry checks are review-only early exits, post-admission re-check decides, admission refusal returns silently) documented in exactly one place
- [ ] Two entry early-exits kept as exits but referencing the gate as the decider rather than restating the window; no caller-side wait loop introduced, no lock-domain change, no new seam, no public API change
- [ ] Gate-locality pins added through the public seam with deterministic time: flip-during-admission routes to failed (not silent activation), terminal-during-wait refuses without settling, plus existing entry/exit behavior unchanged
- [ ] Verify: `swift test --filter ActivationGate` green, `swift test --filter CapabilityRegistryWait` green, `swift test --filter FireAgreement` green; full `swift test` green with zero test-semantics edits except the new gate-locality pins
