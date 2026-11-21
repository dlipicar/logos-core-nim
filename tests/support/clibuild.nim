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
      )
  built

proc cliArtifact*(): LcnAppArtifact =
  ## [G343] The library as `cli.artifact`, with its BLAKE3-256 hash.
  let path = cliLibrary()
  var h: Blake3Hasher
  h.init()
  let bytes =
    try:
      readFile(path)
    except IOError as e:
      raiseAssert path & ": " & e.msg
  h.update(bytes.toOpenArrayByte(0, bytes.high))
  LcnAppArtifact(id: "lcn_call", local_path: path, hash: @(h.finish()))
