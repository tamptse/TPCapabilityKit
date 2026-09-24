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
naturally while new work enters the new one. Counts sum across live
generations while slot admission shares one Store-owned domain across
them, so reconfigure never doubles the configured limit during drain;
the single generations snapshot states this sum-vs-share split once.
Empty plugin ids are rejected once per domain at the owner seam: State
owns update/get/remove/observe, the capability registry owns
register/unregister/queryCapabilities, and the Store facade delegates
without guarding.
Two observation granularities: per-Capability observation serves UI-style
subscribers; whole-registry observation serves the Tasks waiter only.
Whole-set readiness is served behind the registry wait interface; Tasks
keeps park, expiry, activation, and settlement.

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
`timeout`, `maxRetries`, `metadata`. Two documented fire entries:
check-and-run (sync `runIfAvailable`, bypassing Lease, slot admission,
and Deadline by contract) vs schedule-and-wait (async, the one waiter;
`runTaskWhenAvailable` is its single-capability convenience). The legacy
async `runTask` is deprecated in favor of the two.

## Lease

Lifecycle tracker `pending → active → completed/failed/expired` for one
scheduled Task. Exposes state transitions plus a read-only retry budget
view; budget checks and reset decisions live in Settlement, not in Lease.
Custom `==` ignores associated `Error` values. The lifecycle table is
the single writer: each Lease mutation happens together with its row
write in one locked transition.

## Settlement

Single terminal decision for one Lease: timeout vs result vs retry vs
cancel, with completion delivery and waiter preservation. Internal step of
the single Tasks path, not a standalone module. Owns the retry budget
check, the void-completion policy, and the retry re-queue; `enqueue` is
the only queue writer conceptually, retry re-uses the same Lease identity
through a shared re-queue path. Decides outcome and delivers waiters but
never releases the slot — release belongs to the activation scope exit.
_Deadline_ (expiry detail): timeout resolves once at Deadline construction
from the task plus the configured default; Deadline owns only the single
race for both the capability wait and the execution path, while live and
virtual adapters plus the advance policy live in the time module.

## Tasks (Scheduler)

Deep module behind `schedule/cancel/pending/active`. Hides priority queues,
capability matching, timeout, retry, concurrency limits, and fire-and-forget
tracking. Variation is via `Configuration` values, not a protocol seam.
`autoProcess` is an internal detail, not part of the seam.
Owns one path from queued to parked to active to terminal plus retry
re-queue, with one lifecycle table keyed by task id (place is pending,
parked, or active; the order index is an internal detail of the table,
counts served from one immutable snapshot) as internal mechanics. Keeps
park, Deadline expiry, activation, and the Settlement step (exactly-once
terminal delivery for cancel/fail/timeout/retry, waiter preserved across
retry, and the outcome decision reads adjacent to the settlement step
that applies it, so decide-then-transition reviews as one path); whole-set readiness crosses the registry wait seam with one
injected expiry race per set (the Tasks Deadline passes its own race as
the value, so the registry never names the Deadline type). Scoped slot acquisition with re-check inside.
Park is one waiter per dequeued row: the pending → parked → active move
crosses one park-and-wait seam, so double-park and waiter-cancel rules live
in the table, not in callers.
 `executeLease` is the only prod activator. Serves every wait through one
   result rendezvous keyed by task identity with Lease-identity guard; holders tracked by the controller
   by task identity with the identity guard derived inside from the Lease —
   the scoped-hold interface is Lease-keyed, no caller mints tokens. Slot hold is scoped: one
   scoped-hold seam owns admission, FIFO wake order, cancellable wait, and
   scope-exit release. Activation crosses one seam: park, capability wait,
   admission, re-check, and row activation read as one path with one
   release shared by terminal, retry, and scope-exit.
Availability wait crosses one `race(operation:)` seam on Deadline, so
waiter and executor share one expiry with no wait-vs-execution kind
distinction; live and virtual adapters plus the advance policy live in
the time module behind one sleep seam.

## Bridge (ObjC adapter)

Single scheduling adapter behind `TPStoreBridge`: the `taskScheduler`
live view. `ObjcLease` is a live view
of the underlying Lease. The Bridge view and both descriptor creation
paths are thin translators; the whole ObjC timeout fork (wire-negative
vs explicit plus display fallback; an omitted call arrives as the pin
literal collapsing to explicit) lives in one internal
mapper module behind its interface. ObjC Plugins are capability-consumers
only (no `capabilities`).
   Completion delivery hops to the given queue or the main queue via a
   local helper in the Bridge view; no standalone delivery module.
  Timeout: Swift `nil` and ObjC wire-negative mean unspecified (scheduler
  default applies at Deadline construction); an omitted ObjC timeout is instead the pinned
  compat literal carried as an explicit value, independent of reconfigured
  defaults. One
  mapper-owned resolver states the fork once.
Immediate sync and wait-then-run agree through the one Tasks waiter.
