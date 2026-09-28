# 01: Generalize race seam with Bool specialization preserved

**What to build:** the expiry module offers a value-carrying race form beside the existing `Bool` form, so the waiter path behaves byte-identically while the executor has a race capable of carrying its `Any?` result; nothing calls the new form yet and the box path is untouched.

**Blocked by:** None (can start immediately). Note: assumes N1 (terminal unify) plus N4 (slot-eviction unify) post-state; N6-ticket-01 (Deadline collapse) follows this work, not precedes it.

**Status:** ready-for-agent

- [ ] Value-carrying race form added in the Deadline module sharing the single resolved timeout and the single TaskGroup topology (one operation task plus one sleep task, first-wins, `cancelAll`); concrete `Bool` + `Any?` overload pair preferred over unbounded `T: Sendable` generic because `Any?` is not `Sendable`
- [ ] `Bool` specialization preserved byte-for-byte (timeout maps to `false`, operation-`false` still `false`); registry `waitForAll` seam and `DynamicStore.waitForAllCapabilities` delegation unchanged, registry still receives the `Bool` race as an opaque value and never names the Tasks expiry type
- [ ] Timeout-resolve-once at Deadline construction untouched; Deadline named type kept (resolve-once suite keeps constructing it directly); no new lock domain, no new module, no public API change
- [ ] Verify: `swift test --filter DeadlineTests` green, `swift test --filter TimeoutContractTests` green, `swift test --filter SingleExpiryTests` green; full `swift test` green with zero test-semantics edits
