# The TLS suite (DECISIONS I99, G276): the free scan of the erasure case needs the audit
# build and the Nim heap on malloc, which reaches `free` under orc and arc. Test builds only
# (the test-hook rule, sdk/src/logos_sdk/base/wipeaudit.nim).
switch("define", "useMalloc")
switch("define", "lcnWipeAudit")
# [G410] The test copy of the TLS key (owner decision B1: tests only).
switch("define", "logosTestSigning")
