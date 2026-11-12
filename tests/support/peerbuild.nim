## Builds `tests/support/trnpeer.nim`, the child-process peer of
## `test_transport_io`, with this build's memory manager, mode and sanitizer
## (the `kitbuild.nim` variant), so the peer always runs under the same
## sanitizer as the suite.

import std/[os, osproc]
import ./kitbuild

const supportDir = currentSourcePath().parentDir

var built: string

proc peerProgram*(): string =
  ## The peer executable, built once per test process.
  if built.len > 0:
    return built
  let dir = supportDir.parentDir.parentDir / "build" / "peer" / kitVariant
  createDir(dir)
  let exe = dir / "trnpeer"
  var args = @[getCurrentCompilerExe(), "c", "--hints:off", "--mm:" & kitMm]
  when defined(release):
    args.add("-d:release")
  when kitSanitizer.len > 0:
    args.add("-d:" & kitSanitizer)
  args.add(["--nimcache:" & dir / "nimcache", "-o:" & exe, supportDir / "trnpeer.nim"])
  let (output, code) = execCmdEx(quoteShellCommand(args))
  doAssert code == 0, "building trnpeer failed:\n" & output
  built = exe
  exe
