# 03: Re-prove drain-monotonic and pin single-owner behavior

**What to build:** a re-proven drain-monotonic invariant plus behavior pins proving the single owner changed only lifecycle spelling, so D1 and D3 inherit a citable proof and a stable kick-plus-notification contract without touching production code.

**Blocked by:** 02 (add settle-drain notification for reconfigure and settle points).

**Status:** ready-for-agent

- [ ] Drain-monotonic proof recorded and pinned: new work lands only on current, cancel only removes, retry re-queues within its own generation, so a flagged-drained non-current generation cannot become live before the sweep; burst plus cancel plus retry suites hold this under coalesced pumping
- [ ] Single-owner pins: burst drains to zero with every completion delivered exactly once and at most one drain running; reentrant retry observed without an extra drain; handover never strands; notification fires exactly once per settle-to-drained transition; priority high-before-low, slot serialization with FIFO wake, and cancel-while-queued/parked/active terminal pins hold
- [ ] Provided-contracts note handed to D1/D3: single kick entry, settle/drain notification callable from reconfigure/settle points, re-proven invariant; production code untouched in this ticket except test files
- [ ] `swift build` green and full `swift test` green
