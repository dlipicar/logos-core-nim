## Builds a child program for a suite once per test process, with this build's
## memory manager, mode and sanitizer (the `kitbuild.nim` variant), so the
## child always runs under the suite's sanitizer (`peerbuild.nim`,
## `modulehostbuild.nim`; Tier 4b step 4b-3 plan §4.1).
##
## Test processes running at once share the output and its nimcache: each
## builds under an exclusive lock on `build.lock` into its own file, then
## renames it over the old one, so no process ever runs a half-written child.

import std/[os, osproc, posix]
import ./kitbuild

export kitbuild

const repoDir = currentSourcePath().parentDir.parentDir.parentDir

proc buildChild*(source, name, subdir: string, defines: seq[string] = @[]): string =
  ## `source` (relative to the repository) as `build/<subdir>/<variant>/<name>`.
  let dir = repoDir / "build" / subdir / kitVariant
  createDir(dir)
  let exe = dir / name
  let fresh = exe & ".tmp-" & $getCurrentProcessId()
  var args = @[getCurrentCompilerExe(), "c", "--hints:off", "--mm:" & kitMm]
  when defined(release):
    args.add("-d:release")
  when kitSanitizer.len > 0:
    args.add("-d:" & kitSanitizer)
  for d in defines:
    args.add("-d:" & d)
  args.add(["--nimcache:" & dir / "nimcache", "-o:" & fresh, repoDir / source])
  let lock =
    posix.open(cstring(dir / "build.lock"), O_RDWR or O_CREAT or O_CLOEXEC, 0o644)
  doAssert lock >= 0, "build.lock: " & osErrorMsg(osLastError())
  doAssert lockf(lock, F_LOCK, 0) == 0, "build.lock: " & osErrorMsg(osLastError())
  let (output, code) = execCmdEx(quoteShellCommand(args))
  if code == 0:
    moveFile(fresh, exe)
  discard posix.close(lock) # releases the lock
  doAssert code == 0, "building " & name & " failed:\n" & output
  exe
