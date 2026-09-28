# 03: Verify sample + priority slices end-to-end

**What to build:** proof that the two cleanup slices land with zero product-behavior change — full build plus test suite green with the sample orchestrator still running cleanly.

**Blocked by:** 01 (sample split), 02 (priority synthesize).

**Status:** verify-only (2026-09-28: build green + 78-test Bridge filter green; full suite to confirm at commit)

- [ ] `swift build` green (Sample target still excluded from the product library)
- [ ] `swift test` green, including `sampleUsageRunsCleanly`, scheduler/priority tests, and Bridge timeout/display/delivery tests as regression guards
- [ ] No public API diff: no prod file outside `TPCapabilityKitSample` and `TaskPriority.swift` modified; `Capability`, Bridge adapter, Tasks/Lease/Settlement/Time/Slot untouched
- [ ] Decision recorded: speculative low-priority cleanup done as filler; no follow-up deepening spawned from this area
