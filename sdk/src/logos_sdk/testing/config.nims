# Test builds only: the hooks of the test-hook rule (sdk/src/logos_sdk/base/testhooks.nim;
# D27 revised 2026-11-13). No package, app or `build_*` task compiles from here: the kit
# fixtures below are built as libraries by the test suites, as they were under tests/.
switch("define", "lcnTestHooks")
