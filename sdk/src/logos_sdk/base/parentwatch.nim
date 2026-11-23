## [IMPL-DECISION G264, amended 2026-11-21; G411] A child that the Runtime
## spawns binds its life to the Runtime's process: the Module Host
## (`logos-module-host`) and, from Tier 5 step 5-7a-2, the remote program
## (`logos_remote`).
##
## The spawner puts its own pid on the child's command line as
## `--parent=<pid>` (`hostsup.spawnProcess`, `runSpawns`), so the child can
## tell its parent from an adopter. `posix_spawn` runs nothing in the child
## before `exec` (`hostspawn.c`), so the child registers the parent watch
## itself, first, and only then compares `getppid()` with that pid. Comparing
## `getppid()` with an earlier `getppid()` instead misses a parent that ended
## before the first call: both calls then return the same adopter.
##
## On Linux the watch is `PR_SET_PDEATHSIG(SIGKILL)`, which fires when the
## *thread* that spawned the child ends, so the spawner spawns from a thread
## that lives as long as the Runtime (G265). Elsewhere there is no such call,
## and `bindToParent` only compares; a child that must also notice its
## parent's end later watches it itself (5-7a-2).

{.push raises: [], gcsafe.}

import std/strutils
import results

when defined(posix):
  import std/posix

export results

const ParentFlag* = "--parent="
  ## The command-line argument the spawner adds, followed by its pid in decimal.

proc parentArg*(args: openArray[string]): Opt[int] =
  ## The pid of the first `--parent=<pid>` argument: a positive decimal that fits
  ## `pid_t`, with nothing after it. None when no argument is one.
  for a in args:
    if a.startsWith(ParentFlag):
      let digits = a.len - ParentFlag.len
      if digits == 0 or digits > 10:
        return Opt.none(int)
      var pid = 0
      # Indexed, not `toOpenArray`: under orc that prepares the element for
      # mutation, which faults on a literal array (upstream ISSUES.md 193).
      for i in ParentFlag.len ..< a.len:
        if a[i] notin Digits:
          return Opt.none(int)
        pid = pid * 10 + (ord(a[i]) - ord('0'))
      if pid <= 0 or pid > int(high(int32)):
        return Opt.none(int)
      return Opt.some(pid)
  Opt.none(int)

when defined(linux):
  proc prctl(
    option: cint, arg2: culong, arg3, arg4, arg5: culong = 0
  ): cint {.importc, header: "<sys/prctl.h>", varargs.}

  const PrSetPdeathsig = cint(1)

proc bindToParent*(parent: int): Result[void, string] =
  ## Linux: SIGKILL when the spawning thread ends, then the parent compared
  ## with `parent`. Elsewhere on POSIX: the comparison only. An error means
  ## the parent is gone (this process was adopted) or the signal could not be
  ## set: the caller exits at once.
  when defined(posix):
    when defined(linux):
      if prctl(PrSetPdeathsig, culong(SIGKILL)) != 0:
        return err("the parent-death signal cannot be set: " & $strerror(errno))
    if int(getppid()) != parent:
      return err("the parent " & $parent & " is gone")
    ok()
  else:
    err("not supported on this platform")
