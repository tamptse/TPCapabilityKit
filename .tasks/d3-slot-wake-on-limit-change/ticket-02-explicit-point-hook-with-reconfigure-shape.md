# 02: Hook the wake into the explicit point with reconfigure shape preserved

**What to build:** The limit-change consideration is reachable only via the explicit reconfigure/settle point: reconfigure keeps its shape (store the new configuration, thread the caps into the one shared slot domain, append a fresh generation, reap via the explicit point) with identical drain and in-flight behavior, and no count or snapshot read triggers consideration. End-to-end: reconfigure under slot pressure still never doubles the configured limit during drain (sum-vs-share split untouched), generation append-plus-reap outcomes are identical, and the wake fires exactly at the explicit entry — never from a getter.

**Blocked by:** 01 (share the release consideration with limit change plus raise/lower pins); D1 explicit reap/settle points with reconfigure shape preserved (hard, external); D4 pump drain notification hook (transitive via D1, external).

**Status:** ready-for-agent

- [ ] Reconfigure shape preserved: store configuration, thread caps into the shared domain, append generation, reap via the explicit point — in-flight drain, summed counts, precede-first-use gate, and cancel fan-out unchanged
- [ ] Wake reachable only via the explicit reconfigure/settle entries; mechanical grep shows no consideration trigger inside count/snapshot/getter reads and exactly one Store-to-Tasks crossing at the named reap pass
- [ ] Shared-slot-domain suite (reconfigure under pressure never doubles the limit) plus generation wiring suites green with zero test-semantics edits; `swift build` green and full `swift test` green
