## logosd's reaction to a Module Loader failure after start (Tier 4b step
## 4b-6; E1; DECISIONS G249, G302, G304; RUNTIME l.3823-3824, l.3985).
## docs/DAEMON.md §15.
##
## 1. The engine calls `terminationHook` on a Runtime thread with the
##    in-process realizations left unresolved. The hook copies them into the
##    supervisor and notifies (logosd: SIGUSR1 to its signal thread); it never
##    calls into the engine.
## 2. `onLoaderLoss` logs the loss and requests shutdown.
## 3. The wait returns MODULE_ERROR ("…; the Module Loader failed: the host
##    process must end").
## 4. `confirmHostsGone`: the Runtime's own supervision already ended every
##    Module Host (`loaderLost` → `endHost`); each is confirmed gone by its
##    restart lock in `work/hosts/` becoming free, polled every 20 ms for at
##    most 10 s. A lock still held is logged.
## 5. logosd never calls `runtimeDestroy` after a loss, which stays NOT_READY
##    (l.3985): it flushes, releases the session lock and `_exit(4)`s, so the
##    orphaned in-process realizations end with the process, and the service
##    manager restarts it (decision 5).

{.push raises: [], gcsafe.}

import std/[locks, monotimes, os, strutils, times]
import results
from ../runtime/host import runtimeRequestShutdown
from ../abi/host as abihost import LogosRuntimeHandle
import ./logging

when defined(posix):
  import std/posix

  proc flock(fd: cint, op: cint): cint {.importc, header: "<sys/file.h>".}

export results

const
  ConfirmPollMs* = 20 ## [IMPL]
  ConfirmTimeoutMs* = 10_000 ## [IMPL] the host confirmation's bound

type
  NotifyFn* = proc() {.nimcall, gcsafe, raises: [].}
    ## Wakes whoever runs `onLoaderLoss`; must be async-signal-safe enough
    ## for a Runtime thread (no engine call).

  SupervisorObj = object
    lock: Lock
    lost: bool
    unresolved: ptr UncheckedArray[char]
    unresolvedLen: int
    notify: NotifyFn

  Supervisor* = ptr SupervisorObj

proc raiseUsr1() {.nimcall, gcsafe, raises: [].} =
  ## [G302] logosd's notification: SIGUSR1 to its own signal thread.
  when defined(posix):
    discard kill(getpid(), SIGUSR1)

proc newSupervisor*(notify: NotifyFn = raiseUsr1): Supervisor =
  result = cast[Supervisor](allocShared0(sizeof(SupervisorObj)))
  initLock(result.lock)
  result.notify = notify

proc freeSupervisor*(sv: Supervisor) =
  if sv == nil:
    return
  if sv.unresolved != nil:
    deallocShared(sv.unresolved)
  deinitLock(sv.lock)
  deallocShared(sv)

proc terminationHook*(
    data: pointer, unresolved: seq[string]
) {.nimcall, gcsafe, raises: [].} =
  ## [G304] The engine's termination hook: `data` is the `Supervisor`. Copies
  ## and notifies; never calls into the engine.
  let sv = cast[Supervisor](data)
  if sv == nil:
    return
  let text = unresolved.join("\n")
  withLock sv.lock:
    if sv.lost:
      return
    sv.lost = true
    if text.len > 0:
      sv.unresolved = cast[ptr UncheckedArray[char]](allocShared(text.len))
      copyMem(sv.unresolved, unsafeAddr text[0], text.len)
      sv.unresolvedLen = text.len
  if sv.notify != nil:
    sv.notify()

proc loaderLost*(sv: Supervisor): Opt[seq[string]] =
  ## The unresolved instances, once the hook fired.
  withLock sv.lock:
    if not sv.lost:
      return Opt.none(seq[string])
    var text = newString(sv.unresolvedLen)
    if sv.unresolvedLen > 0:
      copyMem(addr text[0], sv.unresolved, sv.unresolvedLen)
    return Opt.some(
      if text.len == 0:
        @[]
      else:
        text.split('\n')
    )

proc onLoaderLoss*(sv: Supervisor, rt: ptr LogosRuntimeHandle): bool =
  ## Step 2: logs the loss and requests shutdown. False when no loss was
  ## reported.
  let ids = sv.loaderLost.valueOr:
    return false
  let names =
    if ids.len == 0:
      "no in-process instance"
    else:
      ids.join(", ")
  logError("the Module Loader failed; termination required for " & names)
  discard runtimeRequestShutdown(rt)
  true

proc heldLocks*(workDir: string): seq[string] =
  ## The restart locks in `work/hosts/` some process still holds, by file
  ## name.
  when defined(posix):
    let dir = workDir / "hosts"
    var names: seq[string]
    try:
      for kind, p in walkDir(dir, relative = true):
        if kind == pcFile and p.endsWith(".lock"):
          names.add(p)
    except OSError:
      return
    for n in names:
      let fd = posix.open(cstring(dir / n), O_RDWR or O_CLOEXEC)
      if fd < 0:
        continue
      if flock(fd, cint(2) or cint(4)) != 0:
        result.add(n)
      discard posix.close(fd)

proc confirmHostsGone*(workDir: string, timeoutMs = ConfirmTimeoutMs): seq[string] =
  ## Step 4: polls until every restart lock is free; the ones still held at
  ## the bound, each logged.
  let until = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while true:
    let held = heldLocks(workDir)
    if held.len == 0:
      return @[]
    if getMonoTime() >= until:
      for n in held:
        logError("a Module Host's restart lock is still held: " & workDir / "hosts" / n)
      return held
    sleep(ConfirmPollMs)

{.pop.}
