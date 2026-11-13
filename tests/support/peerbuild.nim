## Builds `tests/support/trnpeer.nim`, the child-process peer of
## `test_transport_io`, with this build's memory manager, mode and sanitizer
## (the `kitbuild.nim` variant), so the peer always runs under the same
## sanitizer as the suite.

import std/[os, osproc, posix]
import ./kitbuild

const supportDir = currentSourcePath().parentDir

var built: string

proc peerProgram*(): string =
  ## The peer executable, built once per test process. Test processes running
  ## at once share it and its nimcache: each builds under an exclusive lock on
  ## `build.lock` into its own file, then renames it over the old one, so no
  ## process ever runs a half-written peer.
  if built.len > 0:
    return built
  let dir = supportDir.parentDir.parentDir / "build" / "peer" / kitVariant
  createDir(dir)
  let exe = dir / "trnpeer"
  let fresh = exe & ".tmp-" & $getCurrentProcessId()
  var args = @[getCurrentCompilerExe(), "c", "--hints:off", "--mm:" & kitMm]
  when defined(release):
    args.add("-d:release")
  when kitSanitizer.len > 0:
    args.add("-d:" & kitSanitizer)
  args.add(
    ["--nimcache:" & dir / "nimcache", "-o:" & fresh, supportDir / "trnpeer.nim"]
  )
  let lock =
    posix.open(cstring(dir / "build.lock"), O_RDWR or O_CREAT or O_CLOEXEC, 0o644)
  doAssert lock >= 0, "build.lock: " & osErrorMsg(osLastError())
  doAssert lockf(lock, F_LOCK, 0) == 0, "build.lock: " & osErrorMsg(osLastError())
  let (output, code) = execCmdEx(quoteShellCommand(args))
  if code == 0:
    moveFile(fresh, exe)
  discard posix.close(lock) # releases the lock
  doAssert code == 0, "building trnpeer failed:\n" & output
  built = exe
  exe
