## liblogos_package_manager, the Package Manager module's library, for the suites
## that host it (Tier 5 step 5-6a-1; DECISIONS G491, G494): built once per test
## process with the suite's memory manager, mode and sanitizer
## (`logos_sdk/testing/kitbuild`), with its own `NimMain` prefix, no signal handlers
## (G340) and its export list (G341), as `clibuild.nim` builds liblcn_call.
## `LCN_PM_LIBRARY` may name a prebuilt one (`logosd-smoke` only).
##
## `pmArtifact` is the `package_manager.artifact` value a test session gives logosd: a
## test logosd is built without the packaged library's hash, so it composes the
## Package Manager only from that field.

import std/os
import logos_sdk/crypto/blake3
import logos_sdk/testing/kitbuild
import ../../src/logos_core/daemon/daemon_config_types

export kitbuild

const pmRepo = currentSourcePath().parentDir.parentDir.parentDir

var built: string

proc pmLibrary*(): string =
  ## The library's absolute path.
  if built.len > 0:
    return built
  let given = getEnv("LCN_PM_LIBRARY")
  # The source is in src/, which reads no tests/config.nims: the test hooks the suites
  # use (the extraction pace, PACKAGE-MANAGER.md §9) are named here.
  const hooks: seq[string] =
    when defined(lcnTestHooks):
      @["lcnTestHooks"]
    else:
      @[]
  built =
    if given.len > 0 and fileExists(given):
      absolutePath(given)
    else:
      buildKitLibraryIn(
        KitTree(
          sources: @[pmRepo / "src"],
          generated: @[pmRepo / "src" / "logos_core" / "pm"],
          build: pmRepo / "build" / "pm-lib",
        ),
        "logos_package_manager.nim",
        "logos_package_manager",
        exports = "logos_package_manager",
        defines = hooks,
      )
  built

proc pmArtifact*(path = pmLibrary()): LcnAppArtifact =
  ## [G491] The library at `path` as `package_manager.artifact`, with its BLAKE3-256
  ## hash.
  var h: Blake3Hasher
  h.init()
  let bytes =
    try:
      readFile(path)
    except IOError as e:
      raiseAssert path & ": " & e.msg
  h.update(bytes.toOpenArrayByte(0, bytes.high))
  LcnAppArtifact(id: "logos_package_manager", local_path: path, hash: @(h.finish()))
