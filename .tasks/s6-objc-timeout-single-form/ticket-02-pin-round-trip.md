# 02: Pin the lossy display round-trip and prove single storage at rest

**What to build:** The lossy display derivation is stated once beside the single pin and locked by test, so a future caller knows display-fed rebuild without the explicitness flag promotes unspecified to explicit pin while flag-guarded rebuild preserves the distinction — with mechanical proof that no duplicate timeout store or second pin literal remains.

**Blocked by:** 01 (Collapse descriptor to one stored timeout with three derived readings) — lands after the storage collapse so the round-trip pin and the single-store proof assert the rest state, not the transitional duplication.

**Status:** ready-for-agent

- [ ] Lossy display stated once beside the single pin (absent displays as pin; display alone does not round-trip; the explicitness flag is the disambiguator and the rebuild guide)
- [ ] Round-trip pin passes through existing seams: wrap Swift-absent displays pin flagged non-explicit, rebuild from display alone yields explicit pin, rebuild honoring the flag yields absent again; explicit values round-trip unchanged either way
- [ ] Mechanical proof at rest: no duplicate stored timeout field and no second pin literal remain; full suite green with only the additive round-trip pin plus the single-store check
