# The SDK's erasure suite (DECISIONS I92; as tests/test_wipe_routes.nims): the free scan needs
# the audit build and the Nim heap on malloc, which reaches `free` under orc and arc.
# Test builds only (the test-hook rule, sdk/src/logos_sdk/base/wipeaudit.nim).
switch("define", "useMalloc")
switch("define", "lcnWipeAudit")
when defined(linux):
  # Kits loaded with dlopen find the executable's scan registry (wipeaudit.c).
  switch("passL", "-rdynamic")
