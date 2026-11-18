# The TLS suite (DECISIONS I99, G327): the free scan of the erasure cases needs the audit
# build and the Nim heap on malloc, which reaches `free` under orc and arc. Test builds only
# (the test-hook rule, sdk/src/logos_sdk/base/wipeaudit.nim).
switch("define", "useMalloc")
switch("define", "lcnWipeAudit")
