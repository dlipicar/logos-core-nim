## Builds a `tests/kit/` source as a shared library (`--app:lib`) with this
## build's memory manager and mode, for the suites that load kit modules the way
## a Runtime does (`test_kit_dylib`, `test_realizer`). Each library gets its own
## `--nimMainPrefix`, so its `NimMain` is distinct from the host's and from any
## other library's, and its own nimcache, so suites can build in parallel.

import std/[os, osproc, strutils]

const
  kitMm* =
    when compileOption("mm", "orc"):
      "orc"
    elif compileOption("mm", "refc"):
      "refc"
    elif compileOption("mm", "arc"):
      "arc"
    else:
      {.error: "kitbuild: unknown memory manager".}
  kitVariant* = kitMm & (when defined(release): "-release" else: "")
  kitTestsDir = currentSourcePath().parentDir.parentDir
  nimExe = getCurrentCompilerExe()

proc buildKitLibrary*(source, name: string): string =
  ## `tests/kit/<source>` as `lib<name>` under `build/kit-dylib/<variant>/`.
  let dir = kitTestsDir.parentDir / "build" / "kit-dylib" / kitVariant
  createDir(dir)
  result = dir / (DynlibFormat % name)
  var args = @[nimExe, "c", "--hints:off", "--mm:" & kitMm]
  when defined(release):
    args.add("-d:release")
  args.add(
    [
      "--app:lib",
      "--nimMainPrefix:lib" & name,
      "--nimcache:" & dir / ("nimcache-" & name),
      "-o:" & result,
      kitTestsDir / "kit" / source,
    ]
  )
  let (output, code) = execCmdEx(quoteShellCommand(args))
  doAssert code == 0, "building " & source & " failed:\n" & output
