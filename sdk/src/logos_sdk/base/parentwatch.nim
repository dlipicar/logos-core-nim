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

when defined(macosx) or defined(freebsd) or defined(openbsd) or defined(netbsd):
  type KEvent {.importc: "struct kevent", header: "<sys/event.h>", pure, final.} = object
    ident: uint
    filter: int16
    flags: uint16
    fflags: uint32
    data: int
    udata: pointer

  proc kqueue(): cint {.importc, header: "<sys/event.h>".}
  proc kevent(
    kq: cint,
    changes: ptr KEvent,
    nchanges: cint,
    events: ptr KEvent,
    nevents: cint,
    timeout: ptr Timespec,
  ): cint {.importc, header: "<sys/event.h>".}

  var
    EvfiltProc {.importc: "EVFILT_PROC", header: "<sys/event.h>".}: int16
    EvAdd {.importc: "EV_ADD", header: "<sys/event.h>".}: uint16
    EvOneshot {.importc: "EV_ONESHOT", header: "<sys/event.h>".}: uint16
    NoteExit {.importc: "NOTE_EXIT", header: "<sys/event.h>".}: uint32

type ParentWatch* = object
  ## [G411; 5-7a plan §3.1 items 1 and 2] What `watchParent` registered, for
  ## the one thread that blocks on it: on BSD systems and macOS a kqueue with
  ## the parent's `NOTE_EXIT`; on Linux nothing (the parent-death signal is
  ## the watch, and the thread watches the control channel instead).
  kq*: cint

proc watchParent*(parent: int): Result[ParentWatch, string] =
  ## [G411] As `bindToParent`, with the watch the remote program's watcher
  ## thread blocks on. On macOS the order matters: `NOTE_EXIT` is registered
  ## on `parent` first (`ESRCH`: it is gone), and only then is `getppid()`
  ## compared, so a parent that ends between the two is not missed.
  when defined(macosx) or defined(freebsd) or defined(openbsd) or defined(netbsd):
    let kq = kqueue()
    if kq < 0:
      return err("no kqueue: " & $strerror(errno))
    var ch = KEvent(
      ident: uint(parent),
      filter: EvfiltProc,
      flags: EvAdd or EvOneshot,
      fflags: NoteExit,
    )
    if kevent(kq, addr ch, 1, nil, 0, nil) != 0:
      let e = errno
      discard posix.close(kq)
      if e == ESRCH:
        return err("the parent " & $parent & " is gone")
      return err("the parent cannot be watched: " & $strerror(e))
    if int(getppid()) != parent:
      discard posix.close(kq)
      return err("the parent " & $parent & " is gone")
    ok(ParentWatch(kq: kq))
  elif defined(posix):
    ?bindToParent(parent)
    ok(ParentWatch(kq: -1))
  else:
    err("not supported on this platform")

proc waitParentEnd*(w: ParentWatch, channel: cint) =
  ## [G411] Blocks until the parent ends (macOS: the kqueue fires) or, on
  ## Linux, until `channel` reports a hang-up; returns then. The caller ends
  ## the process at once.
  when defined(macosx) or defined(freebsd) or defined(openbsd) or defined(netbsd):
    var ev: KEvent
    while true:
      let n = kevent(w.kq, nil, 0, addr ev, 1, nil)
      if n > 0:
        return
      if n < 0 and errno != EINTR:
        return
  elif defined(linux):
    const PollRdhup = cshort(0x2000)
      # POLLRDHUP, which <poll.h> hides without _GNU_SOURCE
    var pfd = TPollfd(fd: channel, events: PollRdhup)
    while true:
      let n = poll(addr pfd, 1, -1)
      if n > 0 and (pfd.revents and (PollRdhup or POLLHUP or POLLERR or POLLNVAL)) != 0:
        return
      if n < 0 and errno != EINTR:
        return
  else:
    discard
