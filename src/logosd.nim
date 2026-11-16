## logosd: the host of one Runtime, outside the participant model (Tier 4b
## step 4b-6; DECISIONS G88, G146, G302; BOOTSTRAP l.100-104).
## docs/DAEMON.md.
##
##   logosd [--session-dir DIR] [--log-level error|warn|info] [--version]
##
## This file is the process part of the start sequence: the session (1), its
## lock (2), the signal mask and thread (3), the wait (12) and the exit.
## Steps 4 to 10 are `daemon/assemble.nim`'s.
##
## | Exit | Meaning |
## |---|---|
## | 0 | clean shutdown |
## | 1 | usage, session, configuration, trust or evidence-key binding refused |
## | 2 | `create`, register or `start` failed |
## | 3 | the shutdown or `destroy` reported an error |
## | 4 | the Module Loader failed after start: termination required (E1) |

{.push raises: [].}

import std/[os, parseopt, strutils]
import results
import ./logos_core/daemon/version

proc say(text: string) =
  try:
    stderr.writeLine(text)
  except IOError:
    discard

when defined(posix):
  import std/[locks, posix]
  import ./logos_core/abi/host as abihost
  import ./logos_core/durable
  import ./logos_core/runtime/host
  import ./logos_core/daemon/[assemble, evstore, logging, session]

  const Usage =
    "usage: logosd [--session-dir DIR] [--log-level error|warn|info] [--version]"

  type SigState = object
    ## What the signal thread acts on, under `lock`: each of its Host API
    ## calls holds it, and `destroying` ends them before the first destroy
    ## (RUNTIME l.3984).
    lock: Lock
    rt: ptr LogosRuntimeHandle
    supervisor: Supervisor
    terms: int
    destroying: bool
    stopping: bool

  var sig: SigState
  initLock(sig.lock)

  proc daemonSignals(): Sigset =
    discard sigemptyset(result)
    for s in [SIGTERM, SIGINT, SIGHUP, SIGUSR1, SIGUSR2]:
      discard sigaddset(result, s)

  proc sigMain(_: int) {.thread.} =
    var set = daemonSignals()
    while true:
      var s: cint = 0
      if sigwait(set, s) != 0:
        continue
      withLock sig.lock:
        if s == SIGUSR2:
          if sig.stopping:
            break
          continue
        if sig.destroying:
          logInfo("signal " & $s & " ignored: the daemon is ending")
          continue
        if s == SIGTERM or s == SIGINT:
          inc sig.terms
          let name = if s == SIGTERM: "SIGTERM" else: "SIGINT"
          if sig.terms == 1:
            logInfo(name & ": shutting down")
            if sig.rt != nil:
              discard runtimeRequestShutdown(sig.rt)
          else:
            logInfo(name & ": shutdown in progress")
        elif s == SIGHUP:
          logInfo("SIGHUP: configuration changes apply at the next start")
        elif s == SIGUSR1:
          if sig.supervisor != nil and sig.rt != nil:
            discard onLoaderLoss(sig.supervisor, sig.rt)

  when defined(lcnTestHooks):
    import std/[atomics, monotimes, times]

    var timerStop: Atomic[bool]

    proc timerMain(arg: (ptr LogosRuntimeHandle, int)) {.thread.} =
      ## [G300] `test_hooks.loader_failure_after_ms`, in a test build only.
      let (rt, ms) = arg
      let until = getMonoTime() + initDuration(milliseconds = ms)
      while getMonoTime() < until:
        if timerStop.load:
          return
        sleep(5)
      withLock sig.lock:
        if sig.destroying:
          return
        logWarn("test hook: the Module Loader reports its failure now")
        failLoaderForTests(rt).isOkOr:
          logError("test hook: " & error)

  proc run(sessionFlag: string): int =
    # 1. The session.
    let s = resolveSession(sessionFlag).valueOr:
      logError(error)
      return ExitRefused
    checkSession(s).isOkOr:
      logError(error)
      return ExitRefused
    # 2. Its lock.
    var lock = lockSession(s).valueOr:
      logError(error)
      return ExitRefused
    # 3. The mask, before any thread exists, so every thread inherits it.
    var set = daemonSignals()
    var old: Sigset
    discard pthread_sigmask(SIG_BLOCK, set, old)
    discard signal(SIGPIPE, SIG_IGN)
    var sigThread: Thread[int]
    try:
      createThread(sigThread, sigMain, 0)
    except ResourceExhaustedError as e:
      logError("cannot start the signal thread: " & e.msg)
      lock.release()
      return ExitRefused
    proc stopSignals() =
      withLock sig.lock:
        sig.stopping = true
      discard kill(getpid(), SIGUSR2)
      joinThread(sigThread)

    # 4-9.
    var d = assembleDaemon(
      s, AssembleOptions(exe: getAppFilename(), version: lcnVersion)
    ).valueOr:
      logError(error.message)
      stopSignals()
      lock.release()
      return error.exit
    var early = false
    withLock sig.lock:
      sig.rt = d.rt
      sig.supervisor = d.supervisor
      early = sig.terms > 0
    if early:
      discard runtimeRequestShutdown(d.rt)
    # 10, 11.
    let started = startDaemon(d)
    if started.isErr:
      withLock sig.lock:
        sig.destroying = true
        early = sig.terms > 0
      stopSignals()
      d.release()
      lock.release()
      if early:
        logInfo("stopped during start")
        return ExitClean
      logError(started.error.message)
      return started.error.exit
    when defined(lcnTestHooks):
      var timer: Thread[(ptr LogosRuntimeHandle, int)]
      var timing = false
      let after = d.prepared.config.hooks.loaderFailureAfterMs
      if after.isSome:
        try:
          createThread(timer, timerMain, (d.rt, int(after.get)))
          timing = true
        except ResourceExhaustedError as e:
          logError("cannot start the test hook timer: " & e.msg)
    # 12.
    let waited = runtimeWaitForShutdown(d.rt)
    when defined(lcnTestHooks):
      timerStop.store(true)
      if timing:
        joinThread(timer)
    if d.supervisor.loaderLost.isSome:
      # [G302; RUNTIME l.3823-3824, l.3985] No destroy: hosts confirmed gone
      # by their restart locks, then the process ends.
      withLock sig.lock:
        sig.destroying = true
      stop(d.store) # [G301] what was offered is written before the exit
      let held = confirmHostsGone(s.workDir)
      logError(
        "exiting with " & $ExitLoaderLost &
          ": the Module Loader failed and this process must end" & (
          if held.len > 0: " (" & $held.len & " Module Host locks still held)"
          else: ""
        )
      )
      # The session lock is not released: the orphaned in-process code still
      # runs until the process is gone, and the kernel drops the `flock` then
      # (RUNTIME l.3824, l.2641). Released earlier, an offline writer or a
      # second logosd could hold the session beside it.
      exitnow(cint(ExitLoaderLost))
    withLock sig.lock:
      sig.destroying = true # [R16] before the first destroy attempt
    stopSignals()
    var code = ExitClean
    if int64(waited.code) != 0:
      logError(
        "shutdown: " & (if waited.message != nil: $waited.message
        else: $waited.code)
      )
      code = ExitShutdownError
    destroyRuntime(d).isOkOr:
      logError(error)
      code = ExitShutdownError
    d.release()
    if entryExists(d.socketPath):
      discard tryRemoveFile(d.socketPath)
    lock.release()
    if code == ExitClean:
      logInfo("stopped")
    code

proc main(): int =
  var sessionFlag = ""
  var level = "info"
  var p = initOptParser(
    commandLineParams(), shortNoVal = {'h'}, longNoVal = @["version", "help"]
  )
  while true:
    p.next()
    case p.kind
    of cmdEnd:
      break
    of cmdLongOption, cmdShortOption:
      case p.key
      of "session-dir":
        sessionFlag = p.val
      of "log-level":
        level = p.val
      of "version":
        echo "logosd " & lcnVersion
        return 0
      of "help", "h":
        when defined(posix):
          echo Usage
        return 0
      else:
        say("logosd: unknown option --" & p.key)
        return 1
    of cmdArgument:
      say("logosd: unexpected argument " & p.key)
      return 1
  when defined(posix):
    let l = parseLevel(level).valueOr:
      say("logosd: " & error)
      return ExitRefused
    setLogLevel(l)
    run(sessionFlag)
  else:
    discard sessionFlag
    discard level
    say(
      "logosd: not supported on this platform (the logosctl socket needs unix-stream)"
    )
    2

when isMainModule:
  quit(main())

{.pop.}
