# M5 — Bridge door layers contract (keep Adapter plus funnel)

## Problem Statement

The Bridge door shows several layers for one queue hop (inner delivery adapter plus hop plus boxed sinks plus two wait spellings plus a detach adapter). Readers perceive pass-through layers that could be inlined and a capability spelling that could move to the caller.

## Solution

Keep the layers and document why: the inner adapter is the single owner of queue policy plus sendable boxing; the capability spelling funnels into the descriptor spelling into one wait core so the two wait spellings cannot diverge; the detach adapter stays an identifier-only noop-start next to the door. No prod change; comments state the funnel once.

## User Stories

1. As an ObjC consumer, I want completions to always arrive on the given queue or the main queue, so that I never learn per-site delivery rules.
2. As a Bridge author, I want one place to add a new delivery site without copying box-plus-hop, so that delivery cannot drift.
3. As a reviewer, I want sync check-and-run versus scheduled wait agreement readable in one place, so that contract review stays local.
4. As a future architect, I want the collapse rejection recorded, so that I do not re-propose inlining without the four-site duplication cost.

## Implementation Decisions

- Module: door stays the single scheduling adapter behind the store bridge live view; inner adapter stays private to the door, not a standalone module.
- Interface: no spelling change. Capability path builds a descriptor then funnels to descriptor path then wait core then hop; subscribe paths funnel through boxed sinks; detach stays identifier-only.
- Timeout passes through the underlying descriptor without inspection; fork stays behind the mapper module.
- Test-only immediate queue policy stays for deterministic delivery assertions.
- Grill (auto): inlining adapter rejected (quadruplicates box-plus-hop); moving capability build to caller rejected (duplicates descriptor defaults plus wire fork); moving detach adapter rejected (couples state API with adapter shape); deleting immediate policy rejected (forces flaky async delivery in tests); collapsing schedule-completion into hop rejected (widens private hop for seven saved lines).

## Testing Decisions

- No test changes. Verify through existing delivery agreement plus single-view plus timeout resolver suites.
- Any real collapse must prove both wait spellings still agree and detach never provisions capability.

## Out of Scope

- Timeout fork changes; sync entry merge into wait core; public ObjC API changes; state or scheduler prod changes.

## Further Notes

- Independent; pairs with M7 (mapper thin). Respects single-scheduling-adapter, bridge-through-single-view, omitted-timeout-pin, and whole-set-wait ADRs. No new ADR.
