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

# [IMPL-DECISION G409] The link drops what nothing reaches. logosd signs with
# the Runtime's TLS key through `transport/tls/p256.nim`, which calls BoringSSL's
# libcrypto only, but the binding compiles libssl's sources into every program
# that imports it. Dead stripping leaves logosd with no libssl code (checked on
# the binary: test_logosd and the flake check `logosd-no-ssl`), while its link
# line still names libssl's objects. Nothing resolves symbols from logosd: it is
# linked without -rdynamic or -export_dynamic. Not on Windows, where logosd is
# not built.
when defined(macosx):
  {.passl: "-Wl,-dead_strip".}
elif defined(linux):
  {.passl: "-Wl,--gc-sections".}

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
  import logos_sdk/abi/host as abihost
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

    proc timerMain(arg: (ptr LogosRuntimeHandle, int, cstring)) {.thread.} =
      ## [G300] `test_hooks.loader_failure_after_ms` (`ms` >= 0) and
      ## `loader_failure_on_file` (`file` not nil), in a test build only:
      ## whichever comes first.
      let (rt, ms, file) = arg
      let until = getMonoTime() + initDuration(milliseconds = max(ms, 0))
      while true:
        if timerStop.load:
          return
        if ms >= 0 and getMonoTime() >= until:
          break
        if file != nil and access(file, F_OK) == 0:
          break
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
      let injected = d.prepared.config.hooks.diagnostics
      if injected.isSome:
        # Between the start's read and the thread's first: the ring wraps
        # when `count` exceeds it.
        diagnoseForTests(d.rt, injected.get.text, int(injected.get.count)).isOkOr:
          logError("test hook: " & error)
    # [I95 amended 2026-11-16] The Runtime's diagnostics while it runs.
    var draining: DrainThread
    draining.startDraining(d.diagnostics, d.rt).isOkOr:
      logError(error)
    when defined(lcnTestHooks):
      var timer: Thread[(ptr LogosRuntimeHandle, int, cstring)]
      var timing = false
      var file: cstring = nil # on the shared heap: the timer's thread reads it
      let after = d.prepared.config.hooks.loaderFailureAfterMs
      let on = d.prepared.config.hooks.loaderFailureOnFile
      if on.isSome:
        file = cast[cstring](allocShared0(on.get.len + 1))
        copyMem(file, on.get.cstring, on.get.len)
      if after.isSome or on.isSome:
        let ms =
          if after.isSome:
            int(after.get)
          else:
            -1
        try:
          createThread(timer, timerMain, (d.rt, ms, file))
          timing = true
        except ResourceExhaustedError as e:
          logError("cannot start the test hook timer: " & e.msg)
    # 12.
    let waited = runtimeWaitForShutdown(d.rt)
    when defined(lcnTestHooks):
      timerStop.store(true)
      if timing:
        joinThread(timer)
      if file != nil:
        deallocShared(file)
    # What shutdown or the Loader's failure recorded, before any exit.
    draining.stopDraining(d.diagnostics)
    d.diagnostics.drainNow(d.rt)
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
