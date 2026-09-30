# N2-02: Bridge detach via identifier with fake adapter removed

**What to build:** Bridge detach passes the identifier string straight to the identifier-keyed seam with no fake plugin adapter in the path; public Bridge shapes stay unchanged and detach still never provisions capabilities.

**Blocked by:** N2-01 add identifier-keyed detach seam with thin forwarder

**Status:** ready-for-agent

- [ ] No fake detach adapter type and no detach factory remain
- [ ] Bridge detach delegates directly by identifier with no guard of its own
- [ ] Register then detach then query reads absent through the Bridge path
- [ ] Public Bridge register, unregister, and remove shapes unchanged
- [ ] Full test suite green
