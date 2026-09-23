# CONTEXT.md — TPCapabilityKit domain glossary

## Plugin

A micro-frontend unit. Has an `id`, declares `capabilities` (default empty),
and `start(with:)` against the Store. Single protocol `AppPlugin` is canonical;
the `CapabilityProvider` legacy alias is removed.

## Store

The in-memory state database + capability registry (`DynamicStore`).
Owns state subjects and the capability index. The registry owns its own
lock with one mutate-and-notify seam: per-Capability notices deliver
before the whole-snapshot publish, and no caller holds the Store lock
across a registry call.
Changes are collected under lock and emitted after unlock; waiting is delegated
to Tasks. Public seam: register/update/get/observe state, query/observe capability,
plus the scheduling facade (schedule/schedule-and-wait/cancel/pending/active/configure,
immediate run styles).
The scheduler instance itself is private; all scheduling crosses the facade.
Reconfigure preserves in-flight generations: the old scheduler drains
naturally while new work enters the new one, and pending/active counts
aggregate across live generations.
Two observation granularities: per-Capability observation serves UI-style
subscribers; whole-registry observation serves the Tasks waiter only.

## State

A per-Plugin value keyed by Plugin id, held by the Store and observed typed.
Creation and subscription are separate: writers get-or-create, observation
alone never creates. Removal completes detached subscribers and the next
update creates a fresh subject for new subscribers.
_Avoid_: cache, snapshot

## Capability

A skill a Plugin provides (`heavyTask`, `lightTask`, `networkAccess`,
`backgroundExecution`, `custom(String)`). Queried O(1) via reverse index.
String `rawValue` exists for ObjC bridge; `description` derives from it.

## Task / TaskDescriptor

A unit of work requiring all `requiredCapabilities`, with `priority`,
`timeout`, `maxRetries`, `metadata`. Two execution styles share one waiting
mechanism: immediate (`runTask`) vs queued (`scheduleTask`).

## Lease

Lifecycle tracker `pending → active → completed/failed/expired` for one
scheduled Task. Exposes state transitions only; callers read
`state/isTerminal/result` plus the retry budget view. Retry budget checks
and reset decisions live in Settlement, not in Lease.
Custom `==` ignores associated `Error` values.
Deadline and retry decisions live in Settlement, not in Lease.

## Settlement

Single terminal decision for one Lease: timeout vs result vs retry vs
cancel, with completion delivery and waiter preservation. Owned by Tasks.
Owns the retry budget check, the void-completion policy, and the retry
re-queue; `enqueue` is the only queue writer conceptually, retry re-uses the
same Lease identity through a shared re-queue path. Owns the lease lifecycle row (place, execution, waiters) and the single
release shared by terminal, retry, and scope-exit paths.
_Deadline_ (expiry detail): timeout resolves once at enqueue and travels with
the Task; one Deadline module owns the single race for both the capability
wait and the execution path, with recording behind its seam.

## Tasks (Scheduler)

Deep module behind `schedule/cancel/pending/active`. Hides priority queues,
capability matching, timeout, retry, concurrency limits, and fire-and-forget
tracking. Variation is via `Configuration` values, not a protocol seam.
`autoProcess` is an internal detail, not part of the seam.
Owns one lifecycle table keyed by task id (place is pending, parked, or
active; order stays in the queue), the single capability waiter (one deadline per set), the Settlement path
(exactly-once terminal delivery for cancel/fail/timeout/retry, waiter preserved
across retry), and scoped slot acquisition with re-check inside.
 `executeLease` is the only prod activator. Serves every wait through one
 result rendezvous keyed by task identity with Lease-identity guard; holders tracked by the controller
 by task identity with owner-guarded release. Slot hold is scoped: one
 scoped-hold seam owns admission, FIFO wake order, cancellable wait, and
 scope-exit release.
Availability wait crosses one `wait(for:deadline:)` seam with an
injectable clock, so waiter and executor share one expiry.

## Bridge (ObjC adapter)

Single scheduling adapter behind `TPStoreBridge`: the `taskScheduler`
live view. `ObjcLease` is a live view
of the underlying Lease. Capability/priority/state/timeout/descriptor mapping lives in one internal
mapper module. ObjC Plugins are capability-consumers only (no `capabilities`).
 Completion delivery defaults to the main queue unless a queue is given.
 Timeout: Swift `nil` and ObjC wire-negative mean unspecified (scheduler
 default applies at enqueue); an omitted ObjC timeout is instead the pinned
 construction-time default carried as an explicit value for compat. One
 mapper-owned resolver states the fork once.
Immediate sync and wait-then-run agree through the one Tasks waiter.
