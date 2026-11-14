## The Module Host program (`src/logos_module_host.nim`, `src/logos_core/host/`;
## Tier 4b step 4b-3, DECISIONS G264, G266; plan §2.2, §4.3) against a test
## owner of its carrier (`support/hostowner.nim`), with no engine: startup,
## lane 0 (init, apply, release), the ends of the carrier, and the spawn
## (`hostsup.spawnProcess`, through a stand-in program).
##
## The module is `tests/kit/probe_impl.nim`, a consumer-only library that reads
## what to do from its state directory and writes what it saw there. The host
## is built without test hooks (plan R20), under this suite's memory manager
## and sanitizer.

when defined(posix):
  import std/[os, posix, sequtils, strutils]
  import unittest2
  import results
  import ../src/logos_core/iface/outcome
  import ../src/logos_core/runtime/[carrier, hostsup]
  from ../src/logos_core/host/state import ExitCarrierLost
  import ./support/[childbuild, hostowner, modulehostbuild]

  let
    work =
      currentSourcePath().parentDir.parentDir / "build" / "module-host-suite" /
      kitVariant
    host = moduleHostProgram()
    probe = buildKitLibrary("probe_impl.nim", "probe")
  removeDir(work)
  createDir(work)

  var dirs = 0

  proc stateDir(commands: varargs[string]): string =
    ## A fresh state directory whose `probe.cmd` holds `commands`.
    inc dirs
    result = work / ("s" & $dirs)
    createDir(result)
    writeFile(result / "probe.cmd", commands.join("\n") & "\n")

  proc lines(dir, file: string): seq[string] =
    try:
      readFile(dir / file).splitLines.filterIt(it.len > 0)
    except IOError:
      @[]

  proc initMsg(
      dir: string, module = "probe_module", path = probe, live = false
  ): LcnCarrierMessage =
    var m = LcnCarrierInit(
      id: 1, module: module, artifact_path: path, live: live, max_payload_depth: 1024
    )
    if dir.len > 0:
      m.state_dir = Opt.some(dir)
    toMessage(m)

  template kindOf(m: Opt[LcnCarrierMessage]): untyped =
    (if m.isSome: $m.get.kind else: "none")

  proc initialized(r: var HostRun, dir: string, live = false): bool =
    check r.send(initMsg(dir, live = live))
    let m = r.next()
    check m.kindOf == $LcnCarrierMessageKind.lcn_Carrier_initialized
    m.isSome and m.get.kind == LcnCarrierMessageKind.lcn_Carrier_initialized

  proc initFailure(r: var HostRun, m: LcnCarrierMessage): LcnCarrierInitFailed =
    check r.send(m)
    let got = r.next()
    check got.kindOf == $LcnCarrierMessageKind.lcn_Carrier_init_failed
    if got.isSome and got.get.kind == LcnCarrierMessageKind.lcn_Carrier_init_failed:
      result = got.get.arm_lcn_Carrier_init_failed

  proc released(r: var HostRun): bool =
    check r.send(toMessage(LcnCarrierRelease(id: 9)))
    let m = r.next()
    check m.kindOf == $LcnCarrierMessageKind.lcn_Carrier_released
    check r.waitExit()
    m.isSome and r.exitedWith == 0

  proc shellStatus(command: string): int =
    ## The exit status of `sh -c command`.
    let st = execShellCmd(command)
    st

  suite "host.module: startup (plan §2.2)":
    test "[IMPL] H-1 started without a carrier on fd 3, or with fd 3 not a socket: exit 2":
      check shellStatus("exec 3<&- ; exec " & quoteShell(host) & " 2>/dev/null") == 2
      check shellStatus("exec " & quoteShell(host) & " 3</dev/null 2>/dev/null") == 2

  suite "host.module: lane 0 init (LOADER §6)":
    test "[LDR-0040] [LDR-0042] [LDR-0053] H-2 a consumer-only module: initialized without a call surface; its state directory and only the given environment reach it":
      putEnv("LCN_PROBE_SECRET", "not for the host")
      let dir = stateDir("env")
      var r = startHost(host, env = @["LCN_PROBE_PASSED=1"])
      defer:
        r.stop()
      check r.send(initMsg(dir))
      let m = r.next()
      check m.kindOf == $LcnCarrierMessageKind.lcn_Carrier_initialized
      if m.isSome and m.get.kind == LcnCarrierMessageKind.lcn_Carrier_initialized:
        check m.get.arm_lcn_Carrier_initialized.call_surface.isNone
      check lines(dir, "inits") == @["init"]
      let env = lines(dir, "env")
      check "LCN_PROBE_PASSED" in env
      check "LCN_PROBE_SECRET" notin env
      check env.filterIt(it.startsWith("LCN_")) == @["LCN_PROBE_PASSED"]
      check r.released()
      check lines(dir, "destroyed") == @["destroyed"]

    test "[LDR-0072] [LDR-0073] H-3 a module whose name does not match, or no library: init_failed in the bind phase, no init":
      let dir = stateDir()
      block:
        var r = startHost(host)
        defer:
          r.stop()
        let f = r.initFailure(initMsg(dir, module = "other_module"))
        check f.code.kind == LcnCarrierInitFailedCodeChoiceKind.Abi_invalid
        check f.phase.kind == LcnCarrierInitFailedPhaseChoiceKind.Bind
        r.closeCarrier()
        check r.waitExit() and r.exitedWith == 0
      block:
        var r = startHost(host)
        defer:
          r.stop()
        let f = r.initFailure(initMsg(dir, path = work / "missing.so"))
        check f.code.kind == LcnCarrierInitFailedCodeChoiceKind.Artifact_unavailable
        check f.phase.kind == LcnCarrierInitFailedPhaseChoiceKind.Bind
      check lines(dir, "inits").len == 0

    test "[LDR-0078] [LDR-0079] H-4 a failed _MODULE_init, or an invalid result: init_failed in the init phase, no destroy":
      # A failure status is forwarded as the cause; with a context, or LOGOS_OK
      # without one, the result is invalid and nothing it wrote is forwarded.
      for (command, cause, message) in [
        ("fail-init", true, true),
        ("fail-init-context", true, false),
        ("ok-null", false, false),
      ]:
        let dir = stateDir(command)
        var r = startHost(host)
        defer:
          r.stop()
        let f = r.initFailure(initMsg(dir))
        check f.code.kind == LcnCarrierInitFailedCodeChoiceKind.Realization_failed
        check f.phase.kind == LcnCarrierInitFailedPhaseChoiceKind.Init
        if cause:
          check f.cause.isSome and f.cause.get.code == uint8(ord(ecModule))
          check f.cause.get.message ==
            (if message: Opt.some("the probe refused to start")
            else: Opt.none(string))
        check lines(dir, "inits") == @["init"]
        check lines(dir, "destroyed").len == 0

  suite "host.module: release and the carrier's end (LOADER §9; RUNTIME l.976)":
    test "[LDR-0117] [LDR-0119] [LDR-0138] H-7 release: destroy exactly once, released, exit 0; a release before init breaks the protocol":
      let dir = stateDir()
      var r = startHost(host)
      defer:
        r.stop()
      check r.initialized(dir)
      check r.released()
      check lines(dir, "destroyed") == @["destroyed"]
      var early = startHost(host)
      defer:
        early.stop()
      check early.send(toMessage(LcnCarrierRelease(id: 1)))
      check early.waitExit() and early.exitedWith == ExitCarrierLost

    test "[RUN-0812] H-8 the carrier closes while module code blocks: the host ends at once, the context is not destroyed":
      let dir = stateDir("block-init")
      var r = startHost(host)
      defer:
        r.stop()
      check r.send(initMsg(dir))
      while lines(dir, "inits").len == 0:
        sleep(5)
      r.closeCarrier()
      check r.waitExit(2000) and r.exitedWith == ExitCarrierLost
      writeFile(dir / "go", "")
      check lines(dir, "destroyed").len == 0

  suite "host.module: live apply (LOADER §8)":
    test "[LDR-0113] H-9 apply: succeeded, rejected, an invalid status; for a startup-only realization no hook runs":
      let dir = stateDir()
      var r = startHost(host)
      defer:
        r.stop()
      check r.initialized(dir, live = true)
      proc apply(r: var HostRun, text: string): Opt[LcnCarrierFailure] =
        var b: seq[byte]
        for c in text:
          b.add(byte(c))
        check r.send(toMessage(LcnCarrierApply(id: 2, configuration: b)))
        let m = r.next()
        check m.kindOf == $LcnCarrierMessageKind.lcn_Carrier_applied
        if m.isSome and m.get.kind == LcnCarrierMessageKind.lcn_Carrier_applied:
          return m.get.arm_lcn_Carrier_applied.failure

      check r.apply("ok").isNone
      let rejected = r.apply("reject")
      check rejected.isSome and rejected.get.code == uint8(ord(ecInvalidParams))
      check rejected.get.message == Opt.some("the probe rejects it")
      check rejected.get.reason.isNone
      let bad = r.apply("bad")
      check bad.isSome and bad.get.code == uint8(ord(ecModule))
      check bad.get.message.isNone and bad.get.reason.isSome
      check lines(dir, "applied").len == 3
      check r.released()
      # Startup only: the apply breaks the protocol and calls no hook.
      let quiet = stateDir()
      var s = startHost(host)
      defer:
        s.stop()
      check s.initialized(quiet)
      check s.send(
        toMessage(LcnCarrierApply(id: 2, configuration: @[byte('o'), byte('k')]))
      )
      check s.waitExit() and s.exitedWith == ExitCarrierLost
      check lines(quiet, "applied").len == 0

  suite "host.module: carrier violations (RUNTIME RUN-0812)":
    test "[RUN-0812] H-13 a frame that does not decode, one over the limit, an unexpected message, a reply to no request: exit 70":
      let garbage = @[0'u8, 0, 0, 3, 0xFF, 0xFF, 0xFF]
      let oversize = @[0xFF'u8, 0xFF, 0xFF, 0xFF, 0]
      var frames = @[garbage, oversize]
      frames.add(frameOf(toMessage(LcnCarrierInitialized(id: 1))).get)
      frames.add(
        frameOf(toMessage(LcnCarrierRcReply(id: 77, value: Opt.some(@[0xA0'u8])))).get
      )
      for f in frames:
        var r = startHost(host)
        defer:
          r.stop()
        check r.sendRaw(f)
        check r.waitExit() and r.exitedWith == ExitCarrierLost

  suite "host.module: spawn (plan §2.3, R4, R5)":
    test "[IMPL] H-14 the child starts with an empty signal mask, default actions, only the allow-listed environment, /dev/null on fd 0, the lock on fd 5 and nothing above it":
      # Built without Nim's own signal handlers, which would replace the
      # dispositions the spawn set before the probe could read them.
      let program = buildChild(
        "tests/support/spawnprobe.nim", "spawnprobe", "spawnprobe", @["noSignalHandler"]
      )
      putEnv("LCN_SPAWN_PASSED", "yes")
      putEnv("LCN_SPAWN_SECRET", "no")
      # The supervision thread starts on this thread's first spawn and inherits
      # its mask; SIGPIPE ignored is this process's.
      var blocked, old: Sigset
      discard sigemptyset(blocked)
      discard sigaddset(blocked, SIGINT)
      discard sigaddset(blocked, SIGTERM)
      discard pthread_sigmask(SIG_BLOCK, blocked, old)
      discard signal(SIGPIPE, SIG_IGN)
      let lockPath = work / "h14.lock"
      writeFile(lockPath, "")
      let lockFd = posix.open(cstring(lockPath), O_RDWR or O_CLOEXEC)
      var lockStat: Stat
      discard fstat(lockFd, lockStat)
      let s = newSupervisor(program, ["LCN_SPAWN_PASSED", "LCN_SPAWN_UNSET"])
      let h = s.newHost(nil, nil, nil, 1024).get
      check h.spawn(lock = lockFd).isOk
      discard pthread_sigmask(SIG_SETMASK, old, blocked)
      discard posix.close(lockFd)
      let m = h.awaitLane0()
      check m.isSome and m.get.kind == LcnCarrierMessageKind.lcn_Carrier_fatal
      let report =
        if m.isSome and m.get.kind == LcnCarrierMessageKind.lcn_Carrier_fatal:
          m.get.arm_lcn_Carrier_fatal.message.splitLines.filterIt(it.len > 0)
        else:
          @[]
      check "mask 0" in report
      for sig in ["pipe", "term", "int", "hup"]:
        check (sig & " dfl") in report
      check report.filterIt(it.startsWith("env LCN_")) == @["env LCN_SPAWN_PASSED"]
      check "fd0 null" in report
      check ("fd5 " & $lockStat.st_dev & ":" & $lockStat.st_ino) in report
      check "fd6 closed" in report
      let e = h.awaitEnd()
      check e.exited and e.status == 0
      h.dropHost()
      s.closeSupervisor()
else:
  import unittest2

  suite "host.module: the Module Host (POSIX only)":
    test "[IMPL] hosted placement is not supported on this platform; the host is a stub":
      skip()
