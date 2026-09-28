# 01: Collapse timeout readers to one stored enum match

**What to build:** The ObjC timeout fork reads once instead of three times: the single wire resolver stays the sole policy statement while the descriptor stores the resolved enum and both `@objc` observables (collapsed display reading, explicitness flag) become thin views over that one stored match, so omitted still reads as the pinned literal flagged explicit, negative still stores nil flagged non-explicit while displaying the pin, and explicit still travels unchanged — with zero `@objc` signature change.

**Blocked by:** None (can start immediately).

**Status:** closed-superseded-by-s6 (self-grill 2026-09-27: conflicts with s6 single-store + mirror pin; see specs/FAILURES.md 2026-09-26 c6 entry)

- [ ] Single resolver still owns the only fork condition (wire-negative to unspecified, non-negative to explicit, omitted pin collapsing to explicit); no reader restates the condition independently
- [ ] Descriptor stores the resolved enum once; collapsed display and explicitness flag read from one stored match, never from two independent optional derivations
- [ ] `@objc` surface frozen (collapsed timeout property, explicitness flag, both constructors keep signatures; no rename, removal, or deprecation)
- [ ] Resolver suite (omitted-pin, wire-negative, explicit preserved, both-paths-share), display-collapse suite, timeout-contract suite, and timeout-pins suite pass unchanged with zero test edits
