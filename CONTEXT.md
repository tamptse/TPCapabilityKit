# CONTEXT.md — TPCapabilityKit domain glossary

## Plugin

A micro-frontend unit. Has an `id`, declares `capabilities` (default empty),
and `start(with:)` against the Store. Single protocol `AppPlugin` is canonical;
`CapabilityProvider` is a legacy alias, not a separate concept.

## Store

The in-memory state database + capability registry (`DynamicStore`).
Owns state subjects and the capability index. Single lock protects mutable state.
Public seam: register/update/get/observe state, query/observe capability.

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
