# 03: Prove both creation paths agree

**What to build:** plain and client-id descriptor creation sharing one resolve-then-build form, proven by behavior so cancel-by-id and plain scheduling can never disagree on timeout meaning.

**Blocked by:** 02 (collapse the pin duplicate to one owner).

**Status:** ready-for-agent

- [ ] Both creation paths route through the same resolve-then-build form (resolve wire once, build domain descriptor from the resolved form)
- [ ] Behavioral proof across every wire class: wire-negative, pin literal, arbitrary explicit, plus Swift `nil` round-trip; Deadline construction confirms `nil` takes the configured default while explicit ignores reconfigure
- [ ] `swift build` + full `swift test` green; no timeout-semantics change, no Deadline/time-adapter change
- [ ] No new seam; Bridge adapter stays thin with timeout policy only in the timeout form
