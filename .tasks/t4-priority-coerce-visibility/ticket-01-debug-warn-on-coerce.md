# 01: Warn in DEBUG when priority coercion fires

**What to build:** Out-of-range ObjC priority values still schedule at normal exactly as today, but a DEBUG build now warns with the offending raw value at the single coercion point, so a developer can tell a coerced normal apart from a genuine normal — with zero release-build change.

**Blocked by:** None (can start immediately).

**Status:** verify-only (landed — see spec header 2026-09-28)

- [ ] Single coercion point still maps every out-of-range raw to normal with byte-identical production behavior (both descriptor constructors, read-back agreement unchanged)
- [ ] DEBUG builds emit a warning naming the coerced raw value, following the established `#if DEBUG` warning style used elsewhere in the codebase; release builds emit nothing
- [ ] `@objc` surface frozen (no signature rename, removal, deprecation, or new failure mode)
- [ ] Existing coercion suites (out-of-range-to-normal, read-back agreement, explicit-at-view) pass unchanged with zero test edits
