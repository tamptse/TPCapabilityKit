# CONTEXT.md — TPCapabilityKit domain glossary

## Plugin

A micro-frontend unit. Has an `id`, declares `capabilities` (default empty),
and `start(with:)` against the Store. Single protocol `AppPlugin` is canonical;
the `CapabilityProvider` legacy alias is removed.

## Store

The in-memory state database + capability registry (`DynamicStore`).
Owns state subjects and the capability index. Single lock protects mutable state.
Changes are collected under lock and emitted after unlock; waiting is delegated
to Tasks. Public seam: register/update/get/observe state, query/observe capability,
plus the scheduling facade (schedule/schedule-and-wait/cancel/pending/active/configure,
immediate run styles).
The scheduler instance itself is private; all scheduling crosses the facade.
Two observation granularities: per-Capability observation serves UI-style
subscribers; whole-registry observation serves the Tasks waiter only.

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
same Lease identity through a shared re-queue path.

## Tasks (Scheduler)

Deep module behind `schedule/cancel/pending/active`. Hides priority queues,
capability matching, timeout, retry, concurrency limits, and fire-and-forget
tracking. Variation is via `Configuration` values, not a protocol seam.
`autoProcess` is an internal detail, not part of the seam.
Owns the single capability waiter (one deadline per set), the Settlement path
(exactly-once terminal delivery for cancel/fail/timeout/retry, waiter preserved
across retry), and scoped slot acquisition with re-check inside.
`executeLease` is the only prod activator.

## Bridge (ObjC adapter)

Single scheduling adapter behind `TPStoreBridge`: the `taskScheduler`
live view. `ObjcLease` is a live view
of the underlying Lease. Capability/priority mapping lives in one internal
mapper module. ObjC Plugins are capability-consumers only (no `capabilities`).
Completion delivery defaults to the main queue unless a queue is given.
