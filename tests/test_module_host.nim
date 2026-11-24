## The Module Host program (`src/logos_module_host.nim`, `src/logos_core/host/`;
## Tier 4b step 4b-3, DECISIONS G264, G266; plan §2.2, §4.3) against a test
## owner of its carrier (`support/hostowner.nim`), with no engine: startup,
## lane 0 (init, apply, release), the ends of the carrier, and the spawn
## (`hostsup.spawnProcess`, through a stand-in program), and the parent the
## spawn names (`--parent=<pid>`, G264 amended 2026-11-21; Tier 5 step 5-7a-1).
## And the supervisor's side of a lane-1 Runtime Control call, through a fake
## binding (`hostsup.rcCallReply`; INTERFACE §5.2 l.3860-3864, DECISIONS I135).
##
## The module is `tests/kit/probe_impl.nim`, a consumer-only library that reads
## what to do from its state directory and writes what it saw there. The host
## is built without test hooks (plan R20), under this suite's memory manager
## and sanitizer.

when defined(posix):
  import std/[os, posix, sequtils, strutils]
  import unittest2
  import results
  import logos_sdk/abi/types
  import logos_sdk/iface/outcome
  import logos_sdk/base/parentwatch
  import ../src/logos_core/runtime/[carrier, hostio, hostsup]
  import ../src/logos_core/transport/io/endpoint
  from ../src/logos_core/transport/io/sock import fdClose, socketPair
  from ../src/logos_core/host/state import ExitCarrierLost, ExitNotStartedByLoader
  import ./support/[childbuild, hostowner, modulehostbuild, shortdir]
  import ./support/trnowner

  let
    work =
      currentSourcePath().parentDir.parentDir / "build" / "module-host-suite" /
      kitVariant
    host = moduleHostProgram()
    probe = buildKitLibrary("probe_impl.nim", "probe")
    meter = buildKitLibrary("meter_impl.nim", "mhmeter")
    shortBase = makeShortBase("lcnmh", "/e999/12345678/logos_meter_module.sock")
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
      # `$PPID` is this process: `sh` execs the host in its own place.
      let named = quoteShell(host) & " --parent=$PPID"
      check shellStatus("exec 3<&- ; exec " & named & " 2>/dev/null") == 2
      check shellStatus("exec " & named & " 3</dev/null 2>/dev/null") == 2

    test "[IMPL-DECISION G264] H-16 started with a carrier but no valid --parent=<pid>: exit 2":
      for args in [
        newSeq[string](),
        @["--parent="],
        @["--parent=12x"],
        @["--parent=0"],
        @["parent=1"],
      ]:
        var r = startHost(host, args = Opt.some(args))
        defer:
          r.stop()
        check r.waitExit() and r.exitedWith == ExitNotStartedByLoader

    test "[IMPL-DECISION G264] H-17 a --parent that is not the host's parent, as when the Runtime ended before the host set its watch and the host was adopted: exit 70":
      # This suite's own parent: a live process, never the host's.
      var r = startHost(host, args = Opt.some(@[ParentFlag & $getppid()]))
      defer:
        r.stop()
      check r.waitExit() and r.exitedWith == ExitCarrierLost

    test "[IMPL-DECISION G264] H-18 parentArg: the first --parent=<pid>, a positive decimal that fits pid_t":
      check parentArg(["--parent=1234"]) == Opt.some(1234)
      check parentArg(["x", "--parent=7", "--parent=8"]) == Opt.some(7)
      check parentArg(["--parent=2147483647"]) == Opt.some(2147483647)
      for bad in [
        "--parent=", "--parent=0", "--parent=-1", "--parent=+1", "--parent= 1",
        "--parent=1 ", "--parent=2147483648", "--parent=99999999999", "--parent=0x10",
      ]:
        check parentArg([bad]).isNone
      check parentArg(newSeq[string]()).isNone
      check parentArg(["--parent", "1"]).isNone

  suite "host.module: lane 0 init (LOADER §6)":
    test "[LDR-0040] [LDR-0042] [LDR-0053] [IMPL-DECISION G442] H-2 a consumer-only module: initialized without a call surface; its state directory and only the given environment reach it, with this process's five sanitizer variables beside it":
      putEnv("LCN_PROBE_SECRET", "not for the host")
      let want = deliverySettings()
      let dir = stateDir("env", "env-of " & SanitizerEnv.join(" "))
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
      check lines(dir, "envof") == want.mapIt(it[0] & "=" & it[1])
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

  # H-5, H-6 ------------------------------------------------------------------------------

  var endpoints = 0

  proc providerInit(
      path: string, module = "meter_module", system = Opt.none(string)
  ): LcnCarrierMessage =
    ## `init` for the meter library as a provider whose endpoint is `path`; with `system`,
    ## as the marked provider whose system-service endpoint is that path (G492).
    toMessage(
      LcnCarrierInit(
        id: 1,
        module: module,
        artifact_path: meter,
        live: false,
        max_payload_depth: 1024,
        endpoint: Opt.some(path),
        transport: Opt.some(transportWords(defaultTransportConfig())),
        runtime_id: Opt.some("7f3a2c1e-5b4d-4e6f-8a9b-0c1d2e3f4a5b"),
        system: (if system.isSome: Opt.some(true) else: Opt.none(bool)),
        system_endpoint: system,
      )
    )

  proc newEndpoint(): Endpoint =
    ## An endpoint as the Runtime makes one, under a fresh private base.
    inc endpoints
    let base = shortBase / ("e" & $endpoints)
    doAssert posix.mkdir(cstring(base), 0o700) == 0
    createEndpoint(base, "meter_module").tryGet

  proc kinds(r: var HostRun, until: LcnCarrierMessageKind): seq[LcnCarrierMessageKind] =
    ## The host's messages up to and including the first `until`.
    while true:
      let m = r.next()
      if m.isNone:
        return
      result.add(m.get.kind)
      if m.get.kind == until:
        return

  suite "host.module: a provider's listener (LOADER §5.3, §6, §12; TRANSPORT §8.2)":
    test "[LDR-0081] [LDR-0082] [LDR-0146] [TRN-0184] H-5 the host holds the listener it was given and accepts nothing until _MODULE_init succeeded; then it serves that listener, and after a failed init never":
      type K = LcnCarrierMessageKind
      block served:
        let ep = newEndpoint()
        defer:
          removeDir(ep.dir.base)
        var r = startHost(host, listener = ep.listener)
        defer:
          r.stop()
        discard fdClose(ep.listener) # the host's copy is the only one
        let o = newOwner()
        defer:
          o.stop()
        # A connection made before `init`: its Hello waits in the listener's
        # queue and the host forwards nothing.
        o.connect(1, ep.path, o.issue(), module = "meter_module")
        check r.next(300).isNone
        # `initialized` once it listens on that listener (G267), and that
        # connection's Hello, accepted there. The loop serves fd 4 before
        # `initialized` is sent (`host/main.nim`), so the Hello may come
        # first: it did on macOS CI (1ca4710).
        check r.send(providerInit(ep.path))
        var got: seq[K]
        while K.lcn_Carrier_initialized notin got or K.lcn_Carrier_io_hello notin got:
          let m = r.next()
          if m.isNone:
            break
          got.add(m.get.kind)
        checkpoint "the host's messages: " & $got
        check got.len == 2
        check got.count(K.lcn_Carrier_initialized) == 1
        check got.count(K.lcn_Carrier_io_hello) == 1
        # It serves the path it was given and binds nothing else.
        check toSeq(walkDirRec(ep.dir.path)) == @[ep.path]
        check r.send(toMessage(LcnCarrierRelease(id: 9)))
        check K.lcn_Carrier_released in r.kinds(K.lcn_Carrier_released)
        check r.waitExit() and r.exitedWith == 0
      block failed:
        let ep = newEndpoint()
        defer:
          removeDir(ep.dir.base)
        var r = startHost(host, listener = ep.listener)
        defer:
          r.stop()
        discard fdClose(ep.listener)
        let o = newOwner()
        defer:
          o.stop()
        o.connect(1, ep.path, o.issue(), module = "meter_module")
        let f = r.initFailure(providerInit(ep.path, module = "other_module"))
        check f.code.kind == LcnCarrierInitFailedCodeChoiceKind.Abi_invalid
        r.closeCarrier()
        check r.waitExit() and r.exitedWith == 0
        # The connection ends with the host; no Hello was ever forwarded.
        let ended = o.expect(
          proc(ev: IoEvent): bool =
            ev.conn == 1 and ev.kind in {evConnectFailed, evClosed}
        )
        check ended.isSome

    test "[TRN-0186] [LDR-0089] H-6 a provider's init with no listener on fd 4, or a socket that is not listening: init_failed realization-failed, the module destroyed":
      let ep = newEndpoint()
      var pair: array[2, cint]
      check socketPair(addr pair) == 0
      for listener in [cint(-1), pair[0]]:
        var r = startHost(host, listener = listener)
        defer:
          r.stop()
        let f = r.initFailure(providerInit(ep.path))
        check f.code.kind == LcnCarrierInitFailedCodeChoiceKind.Realization_failed
        check f.phase.kind == LcnCarrierInitFailedPhaseChoiceKind.Bind
        check "listener" in f.message
        r.closeCarrier()
        check r.waitExit()
      discard fdClose(pair[0])
      discard fdClose(pair[1])
      discard fdClose(ep.listener)
      removeDir(ep.dir.base)

    test "[TRN-0186] [IMPL-DECISION G492] H-6b the marked provider's init naming a system-service endpoint, with no listener on fd 6, or a socket there that is not listening: init_failed realization-failed, the module destroyed":
      let ep = newEndpoint()
      var pair: array[2, cint]
      check socketPair(addr pair) == 0
      for system in [cint(-1), pair[0]]:
        # fd 4 is the endpoint's own listener: only fd 6 is wrong.
        var r = startHost(host, listener = ep.listener, system = system)
        defer:
          r.stop()
        let f =
          r.initFailure(providerInit(ep.path, system = Opt.some(ep.path & ".sys")))
        check f.code.kind == LcnCarrierInitFailedCodeChoiceKind.Realization_failed
        check f.phase.kind == LcnCarrierInitFailedPhaseChoiceKind.Bind
        check "system-service listener" in f.message
        r.closeCarrier()
        check r.waitExit()
      discard fdClose(pair[0])
      discard fdClose(pair[1])
      discard fdClose(ep.listener)
      removeDir(ep.dir.base)

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

    test "[IMPL-DECISION I92] H-15 an init that carries wipe_audit to a host that is no audit build: exit 70, before the module is bound":
      # Test support only (the test-hook rule): a host that cannot scan is not
      # one a test may believe armed.
      when kitAudit:
        skip()
      else:
        let dir = stateDir("serve")
        var m = initMsg(dir)
        m.arm_lcn_Carrier_init.wipe_audit = Opt.some(@[newSeq[byte](16)])
        var r = startHost(host)
        defer:
          r.stop()
        check r.send(m)
        check r.waitExit() and r.exitedWith == ExitCarrierLost
        check toSeq(walkDir(dir)).len == 1 # `probe.cmd` alone: no init ran

  suite "host.module: spawn (plan §2.3, R4, R5)":
    test "[IMPL] [IMPL-DECISION G492] H-14 the child starts with --parent=<the Runtime's pid> as its one argument, an empty signal mask, default actions, only the allow-listed environment, /dev/null on fd 0, the lock on fd 5 and nothing above it, not even the daemon's own fd 6 left open and inheritable":
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
      let want = deliverySettings()
      # [G492] This process's fd 6, open and inheritable during the spawn: a host given no
      # system endpoint must not keep it. Where the spawn closes inherited descriptors
      # (Darwin's flag, glibc's closefrom); bionic relies on close-on-exec alone.
      const inheritedSix = defined(macosx) or (defined(linux) and not defined(android))
      let sixFlags = fcntl(6, F_GETFD)
      when inheritedSix:
        if sixFlags < 0:
          let f = posix.open(cstring(lockPath), O_RDONLY)
          check f >= 0 and dup2(f, 6) == 6
          discard posix.close(f)
        else:
          discard fcntl(6, F_SETFD, sixFlags and not FD_CLOEXEC)
        check fcntl(6, F_GETFD) == 0
      let s =
        newSupervisor(program, @["LCN_SPAWN_PASSED", "LCN_SPAWN_UNSET"] & @SanitizerEnv)
      let h = s.newHost(nil, nil, nil, 1024).get
      check h.spawn(lock = lockFd).isOk
      when inheritedSix:
        if sixFlags < 0:
          discard posix.close(6)
        else:
          discard fcntl(6, F_SETFD, sixFlags)
      discard pthread_sigmask(SIG_SETMASK, old, blocked)
      discard posix.close(lockFd)
      let m = h.awaitLane0()
      check m.isSome and m.get.kind == LcnCarrierMessageKind.lcn_Carrier_fatal
      let report =
        if m.isSome and m.get.kind == LcnCarrierMessageKind.lcn_Carrier_fatal:
          m.get.arm_lcn_Carrier_fatal.message.splitLines.filterIt(it.len > 0)
        else:
          @[]
      check report.filterIt(it.startsWith("arg ")) == @["arg --parent=" & $getpid()]
      check "mask 0" in report
      for sig in ["pipe", "term", "int", "hup"]:
        check (sig & " dfl") in report
      check report.filterIt(it.startsWith("env LCN_")) == @["env LCN_SPAWN_PASSED"]
      for (name, _) in want:
        check ("env " & name) in report
      check "fd0 null" in report
      check ("fd5 " & $lockStat.st_dev & ":" & $lockStat.st_ino) in report
      check "fd6 closed" in report
      let e = h.awaitEnd()
      check e.exited and e.status == 0
      h.dropHost()
      s.closeSupervisor()

  suite "host.module: sanitizer reports from a host (DECISIONS G442)":
    test "[IMPL-DECISION G442] the canary checker: a file of one stack trace moves to the canary directory once its process is reaped; anything else stays, so the check fails on it":
      let reports = work / "checker" / "sanitizer-reports"
      removeDir(reports)
      createDir(reports)
      check logDirOf("halt_on_error=1:log_path=" & reports / "report:log_exe_name=1") ==
        reports
      check logDirOf("log_path=/a/report:log_path=" & reports / "report") == reports
      check logDirOf("log_path=stderr") == ""
      check logDirOf("halt_on_error=1") == ""
      const
        trace =
          "    #0 0x1 in __sanitizer_print_stack_trace\n" &
          "    #1 0x2 (h1.so+0xef521)\n    #2 0x3 in main\n\n"
        report =
          "WARNING: ThreadSanitizer: data race\n    #0 f\n" &
          "SUMMARY: ThreadSanitizer: data race a.nim:1 in f\n"
      check isOneTrace(trace)
      check isOneTrace("#0 f\n")
      check not isOneTrace("")
      check not isOneTrace(trace & trace) # two traces: a report came after
      check not isOneTrace(trace & report)
      check not isOneTrace("    #1 0x2 in f\n") # not from #0
      check not isOneTrace("    #0f\n")
      writeFile(reports / "report.logos_module_host.41", trace)
      writeFile(reports / "report.logos_module_host.42", trace & report)
      writeFile(reports / "report.logos_module_host.431", trace)
      check reportFileOf(reports, 43) == ""
      check takeCanary(reports, 43) == coMissing
      check takeCanary(reports, 42) == coNotATrace
      check fileExists(reports / "report.logos_module_host.42")
      check takeCanary(reports, 41) == coMoved
      check not fileExists(reports / "report.logos_module_host.41")
      check readFile(reports / CanaryDir / "report.logos_module_host.41") == trace
      removeDir(work / "checker")

    test "[IMPL-DECISION G442] a direct host's stack trace lands in the sanitizer check's report directory (the canary)":
      when not Sanitized:
        skip()
      else:
        let reports = reportsDir()
        if reports.len == 0:
          checkpoint(
            "no log_path here: this suite was not run by tools/sanitizer/reports.sh"
          )
          skip()
        else:
          let dir = stateDir("sanitizer-trace")
          var r = startHost(host)
          defer:
            r.stop()
          check r.initialized(dir)
          check lines(dir, "inits") == @["init", "sanitizer-trace"]
          check r.released()
          r.closeCarrier()
          check r.waitExit() and r.exitedWith == 0
          # Reaped: nothing more can land in its file.
          check takeCanary(reports, r.pid) == coMoved

    test "[IMPL-DECISION G442] a direct host started without the sanitizer settings writes no file there (the control; its trace goes to the suite's stderr)":
      when not Sanitized:
        skip()
      else:
        let reports = reportsDir()
        if reports.len == 0:
          checkpoint(
            "no log_path here: this suite was not run by tools/sanitizer/reports.sh"
          )
          skip()
        else:
          let dir = stateDir("sanitizer-trace")
          # [G442] sanitizer-env: the control, a host without them
          var r = startHost(host, sanitizerEnv = false)
          defer:
            r.stop()
          check r.initialized(dir)
          check lines(dir, "inits") == @["init", "sanitizer-trace"]
          check r.released()
          r.closeCarrier()
          check r.waitExit() and r.exitedWith == 0
          check reportFileOf(reports, r.pid) == ""

  # The supervisor's lane-1 Runtime Control call (`hostsup.rcCallReply`; DECISIONS
  # I135) through a fake binding whose `call` leaves a chosen result and
  # outputs, and whose `release_response` counts.
  var
    fakeCode: int32
    fakeBuf: ptr UncheckedArray[uint8]
    fakeLen: csize_t
    fakeReleases: int
    fakeReleased: (pointer, csize_t)
    fakeBytes = [0xa0'u8, 0xa0, 0xa0, 0xa0] # empty CBOR maps

  proc fakeCall(
      binding: ptr LogosRuntimeControlBinding,
      `method`: cstring,
      paramsCbor: ptr UncheckedArray[uint8],
      paramsCborLen: csize_t,
      outResponseCbor: ptr ptr UncheckedArray[uint8],
      outResponseCborLen: ptr csize_t,
  ): LogosResult {.cdecl, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      outResponseCbor[] = fakeBuf
      outResponseCborLen[] = fakeLen
      LogosResult(code: CErrorCode(fakeCode))

  proc fakeRelease(
      binding: ptr LogosRuntimeControlBinding,
      responseCbor: ptr UncheckedArray[uint8],
      responseCborLen: csize_t,
  ) {.cdecl, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      fakeReleases += 1
      fakeReleased = (pointer(responseCbor), responseCborLen)

  var
    fakeVtable = LogosRuntimeControlVtable(call: fakeCall, releaseResponse: fakeRelease)
    fakeRc = LogosRuntimeControlBinding(vtable: addr fakeVtable)

  proc fakeReply(code: ErrorCode, buf: pointer, len: int): LcnCarrierRcReply =
    ## One call through the fake binding, its outputs `buf` and `len`.
    fakeCode = (if code == ecOk: 0'i32 else: int32(ord(code)))
    fakeBuf = cast[ptr UncheckedArray[uint8]](buf)
    fakeLen = csize_t(len)
    fakeReleases = 0
    fakeReleased = (nil, 0)
    rcCallReply(
      addr fakeRc,
      LcnCarrierRcCall(
        id: 7, `method`: @(toOpenArrayByte("list_modules", 0, 11)), params: @[0xa0'u8]
      ),
    )

  proc refusedAsModuleError(r: LcnCarrierRcReply): bool =
    r.id == 7 and r.value.isNone and r.failure.isSome and
      r.failure.get.code == uint8(ord(ecModule)) and r.failure.get.message.isNone and
      r.failure.get.detail.isNone

  suite "host.supervisor: a Runtime Control call's outcome (INTERFACE §5.2 l.3860-3864; DECISIONS I135)":
    test "[SPEC INTERFACE §5.2] a failure that also hands back a buffer is MODULE_ERROR, and the buffer is not released":
      let r = fakeReply(ecNotAuthorised, addr fakeBytes[0], 1)
      check r.refusedAsModuleError
      check fakeReleases == 0

    test "[SPEC INTERFACE §5.2] LOGOS_OK with a zero length is MODULE_ERROR, and the buffer it handed over is released once":
      let r = fakeReply(ecOk, addr fakeBytes[0], 0)
      check r.refusedAsModuleError
      check fakeReleases == 1
      check fakeReleased == (pointer(addr fakeBytes[0]), csize_t(0))

    test "[SPEC INTERFACE §5.2] LOGOS_OK with no buffer and a nonzero length is MODULE_ERROR, with nothing read or released":
      let r = fakeReply(ecOk, nil, 5)
      check r.refusedAsModuleError
      check fakeReleases == 0

    test "[SPEC INTERFACE §5.2] a success is copied, then released once; a failure with no outputs keeps its code":
      let ok = fakeReply(ecOk, addr fakeBytes[0], 2)
      check ok.failure.isNone and ok.value == Opt.some(@[0xa0'u8, 0xa0])
      check fakeReleases == 1
      check fakeReleased == (pointer(addr fakeBytes[0]), csize_t(2))
      let refused = fakeReply(ecNotAuthorised, nil, 0)
      check refused.value.isNone and refused.failure.isSome
      check refused.failure.get.code == uint8(ord(ecNotAuthorised))
      check fakeReleases == 0
else:
  import unittest2

  suite "host.module: the Module Host (POSIX only)":
    test "[IMPL] hosted placement is not supported on this platform; the host is a stub":
      skip()

# [DECISIONS I146] The dispatch pool's counting, on every platform: pure, so every order of posts,
# the workers' receives and the jobs' ends is walked, where a timed test would see only the orders
# its host runs. `claim` and `finished` are the ones `host/endpoint.nim`'s `post` and `poolLoop`
# call; the worker's side (nothing counted at a receive, `finished` once after each job) is this
# model's, as `poolLoop` has it.
import std/sets
import ../src/logos_core/host/dispatchcount

type
  PoolModel = object
    ## Posts into the pool's queue, the workers that take them, and the jobs' ends. `old`: the
    ## counting before I146, which made a worker idle when started and claimed it only once it
    ## had taken a job.
    counts: DispatchCounts
    old: bool
    oldIdle, oldCount: int
    posted, receiving, queued, running, ended: int

  Walked = object
    ok: bool ## every state kept the invariant, and every order ended with every job done
    claims: set[DispatchClaim] ## the claim kinds some order made
    tookWaiting, wentIdle: bool ## `finished`'s two outcomes, each seen in some order

proc post(m: var PoolModel, cap: int, w: var Walked) =
  inc m.posted
  inc m.queued
  if m.old:
    if m.oldIdle == 0 and m.oldCount < cap:
      inc m.oldCount
      inc m.oldIdle
      inc m.receiving
  else:
    let c = m.counts.claim(cap)
    w.claims.incl c.kind
    if c.kind == dcGrow:
      doAssert c.index == m.counts.count - 1
      inc m.receiving

proc take(m: var PoolModel) =
  dec m.receiving
  dec m.queued
  inc m.running
  if m.old:
    dec m.oldIdle

proc finish(m: var PoolModel, w: var Walked) =
  ## A running job ends; its worker goes back to its receive.
  dec m.running
  inc m.ended
  inc m.receiving
  if m.old:
    inc m.oldIdle
  elif m.counts.finished():
    w.tookWaiting = true
  else:
    w.wentIdle = true

func holds(m: PoolModel): bool =
  ## [Fable §13.4] With A the workers not running a job (a new one from its claim) and Q the
  ## jobs claimed and not yet received: A - Q = idle - waiting, and never both idle and waiting.
  m.receiving - m.queued == m.counts.idle - m.counts.waiting and
    not (m.counts.idle > 0 and m.counts.waiting > 0)

proc walk(cap, jobs: int, ends: bool, old = false): Walked =
  ## Every order of `jobs` posts, the workers' receives and, with `ends`, the running jobs'
  ## ends. Done means every job running (`ends` false: each blocks for ever) or ended.
  var w = Walked(ok: true)
  var seen: HashSet[array[10, int]]
  proc step(m: PoolModel) =
    if not w.ok:
      return
    let key = [
      m.posted, m.receiving, m.queued, m.running, m.ended, m.counts.idle,
      m.counts.waiting, m.counts.count, m.oldIdle, m.oldCount,
    ]
    if key in seen:
      return
    seen.incl key
    if not m.old and not m.holds:
      w.ok = false
      return
    var moved = false
    if m.posted < jobs:
      var n = m
      n.post(cap, w)
      step(n)
      moved = true
    if m.receiving > 0 and m.queued > 0:
      var n = m
      n.take()
      step(n)
      moved = true
    if ends and m.running > 0:
      var n = m
      n.finish(w)
      step(n)
      moved = true
    if not moved and (if ends: m.ended else: m.running) != jobs:
      w.ok = false

  step(PoolModel(old: old))
  w

suite "host.module: the dispatch pool's counts (DECISIONS I146)":
  test "[IMPL-DECISION I146] two posts before any worker has taken a job start two workers, at distinct indexes; a worker whose job ended is the next post's":
    var c: DispatchCounts
    let a = c.claim(64)
    let b = c.claim(64)
    check a.kind == dcGrow and a.index == 0
    check b.kind == dcGrow and b.index == 1
    check c.count == 2 and c.idle == 0
    check not c.finished()
    check c.idle == 1
    check c.claim(64).kind == dcIdle
    check c.count == 2 and c.idle == 0

  test "[IMPL-DECISION I146] at the cap a job waits, and the next worker to finish takes it before it counts idle":
    var c: DispatchCounts
    check c.claim(2).kind == dcGrow
    check c.claim(2).kind == dcGrow
    check c.claim(2).kind == dcWaiting
    check c.count == 2 and c.waiting == 1
    check c.finished()
    check c.waiting == 0 and c.idle == 0
    check not c.finished()
    check not c.finished()
    check c.idle == 2 and c.count == 2 and c.waiting == 0

  test "[IMPL-DECISION I146] in every order of four posts and the workers' receives, four blocking calls all run; the counting before I146 leaves one queued in some order":
    check walk(cap = 64, jobs = 4, ends = false).ok
    check walk(cap = 4, jobs = 4, ends = false).ok
    check not walk(cap = 64, jobs = 4, ends = false, old = true).ok

  test "[IMPL-DECISION I146] in every order of five posts, the workers' receives and the jobs' ends under a cap of 2, every state keeps A - Q = idle - waiting with never both idle and waiting, and every job runs and ends; the walk reaches every claim and both ends of a job":
    let w = walk(cap = 2, jobs = 5, ends = true)
    check w.ok
    check w.claims == {dcIdle, dcGrow, dcWaiting}
    check w.tookWaiting and w.wentIdle
