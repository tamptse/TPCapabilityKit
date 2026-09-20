# CONTEXT.md — TPCapabilityKit domain glossary

## Plugin

A micro-frontend unit. Has an `id`, declares `capabilities` (default empty),
and `start(with:)` against the Store. Single protocol `AppPlugin` is canonical;
`CapabilityProvider` is a legacy alias, not a separate concept.

## Store

The in-memory state database + capability registry (`DynamicStore`).
Owns state subjects and the capability index. Single lock protects mutable state.
Changes are collected under lock and emitted after unlock; waiting is delegated
to Tasks. Public seam: register/update/get/observe state, query/observe capability.

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
scheduled Task. Mutations are internal to the Tasks module; callers only read
`state/isTerminal/result`. Custom `==` ignores associated `Error` values.

## Tasks (Scheduler)

Deep module behind `schedule/cancel/pending/active`. Hides priority queues,
capability matching, timeout, retry, concurrency limits, and fire-and-forget
tracking. `TaskSchedulerProtocol` is the A/B seam (one real adapter today).
`autoProcess` is an internal detail, not part of the seam.
Owns the single capability waiter (one deadline per set), the terminalize path
(exactly-once terminal delivery for cancel/fail/timeout/retry), and scoped slot
acquisition with re-check inside. `executeLease` is the only prod activator.

## Bridge (ObjC adapter)

Single scheduling adapter behind `TPStoreBridge`; `TPTaskScheduler` is the same
implementation, not a second seam. `ObjcLease` is a live view of the underlying
Lease. Capability/priority mapping lives in one internal mapper.
