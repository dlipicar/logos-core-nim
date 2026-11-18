# Test builds only: the hooks of the test-hook rule (sdk/src/logos_sdk/base/testhooks.nim;
# D27 revised 2026-11-13). No package, app or `build_*` task compiles from here.
switch("define", "lcnTestHooks")

# The TLS suite on Windows builds BoringSSL's portable C: the Windows leg has no nasm for its
# assembly (DECISIONS I99; to revisit at M12 for real Windows deployments).
when defined(windows):
  switch("define", "BORINGSSL_USE_ASM=false")
