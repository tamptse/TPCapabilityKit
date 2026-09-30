# N6-01: Collapse lease integer mapping to Bridge single truth

**What to build:** The duplicate Swift-side integer view of lifecycle state is gone; the transition matrix keys by the lifecycle enum directly, and the exhaustive translation co-located with the Bridge live view stands as the sole integer truth.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] Swift-side integer view removed; no production path depends on it
- [ ] Matrix suite keys by enum identity with identical accepted-vs-rejected outcomes; Bridge state reads unchanged and exhaustive
- [ ] Full suite green (build plus decision-table, matrix, and Bridge lifecycle filters)
