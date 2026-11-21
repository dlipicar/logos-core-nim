# Test builds only: the hooks of the test-hook rule (sdk/src/logos_sdk/base/testhooks.nim;
# D27 revised 2026-11-13). No package, app or `build_*` task compiles from here.
switch("define", "lcnTestHooks")
# [DECISIONS G438] An in-process confined kit aborts when its destroy left something registered
# with its module thread's dispatcher. Set here and on kitbuild's command line only, never in the
# root config.nims, which every build reads.
switch("define", "lcnKitStrictDestroy")
