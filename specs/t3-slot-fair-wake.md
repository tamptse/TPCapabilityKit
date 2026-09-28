## Problem Statement

The slot controller admits waiters strictly through the head of its FIFO arrival queue: on release it tests only the first queued waiter against current capacity and, when that waiter still does not fit, wakes nobody — even when a waiter further back would fit the capacity just freed. Behind one shared slot domain with heterogeneous capability sets this is head-of-line blocking: a single waiter needing a still-full capability parks the entire queue behind it while usable capacity idles. From a scheduler user's perspective, tasks whose required capabilities are all free sit pending for no reason related to their own demand, and overall throughput degrades toward the worst-case capability mix instead of tracking genuinely contended limits. The wake-order comment states head-only wake as policy, so the behavior is deliberate but undocumented as a tradeoff: strict FIFO order is being bought with idle slots, without ever stating the overtake alternative or who pays for it.

## Solution

Keep the FIFO arrival queue and the sole scoped-hold admission seam untouched, and change only which waiters a release considers: scan the queue in arrival order and admit satisfiable waiters instead of testing only the head. The head keeps absolute priority — every scan starts at index zero, so whenever the head fits it is still admitted first — and a skipped head is re-evaluated on every later release, so skipping can delay it but never strand it. The documented policy becomes first-fit FIFO with skip: arrival order decides among the waiters that fit; a waiter that does not fit is passed over without losing its place. Admission, duplicate rejection, cancellable wait, single-waiter eviction intents, the scope-exit release guard, and the Tasks settle-then-activate ordering stay identical; only the release consideration set changes, from one waiter (the head) to every satisfiable waiter in order, bounded by the freed capacity. The overtake policy is stated once beside the admission seam and in the domain glossary so the fairness-vs-throughput tradeoff is explicit instead of implied by a queue comment.

## User Stories

1. As a scheduler user with mixed-capability workloads, I want a task whose capabilities are free to activate even when an earlier task still waits on a full capability, so that my throughput tracks real contention instead of the worst waiter.
2. As a FIFO waiter whose demand currently fits, I want arrival order among fitting waiters preserved, so that fairness survives the removal of head-only wake.
3. As a skipped head waiter, I want re-evaluation on every later release, so that my delay ends at the first release that frees what I need and I am never stranded behind overtakers.
4. As a Tasks maintainer, I want one release path that scans in arrival order, so that wake behavior reviews in a single hop instead of a head check plus an implied stall.
5. As a slot reviewer, I want the overtake policy stated once beside the admission seam, so that skip-vs-strict reads as a decision rather than an accident of queue indexing.
6. As an activation-path reviewer, I want woken waiters to keep crossing the same admission gate and row activation, so that terminal, displaced, or unavailable leases still refuse cleanly and return their slot.
7. As a cancel caller, I want cancellable wait unchanged, so that a waiter cancelled mid-scan still resolves false exactly once and never holds a scanned slot.
8. As a displacement integrator, I want stale-evict and self-cancel intents untouched, so that same-identity overwrite keeps settling first with slot-only eviction.
9. As a global-limit operator, I want one release to admit at most what the freed capacity allows, so that limits are never overshot by a wake batch.
10. As an unbounded-global operator, I want one release that frees several per-capability slots to admit every fitting waiter in order, so that disjoint demands do not serialize behind a single wake.
11. As a park reviewer, I want the newcomer rule (never overtake queued waiters) coherent with the release scan, so that admission fairness reads the same from both directions.
12. As a test author, I want the HOL stall pinned through the scheduling facade with heterogeneous demands, so that the fix is proven by observable activation order rather than queue spelling.
13. As a test author, I want homogeneous FIFO order still pinned, so that the scan cannot silently reorder waiters that all fit.
14. As a future contributor, I want the fairness-vs-throughput tradeoff plus the no-strand argument recorded in the decision log, so that a later strict-FIFO revert must answer the throughput evidence.
15. As a Bridge consumer, I want scheduling behavior identical from Objective-C, so that this throughput fix stays invisible across the adapter.

## Implementation Decisions

- **Module**: the slot controller remains the slot module owning admission, wake order, cancellable wait, waiter eviction, and scope-exit release. Tasks keeps owning park, Deadline expiry, activation, and the Settlement step. No Lease or row logic moves into the controller; no new module is introduced.
- **Interface**: the scoped-hold seam stays the sole admission seam with its shape unchanged. Callers learn one documented policy sentence (first-fit FIFO with skip, head re-evaluated each release), not a new method or parameter. The rejected alternative (a scan-mode flag or a second wake entry) would split one admission decision across two caller-visible spellings for zero gain.
- **Depth**: depth increases with no new seam: the same locked pass that frees capacity now also finds every fitting waiter, so one release reviews as one scan instead of a head test plus an invisible stall. No new abstraction layer is added.
- **Seam**: the highest seam stays the scheduling facade (schedule/schedule-and-wait/cancel/pending/active) plus the scoped-hold seam as the sole admission crossing. Behavior pins cross the facade; the scan itself is pinned narrowly at the controller seam. No new seam is created.
- **Adapter**: no adapter change. The Bridge stays the single ObjC scheduling adapter and is untouched; wake order is invisible from Objective-C.
- **Fairness policy**: first-fit FIFO with skip. The scan restarts at the head on every release, so the head is always the first candidate and keeps priority whenever it fits; a skipped waiter loses no place and is reconsidered on each later release. No overtake counter or starvation bound is introduced: a head that never fits faces genuine capacity exhaustion, not unfairness, and a counter would add interface for zero gain.
- **Wake budget**: one release admits every satisfiable waiter in arrival order within the same locked pass, bounded by freed capacity — at most one admission per freed global slot when a global limit is configured, per-capability limits otherwise. Woken means admitted (slot already installed under the lock), so no woken waiter ever re-parks: the thundering-herd alternative (wake-then-contend) is rejected because it churns continuations for capacity that was never reserved.
- **Resume discipline**: all admitted waiters resume outside the lock as a batch, preserving the existing no-reentrancy rule (today with one resume, after with many). Order of resume follows arrival order.
- **Park coherence**: the newcomer no-overtake rule is kept, not relaxed: a newcomer arriving while waiters are queued still parks even if it would fit, because the queued scan owns the freed capacity first. Relaxing it would let newcomers jump the queue the scan just made fair.
- **Activation interplay**: woken waiters cross the unchanged admission gate (terminal refusal returns silently, availability re-check may fail the lease, row activation may refuse a displaced row). Any refusal exits the hold scope and releases, cascading into the next scan — throughput is preserved through refusal churn with no special path.
- **Locality**: scan, capacity check, install, and queue removal read adjacent inside the release step, so the full wake contract needs no hop. The overtake policy comment lives beside that step, not in callers.
- **Leverage**: leverage is stall removal at fixed interface cost: one scan to audit, zero caller changes, zero new seams. Blast radius is bounded because the homogeneous-demand case behaves exactly as before (scan degenerates to head wake) and only the heterogeneous stall changes.
- **Respects ADRs**: scoped-hold ownership (the controller owns admission, wake order, cancellable wait, and scope-exit release behind one seam — the scan stays inside that ownership, the seam shape untouched); single scoped-hold seam (no second wake spelling is added); hold Lease-keyed with the newcomer-keyed retire exception (eviction intents untouched); task-keyed slot ownership with controller-owned idempotent release (the scan touches only queued waiters, never held entries).

## Testing Decisions

- A good test pins externally observable activation order through the scheduling facade with heterogeneous demands (blocked head plus fitting follower activates; skipped head activates at the first release freeing its demand; homogeneous FIFO order identical) plus narrow controller pins of the scan (first-satisfiable admitted, unsatisfiable head skipped without losing place, limits never overshot, batch resumes all admitted) — never the loop spelling.
- Modules under test: the release scan (order plus capacity budget), the admission-gate interplay (a refused waiter returns its slot and the cascade continues), and park coherence (a newcomer still queues behind waiters).
- Prior art: the slot-hold suite (double-acquire rejection, stale/self eviction pins, arrival-order log pin), the scoped slot suite (drain, cancel-during-acquire, injected-domain limits), and the scheduler integration suites are the models — all stay green with zero test-semantics edits. No existing test covers heterogeneous blocking, so the HOL pins are purely additive and nothing re-pins.
- Verification: focused slot suites first, then the full suite green; grep confirms no head-only wake spelling remains beside the scan.

## Out of Scope

- Any change to admission limits, duplicate rejection, cancellable wait, single-waiter eviction, the scope-exit owner guard, same-identity policy, settle-first ordering, retry budget, void policy, cancellation, timeout/expiry, capability matching, the Deadline race, or the registry wait.
- Limit-reconfiguration wake sweeps (raising limits does not retro-scan the queue) — a separate candidate.
- Priority-aware slot admission (priority still lives in the Tasks dequeue order, not in slot wake order).
- Moving or reshaping the lifecycle table, the order index, the outcome decision, the Lease shape, or the hold keying.
- Touching the state database, capability registry, Bridge translators and delivery, time adapters and advance policy, generations, the package manifest, or any new public interface or observation seam.

## Further Notes

Grill record (autonomous self-grill, two rounds; recommendations adopted):

- Round 1, Q1 — Scan-with-install vs wake-all-then-contend? Scan-with-install: woken means admitted under the lock, so no waiter resumes only to re-park. Wake-all churns continuations for unreserved capacity. Adopted.
- Round 1, Q2 — Single wake per release vs drain-all-fitting? Drain-all bounded by freed capacity: one release can free several per-capability slots when no global limit binds, and single-wake would serialize disjoint demands for no fairness gain. The global-bounded case naturally drains to one. Adopted.
- Round 1, Q3 — Overtake counter or starvation bound? Rejected: the scan restarts at the head on every release, so the head is always the first candidate — skipping delays but cannot strand. A counter adds interface for zero gain. Adopted.
- Round 1, Q4 — Relax the newcomer no-overtake rule to match? Rejected: newcomers still park behind queued waiters so the queued scan owns freed capacity first; relaxing reintroduces queue-jumping through the other door. Adopted.
- Round 2, Q5 — Batch resume inside vs outside the lock? Outside as an arrival-ordered batch, extending the existing single-resume rule; resuming continuations under the controller lock risks re-entrancy into park/release. Adopted.
- Round 2, Q6 — Refused-at-gate cascade needs a special path? No: refusal exits the hold scope, scope-exit release runs the next scan. Pinned by test, not by mechanism. Adopted.
- Round 2, Q7 — Does the scan disturb stale-evict or self-cancel? No: eviction removes queued waiters under task identity independent of position; the scan only reads the post-eviction order. Untouched. Adopted.

Strong recommendation holds after both rounds: head-only wake is strictly dominated by first-fit FIFO with skip — same interface, same seams, same homogeneous behavior, with idle-slot stalls removed and the head's priority provably preserved by scan-from-zero plus re-evaluation on every release.

- Domain vocabulary (CONTEXT): Tasks Scheduler, Lease, Settlement, slot hold, admission, FIFO wake, cancellable wait, scope-exit release, same-id policy, rendezvous waiter, Deadline, registry wait.
- Design vocabulary: Module (slot controller vs Tasks ownership), Interface (scoped-hold seam unchanged, one policy sentence), Depth (stall logic inside, no new seam), Seam (facade highest, controller narrow pin), Locality (scan plus install adjacent), Leverage (stall removal at fixed interface cost).
- Source of prototype decisions: none — no prototype; decisions derive from the release-step inventory and the activation-path dependency (admission gate plus scope-exit release plus settle-owns-no-release).
