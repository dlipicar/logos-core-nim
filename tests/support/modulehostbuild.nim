## The `logos-module-host` program for the hosted suites (Tier 4b step 4b-3;
## plan §4.1, R20, R21): built once per test process with the suite's memory
## manager, mode and sanitizer, and without test hooks (the host has none).
## `LCN_TEST_MODULE_HOST` may name a prebuilt one; it is test support only, the
## Runtime never reads the environment for the host.
##
## `hostPids` finds the hosts still running by their executable: a host's
## argv is its bare name (plan §2.3), so a match on the command line would
## count every build's hosts, or none.

import std/[os, strutils]
import ./childbuild

var built: string

proc moduleHostProgram*(): string =
  ## The host executable: an absolute path, as `runtime.module_host` is.
  if built.len > 0:
    return built
  let given = getEnv("LCN_TEST_MODULE_HOST")
  built =
    if given.len > 0 and fileExists(given):
      absolutePath(given)
    else:
      buildChild("src/logos_module_host.nim", "logos-module-host", "module-host")
  built

when defined(macosx):
  proc procListAllPids(
    buf: pointer, size: cint
  ): cint {.importc: "proc_listallpids", header: "<libproc.h>".}

  proc procPidPath(
    pid: cint, buf: pointer, size: uint32
  ): cint {.importc: "proc_pidpath", header: "<libproc.h>".}

proc hostPids*(program = moduleHostProgram()): seq[int] =
  ## The live processes (zombies excluded) whose executable is `program`.
  let want =
    try:
      expandFilename(program)
    except OSError:
      program
  when defined(macosx):
    var pids = newSeq[cint](16384)
    let n = procListAllPids(addr pids[0], cint(pids.len * sizeof(cint)))
    var buf: array[4096, char]
    for i in 0 ..< min(int(n), pids.len):
      let pid = pids[i]
      if pid > 0 and procPidPath(pid, addr buf[0], uint32(buf.len)) > 0 and
          $cast[cstring](addr buf[0]) == want:
        result.add(int(pid))
  elif defined(linux):
    for kind, path in walkDir("/proc"):
      let name = path.extractFilename
      if kind == pcDir and name.len > 0 and name.allCharsInSet(Digits):
        try:
          if expandSymlink(path / "exe") == want:
            result.add(parseInt(name))
        except OSError, ValueError:
          discard
  else:
    discard
