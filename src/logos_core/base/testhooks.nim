## The test-hook rule (D27, revised 2026-11-13 by the owner, batch A item 1;
## DECISIONS I89) [IMPL].
##
## 1. Hook code under `src/` exists only inside `when defined(lcnTestHooks)`.
## 2. Only test builds set the define: `tests/config.nims` does, for every
##    suite; no package, app, nimble `bin` or `build_*` task does.
## 3. Each module that holds hooks calls `testHooksMarker`, which, under the
##    define, puts `TestHooksMarker` in the binary as an exported C constant.
##    The flake check `no-test-hooks` fails when any deployment output holds
##    it, and requires it in a probe built with the define, so the check is
##    not vacuous.
## 4. A hook is inert until the Runtime's host selects it: in an in-process
##    suite, a call by the test.

{.push raises: [].}

const TestHooksMarker* = "LCN_TEST_" & "HOOKS_BUILD"
  ## Joined here so this source never holds the marker itself.

template testHooksMarker*(name: static string) =
  ## Under `lcnTestHooks`, the C symbol `lcn_test_hooks_<name>` holding the
  ## marker; nothing otherwise.
  when defined(lcnTestHooks):
    let lcnTestHooksBuild {.exportc: "lcn_test_hooks_" & name, used.}: cstring =
      TestHooksMarker

{.pop.}
