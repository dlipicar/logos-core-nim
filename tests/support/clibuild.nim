## liblcn_call, the CLI module's library, for the suites that run logosd with
## its `lcn_call` instance (Tier 5 step N-2b; DECISIONS G343): built once per
## test process with the suite's memory manager, mode and sanitizer
## (`logos_sdk/testing/kitbuild`), with its own `NimMain` prefix, no signal
## handlers (G340) and its export list (G341). `LCN_CALL_LIBRARY` may name a
## prebuilt one (`logosd-smoke` only).
##
## `cliArtifact` is the `cli.artifact` value a test session gives logosd: a test
## logosd is built without the packaged library's hash, so it composes
## `lcn_call` only from that field.

import std/os
import logos_sdk/crypto/blake3
import logos_sdk/testing/kitbuild
import ../../src/logos_core/daemon/daemon_config_types

export kitbuild

const cliRepo = currentSourcePath().parentDir.parentDir.parentDir

var built: string

# The source is in src/, which reads no tests/config.nims: the test hooks the suites use
# (the watch's, `LCN_TEST_CLI_WATCH`, PKG-0555) are named here, as `pmbuild` does.
const hooks: seq[string] =
  when defined(lcnTestHooks):
    @["lcnTestHooks"]
  else:
    @[]

proc cliLibrary*(): string =
  ## The library's absolute path.
  if built.len > 0:
    return built
  let given = getEnv("LCN_CALL_LIBRARY")
  built =
    if given.len > 0 and fileExists(given):
      absolutePath(given)
    else:
      buildKitLibraryIn(
        KitTree(
          sources: @[cliRepo / "src"],
          generated: @[cliRepo / "src" / "logos_core" / "cli"],
          build: cliRepo / "build" / "cli-lib",
        ),
        "lcn_call.nim",
        "lcn_call",
        exports = "lcn_call",
        defines = hooks,
      )
  built

var rebuilt: string

proc cliLibraryRebuilt*(): string =
  ## [G505] A second build of the same source with another `NimMain` prefix: other bytes,
  ## the same module and export list. Built under `build/cli-lib-b/`, once per test process.
  if rebuilt.len > 0:
    return rebuilt
  rebuilt = buildKitLibraryIn(
    KitTree(
      sources: @[cliRepo / "src"],
      generated: @[cliRepo / "src" / "logos_core" / "cli"],
      build: cliRepo / "build" / "cli-lib-b",
    ),
    "lcn_call.nim",
    "lcn_call_b",
    exports = "lcn_call",
    defines = hooks,
  )
  rebuilt

proc cliArtifact*(path = cliLibrary()): LcnAppArtifact =
  ## [G343] The library at `path` as `cli.artifact`, with its BLAKE3-256 hash.
  var h: Blake3Hasher
  h.init()
  let bytes =
    try:
      readFile(path)
    except IOError as e:
      raiseAssert path & ": " & e.msg
  h.update(bytes.toOpenArrayByte(0, bytes.high))
  LcnAppArtifact(id: "lcn_call", local_path: path, hash: @(h.finish()))
