# 03: Pin burst coalescing, reentrancy, and ordering

**What to build:** behavior pins proving the coalescing changed only drain multiplicity, so burst drains once with parallelism intact, reentrant retry is never stranded, and ordering plus cancellation hold without touching production code.

**Blocked by:** 02 (migrate kick sites to the single entry).

**Status:** ready-for-agent

- [ ] Burst pin: N rapid schedules drain to zero with every completion delivered exactly once and priority high-before-low preserved through the public seam
- [ ] Concurrency pin: available rows still activate concurrently under slot limits (serialization with FIFO wake intact); parked rows park once and wake to activation on capability arrival
- [ ] Reentrancy/cancel pin: retry re-queue during drain is observed without an extra drain; pump cancel clears the flag with re-kick on nonempty; cancel-while-queued/parked/active still lands terminal exactly once
- [ ] `swift build` green and full `swift test` green; production code untouched in this ticket except test files
