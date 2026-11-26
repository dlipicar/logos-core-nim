## logosd and logosctl for `test_logosd` (Tier 4b step 4b-6; plan §4.4):
## built once per test process with the suite's memory manager, mode and
## sanitizer (`childbuild.buildChild`). logosd is a test build
## (`-d:lcnTestHooks`: the Loader-loss and delay cases select its hooks);
## logosctl has no hooks. `LCN_LOGOSD` and `LCN_LOGOSCTL` may name prebuilt
## binaries (`logosd-smoke` only).

import std/os
import ./childbuild

var builtD, builtCtl, builtHolder, builtRemote: string

proc logosdProgram*(): string =
  if builtD.len > 0:
    return builtD
  let given = getEnv("LCN_LOGOSD")
  builtD =
    if given.len > 0 and fileExists(given):
      absolutePath(given)
    else:
      buildChild("src/logosd.nim", "logosd", "logosd", @["lcnTestHooks"])
  builtD

proc logosctlProgram*(): string =
  if builtCtl.len > 0:
    return builtCtl
  let given = getEnv("LCN_LOGOSCTL")
  builtCtl =
    if given.len > 0 and fileExists(given):
      absolutePath(given)
    else:
      buildChild("src/logosctl.nim", "logosctl", "logosctl")
  builtCtl

proc keyholderProgram*(): string =
  ## [G410, Tier 5 step 5-7a-1] `logos_keyholder`, a program logosd starts,
  ## with its test hook (the frozen limit clock, `daemon/keyholder.nim`).
  if builtHolder.len == 0:
    builtHolder = buildChild(
      "src/logos_keyholder.nim", "logos_keyholder", "logos_keyholder", @["lcnTestHooks"]
    )
  builtHolder

proc remoteProgram*(): string =
  ## [G411, Tier 5 step 5-7a-2] `logos_remote`, a program logosd starts, with
  ## its test hooks (the wedged-loop test's).
  if builtRemote.len == 0:
    builtRemote = buildChild(
      "src/logos_remote.nim", "logos_remote", "logos_remote", @["lcnTestHooks"]
    )
  builtRemote
