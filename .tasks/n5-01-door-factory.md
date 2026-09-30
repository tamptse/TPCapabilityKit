# N5-01: Own subscribe lifetime inside door factory

**What to build:** Door exposes one lifetime-owning factory per subscribe grain that builds the boxed sink, attaches it, and returns the lifetime token directly with unchanged given-or-main delivery.

**Blocked by:** n2-01, n2-02 (same door region under active reshaping; start only once that region is stable).

**Status:** ready-for-agent

- [ ] Two narrow factory members share one private sink core; queue policy plus boxing plus attachment plus token ownership live in the door
- [ ] Signatures for ObjC-adjacent grains unchanged in behavior; timeout fork and wait core untouched
- [ ] Delivery-unify plus single-view suites green; rebase check confirms no same-region drift at start
