# 01: Collapse descriptor to one stored timeout with three derived readings

**What to build:** The descriptor holds a single timeout truth with three thin derivations over it, so omitted still reads as the pinned literal flagged explicit, negative still stores absent flagged non-explicit while displaying the pin, and explicit still travels unchanged — with the wire fork still owned once behind the mapper interface and zero public signature change.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] Single stored timeout truth per descriptor; the duplicate stored enum field is gone and all three readings (collapsed display, explicitness flag, domain optional) derive adjacently from the one stored optional plus the single pin reference
- [ ] Wire fork still stated once behind the mapper interface (wire-negative to absent, non-negative to present, omitted pin collapsing to explicit present); no derivation restates the fork condition and both creation paths plus the live-view wrap share the one resolve-then-build sequence
- [ ] Public surface frozen (collapsed timeout, explicitness flag, both constructors, both wait entries keep signatures; no rename, removal, or deprecation)
- [ ] Resolver, display-collapse, timeout-contract, timeout-pins, and single-view suites pass unchanged with zero test-semantics edits
