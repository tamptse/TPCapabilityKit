## Problem Statement

The expiry stack resolves timeout once and races waiter against executor through one shared seam, but two readability defects obscure that design: the result box lives as a nested generic type inside the Deadline module while having exactly one call site, and the rendezvous spellings on the time adapter and the deterministic registry are identical, so reviewers cannot tell the public gate apart from the internal registry rendezvous. Both defects raise the cost of reviewing the single race that Settlement depends on.

## Solution

Fold the box to its single call site as a locally-scoped lock-guarded holder, keep the three-layer Deadline → Clock → VirtualTime depth, keep the `race(operation:)` interface untouched, and rename the registry-internal rendezvous so each seam has an unambiguous name. No expiry semantics change: one timeout, one race, one sleep seam.

## User Stories

1. As a scheduler maintainer, I want the result box scoped to the execution path that uses it, so that I review the race and its recording in one place.
2. As a scheduler maintainer, I want the nested box type gone from the Deadline interface, so that the module reads as timeout resolution plus one race and nothing else.
3. As a reviewer, I want the public adapter gate and the registry rendezvous to have different names, so that I never confuse the test synchronization point with the internal advance gate.
4. As a test author, I want the deterministic advance/wait rendezvous preserved, so that expiry tests stay green without flakiness.
5. As a test author, I want multi-waiter tests to keep their explicit count gate, so that advancing with only one waiter parked cannot pass silently.
6. As a reconfigure maintainer, I want the single shared time instance untouched, so that generations never fork virtual time.
7. As a Settlement reviewer, I want void-completion (stored nil) still distinguished from never-stored, so that the retry budget decision reads the same outcome as before.
8. As a concurrency reviewer, I want the folded holder to keep the same lock discipline and sendability as the nested type, so that the loser-write-is-ignored property survives the move.
9. As a registry owner, I want the injected expiry race value unchanged, so that the registry never names the Deadline type.
10. As a Store consumer, I want the facade deterministic-time spelling unchanged, so that no call-site migration is needed.
11. As a future deepener, I want the time module to keep owning both adapters plus the advance policy behind one sleep seam, so that expiry depth stays in two modules, not scattered.
12. As a future deepener, I want locality leveraged: box next to use, rendezvous named by role, race as the single seam — so that the next expiry change touches one place.

## Implementation Decisions

- Keep the three-layer depth: the Deadline module owns timeout-once resolution plus the single race; the time module owns the live adapter, the virtual adapter, and the advance policy behind one sleep seam. No layer is collapsed.
- Fold the nested generic box into the execution path as a locally-scoped lock-guarded holder: one lock, one stored slot, store/load pair, sendability preserved. The holder is constructed per execution and never escapes its scope.
- Preserve the won-gated read exactly: the stored slot is read only when the race reports the operation won; the timeout path still yields an empty result without consulting the slot. This preserves the never-stored vs stored-nil distinction the void-completion retry policy depends on. A naive fold to a bare optional without the won gate is rejected.
- Preserve lock discipline through the fold: the winner-branch write and the post-race read stay mutually excluded, and the loser write (if it lands late) stays ignored by the race outcome, exactly as today.
- Rename the registry-internal rendezvous to `awaitWaiterRegistered` (singular-registration wording, internal to the deterministic registry); the adapter-level gate keeps the `waitForWaiters(count:)` spelling, and the Store facade keeps its deterministic-waiters spelling. Each seam then names its own role: facade spelling, adapter gate, registry rendezvous.
- Keep the `race(operation:)` interface byte-for-byte in behavior and shape: the capability wait and the executor keep sharing one expiry through the one injected race value; the registry seam is untouched.
- No adapter-switching preconditions move: enable-once before first use, virtual-only advance, and the single shared time instance across generations all stay where they are.
- Determinism tests keep both gates: the explicit multi-waiter count gate in tests plus the single-waiter gate inside advance. Removing the explicit count gate to "simplify" is rejected because advance alone only guarantees one waiter parked.

## Testing Decisions

- A good test pins externally observable expiry behavior (expired vs completed vs retry, which waiters woke, waiter counts) through the deterministic adapter, never the holder type or lock internals.
- Existing seams are leveraged, no new seams: the sleep seam plus the advance/wait rendezvous remain the highest synchronization points; tests synchronize on the adapter gate and assert on lease state and waiter counts.
- Prior art: the expiry suite covering resolve-once construction plus execution-expiry delivery, and the time-adapter suite covering non-positive sleep parity plus wake-only-expired advance, are the models for any touched test.
- The fold is verified by the unchanged execution-expiry and operation-wins tests: stored-nil still routes to the retry policy, timeout still routes to expired, and no test names the removed nested type.
- The rename is verified by the unchanged rendezvous tests: multi-waiter advance still requires the explicit count gate, single-waiter advance still passes through the internal gate, with zero public spelling churn.

## Out of Scope

- Any change to timeout resolution (task value vs configured default) or to the pinned-compat timeout fork.
- Any change to the Settlement decision table, retry budget, void policy, or slot-release ownership.
- Any change to the registry wait interface, park механика, activation gates, or generation sharing.
- Collapsing the time module into Deadline, threading time per call, or forking virtual time per generation.
- Public API renames on the Store facade or the adapter gate; the only rename is registry-internal.

## Further Notes

- Grill outcome: the fold was challenged as Strong-safe rather than trivially safe because of the double-optional collapse (`stored nil` vs `never stored`) and Swift 6 sendability capture rules; the verdict is Strong-safe only with the won gate, the lock, and the per-execution holder scope all preserved. That condition is recorded as the load-bearing constraint of the first ticket.
- Vocabulary: module (Deadline expiry detail, time adapters), interface (`race(operation:)` seam, sleep seam, registry wait seam), depth (three layers kept), seam (single race, single sleep, park-and-wait untouched), adapter (live vs virtual behind one seam), leverage (existing rendezvous tests as the verification seam), locality (holder lives where it is used).
- Respects ADR-0023 (time module owns adapters plus advance policy; supersedes the all-in-Deadline reading of ADR-0012), ADR-0012 (single race for wait and execution, timeout resolved once), and the CONTEXT glossary entries for Settlement/Deadline/Tasks (Tasks keeps park, expiry, activation, settlement; whole-set readiness crosses the registry seam with one injected race).
