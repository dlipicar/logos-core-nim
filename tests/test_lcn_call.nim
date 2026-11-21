## lcn_call, the CLI module, in a logosd in this process (Tier 5 step N-2b;
## DECISIONS G343-G350; docs/DAEMON.md §7a; plan §5, L-1 to L-10 and L-13).
##
## Each case makes a session with `logosctl init`'s library function: the
## meter, shapes, vault (orc and arc only, G277) and bulk kit modules hosted as operator providers,
## operator rules granting `lcn_call` the first three (and `discover` alone on
## bulk), and `cli.artifact` naming the library `support/clibuild` builds. It
## runs `assembleDaemon` and `startDaemon` as logosd's `main` does, and runs
## each command with the launcher's library function (`launch`), as `logosctl
## call` does, from the test's threads, with regular files for stdout and
## stderr. `lcn_call` runs in a Module Host of its own, so the test cannot
## reach its globals: what it did is read from exit codes, its output, the
## Runtime's records (through the logosctl instance), and the meter's `held`
## file (channels 22 and 23 hold a call until the file `open` is in the
## meter's state directory; `meter_impl.nim`). Waits that only bound a test
## scale with `Slow`.
##
## logosctl's argument parsing and the binaries are `test_logosd`'s; the
## module's pure parts (arguments, the wire, hops, activation decisions, the
## classifier) are `test_cli`'s.

when defined(posix):
  import
    std/[
      algorithm, atomics, json, locks, monotimes, os, sequtils, strutils, times,
      typedthreads,
    ]
  import std/posix except Time
  import unittest2
  import logos_sdk/cbor
  import logos_sdk/crypto/blake3
  from logos_sdk/base/perthread import releasePerThread
  from logos_sdk/base/wipe import ChannelsMove
  from logos_sdk/iface/accept import acceptContractSet
  import ../src/logos_core/runtime/[engine, host], logos_sdk/kit/[rc_arms, rc_types]
  from ../src/logos_core/durable import DurableLock, release
  from ../src/logos_core/authority/scopes import sortSet
  import
    ../src/logos_core/daemon/
      [assemble, ctlwire, daemon_config_types, logging, session, sessioninit]
  from ../src/logos_core/daemon/config import CliInstance
  from ../src/logos_core/daemon/compose import cliSocketPath
  import ../src/logos_core/cli/[cli_types, launcher]
  from ../src/logos_core/cli/wire import writeRequest, readReply
  import logos_sdk/testing/testdirs
  import ./support/[clibuild, modulehostbuild, shortdir, slowdown]

  const
    Patience = 60 * Slow ## seconds a bounding wait allows
    Timeout = 30_000 * Slow ## a command's, and a client's, wait, ms
    IdleMs = min(60_000 * Slow, 600_000)
      ## `ctl.idle_timeout_ms` and `cli.idle_timeout_ms` where no case is about
      ## them (test_ctl_module's reason)
    StopDeadlineMs = 5_000 * Slow
      ## `stop_deadline_ms` and `shutdown_grace_ms`: L-13's provider ignores
      ## its cancellation, so its stop ends at this deadline
    SanitizerEnv =
      ["ASAN_OPTIONS", "LSAN_OPTIONS", "MSAN_OPTIONS", "TSAN_OPTIONS", "UBSAN_OPTIONS"]
    MeterInstance = "meter-1"
    ShapesInstance = "shapes-1"
    VaultInstance = "vault-1"
    BulkInstance = "bulk-1"
    MeterState = "meter-state"
    # Started at boot. [DECISIONS G277] A refc Runtime or Module Host starts no
    # marked provider, so `vault-1` is only declared there and L-5 skips.
    Providers =
      when ChannelsMove:
        @[MeterInstance, ShapesInstance, VaultInstance, BulkInstance]
      else:
        @[MeterInstance, ShapesInstance, BulkInstance]
    ZeroHex32 = repeat("00", 32)
    ReflectRequest =
      "{\"a\": 7, \"b\": -5, \"c\": \"hi\", \"d\": \"" & ZeroHex32 &
      "\", \"e\": [\"0a0b0c0d\"], \"f\": [[3, \"x\"]], \"g\": 1, \"i\": " &
      "{\"commitment_model\": \"logos.commitment-model.2026-10\", \"schema_root\": \"" &
      ZeroHex32 & "\", \"hash_profile\": \"logos.hash-profile.2026-08.choice-index\", " &
      "\"hash_suite\": \"logos.hash-suite.blake3-256\"}, \"j\": [], \"l\": \"\", " &
      "\"m\": -1, \"n\": 2, \"o\": 3, \"p\": 0, \"r\": [\"ab\"], \"s\": \"ff\", " &
      "\"t\": [{\"kind\": \"file\", \"path\": \"/x\"}], " &
      "\"u\": {\"kids\": [], \"tag\": \"leaf\"}, \"v\": {\"w\": true}, " &
      "\"y\": \"01\", \"z\": \"00000000\"}"
      ## a whole `shapes.reflect_request`, as G89 writes it; `reflect`
      ## answers with the same value

  # Captured log lines --------------------------------------------------------------------

  var
    logLock: Lock
    logBuf: ptr UncheckedArray[char]
    logLen: int
  const LogCap = 1 shl 20
  initLock(logLock)
  logBuf = cast[ptr UncheckedArray[char]](allocShared0(LogCap))

  proc capture(line: string) {.nimcall, gcsafe, raises: [].} =
    withLock logLock:
      for c in line & "\n":
        if logLen < LogCap:
          logBuf[logLen] = c
          inc logLen

  proc logText(): string =
    withLock logLock:
      result = newString(logLen)
      for i in 0 ..< logLen:
        result[i] = logBuf[i]

  setLogSink(capture)

  proc notifyTest() {.nimcall, gcsafe, raises: [].} =
    discard

  # Providers, rules and sessions ---------------------------------------------------------

  proc digestOfFile(path: string): seq[byte] =
    var h: Blake3Hasher
    h.init()
    let bytes = readFile(path)
    h.update(bytes.toOpenArrayByte(0, bytes.high))
    @(h.finish())

  proc rootOf(path: string): seq[byte] =
    @(acceptContractSet(readFile(repoDir / path)).expect(path).primary.root)

  func hexOf(bytes: openArray[byte]): string =
    for b in bytes:
      result.add(toHex(b, 2).toLowerAscii)

  let
    hostExe = moduleHostProgram()
    cliArt = cliArtifact()
    meterLib = buildKitLibrary("meter_impl.nim", "lcmeter")
    shapesLib = buildKitLibrary("shapes_impl.nim", "lcshapes")
    vaultLib = buildKitLibrary("vault_impl.nim", "lcvault")
    bulkLib = buildKitLibrary("bulk_impl.nim", "lcbulk")
    meterRoot = rootOf("spec/mirrors/IFC/3.9.1.module.cddl")
    shapesRoot = rootOf(fixtureDir / "shapes_module.cddl")
    vaultRoot = rootOf("tests/kit/vault_module.cddl")
    bulkRoot = rootOf("tests/kit/bulk_module.cddl")

  proc hosted(
      instance, module: string, root: seq[byte], lib: string, state = ""
  ): LcnAppModule =
    result = LcnAppModule(
      instance: instance,
      module: module,
      primary_contract: Opt.some(SchemaCommitment(schema_root: root)),
      implementation: LcnAppImplementation(
        kind: LcnAppImplementationKind.Process_hosted_dynamic,
        arm_Process_hosted_dynamic: LcnAppImplementationARProcessHostedDynamicMap(
          artifact:
            LcnAppArtifact(id: instance, local_path: lib, hash: digestOfFile(lib))
        ),
      ),
    )
    if state.len > 0:
      result.state_assignment = Opt.some(state)

  proc grant(root: seq[byte], actions: openArray[LcnApActionKind]): LcnApRule =
    ## [DAEMON.md §7a, "Grants"] An operator rule for `lcn_call` on one contract.
    var xs: seq[LcnApAction]
    for a in actions:
      xs.add(LcnApAction(kind: a))
    sortSet(xs)
    LcnApRule(
      kind: LcnApRuleKind.lcn_Ap_allow,
      arm_lcn_Ap_allow: LcnApAllow(
        subject: LcnApSubject(instances: Opt.some(@[CliInstance])),
        scopes: @[
          LcnApScope(
            kind: LcnApScopeKind.lcn_Ap_provider_access,
            arm_lcn_Ap_provider_access: LcnApProviderAccess(
              contract: LcnApProviderAccessContractChoice(
                kind: LcnApProviderAccessContractChoiceKind.logos_Schema_commitment,
                arm_logos_Schema_commitment: SchemaCommitment(schema_root: root),
              ),
              actions: xs,
            ),
          )
        ],
      ),
    )

  const Full = [
    LcnApActionKind.Discover, LcnApActionKind.Establish_route,
    LcnApActionKind.Renew_route, LcnApActionKind.Call,
  ]

  type Shape = object ## What a case changes in the session.
    workers: uint8 = 4
    routeIdleMs: int ## 0: the default
    validityMs: int ## 0: the default
    bulkDiscover: bool = true ## `discover` on bulk, and nothing else

  var sessions = 0

  proc newSession(shape = Shape()): Session =
    inc sessions
    let base = makeShortBase(
      "lcc" & $sessions, deepest = "/s/run/ep/12345678/logos_shapes_module.sock"
    )
    createDir(base / "o")
    let s = Session(dir: base / "s")
    var dc = defaultDaemonConfig("assigned-by-init")
    dc.runtime.module_host = Opt.some(hostExe)
    dc.runtime.module_host_env = Opt.some(@SanitizerEnv)
    dc.runtime.stop_deadline_ms = Opt.some(uint32(StopDeadlineMs))
    dc.runtime.shutdown_grace_ms = Opt.some(uint32(StopDeadlineMs))
    dc.modules = Opt.some(
      @[
        hosted(MeterInstance, "meter_module", meterRoot, meterLib, MeterState),
        hosted(ShapesInstance, "shapes_module", shapesRoot, shapesLib),
        hosted(VaultInstance, "vault_module", vaultRoot, vaultLib, "vault-state"),
        hosted(BulkInstance, "bulk_module", bulkRoot, bulkLib),
      ]
    )
    var o = dc.orchestration.get(LcnDcOrchestration())
    o.start = Opt.some(Providers)
    dc.orchestration = Opt.some(o)
    var rules =
      @[grant(meterRoot, Full), grant(shapesRoot, Full), grant(vaultRoot, Full)]
    if shape.bulkDiscover:
      rules.add(grant(bulkRoot, [LcnApActionKind.Discover]))
    sortSet(rules)
    dc.policy.arm_Capability_authority.rules = rules
    if shape.validityMs > 0:
      dc.policy.arm_Capability_authority.decision_validity_ms =
        Opt.some(uint64(shape.validityMs))
    dc.ctl = Opt.some(
      LcnDcCtl(workers: Opt.some(8'u8), idle_timeout_ms: Opt.some(uint32(IdleMs)))
    )
    var cli = LcnDcCli(
      artifact: Opt.some(cliArt),
      workers: Opt.some(shape.workers),
      idle_timeout_ms: Opt.some(uint32(IdleMs)),
    )
    if shape.routeIdleMs > 0:
      cli.route_idle_ms = Opt.some(uint32(shape.routeIdleMs))
    dc.cli = Opt.some(cli)
    let r = initSession(s, InitOptions(config: Opt.some(dc)))
    doAssert r.isOk, "init: " & r.error
    s

  # A logosd in this process ---------------------------------------------------------------

  type Live = object
    s: Session
    d: Daemon
    lock: DurableLock
    up: bool
    cli: string ## lcn_call's socket
    outDir: string

  var live: ptr Live ## what the teardown ends, if a case left it running

  proc rc[Req](l: Live, m: LcnCtlMethodKind, req: Req): LcnCtlReply =
    let fd = connectCtl(l.d.socketPath, Timeout).expect("a connection")
    result = roundTrip(fd, rcMessage(m, req.encode.expect("an encoding")), Timeout)
      .expect("a reply")
    closeFd(fd)

  proc okBytes(r: LcnCtlReply): seq[byte] =
    if r.outcome.kind == LcnCtlOutcomeKind.lcn_Ctl_rc_error:
      let e = r.outcome.arm_lcn_Ctl_rc_error
      checkpoint("rc error " & $e.code & ": " & e.message.get(""))
    check r.outcome.kind == LcnCtlOutcomeKind.lcn_Ctl_ok
    if r.outcome.kind == LcnCtlOutcomeKind.lcn_Ctl_ok:
      return r.outcome.arm_lcn_Ctl_ok.result.get(@[])

  proc target(l: Live, instance: string): LogosNSRuntimeModuleInstanceAddress =
    LogosNSRuntimeModuleInstanceAddress(
      module_instance_id: instance,
      runtime_instance_id: l.d.prepared.config.value.runtime.runtime_instance_id,
    )

  proc state(l: Live, instance: string): LogosNSRuntimeControlStateKind =
    let r = l.rc(
      LcnCtlMethodKind.Get_execution_summary,
      LogosNSRuntimeControlGetExecutionSummaryRequest(target: l.target(instance)),
    )
    LogosNSRuntimeControlGetExecutionSummaryResponse
      .decode(r.okBytes)
      .expect("a summary").state.kind

  proc reaches(l: Live, instance: string, s: LogosNSRuntimeControlStateKind): bool =
    let until = getMonoTime() + initDuration(seconds = Patience)
    while getMonoTime() < until:
      if l.state(instance) == s:
        return true
      sleep(20)
    l.state(instance) == s

  proc routes(l: Live): seq[LogosNSRuntimeControlRouteRecord] =
    let r = l.rc(LcnCtlMethodKind.List_routes, LogosNSRuntimeControlListRoutesRequest())
    LogosNSRuntimeControlListRoutesResponse.decode(r.okBytes).expect("routes").routes

  proc cliRoutes(l: Live): seq[LogosNSRuntimeControlRouteRecord] =
    ## `lcn_call`'s ready routes.
    l.routes.filterIt(
      it.consumer.module_instance_id == CliInstance and
        it.state.kind == LogosNSRuntimeControlRouteStateKind.Ready
    )

  proc stop(l: Live, module, instance: string) =
    let r = l.rc(
      LcnCtlMethodKind.Stop_module,
      LogosNSRuntimeControlStopModuleRequest(
        module: module, instance: Opt.some(instance)
      ),
    )
    discard r.okBytes

  proc start(l: Live, module, instance: string) =
    let r = l.rc(
      LcnCtlMethodKind.Start_module,
      LogosNSRuntimeControlStartModuleRequest(
        module: module, instance: Opt.some(instance)
      ),
    )
    discard r.okBytes

  proc boot(s: Session): Live =
    ## Assembles and starts, then waits for the logosctl socket and the four
    ## providers (DAEMON.md §4); `lcn_call` is not started.
    result.s = s
    result.outDir = s.dir.parentDir / "o"
    result.lock = lockSession(s).expect("the session lock")
    let d = assembleDaemon(s, AssembleOptions(version: "test", notify: notifyTest))
    doAssert d.isOk, "assemble: " & d.error.message
    result.d = d.get
    result.cli = cliSocketPath(s, result.d.prepared.config)
    let serving = "logosctl: serving " & result.d.socketPath
    let before = logText().count(serving)
    let r = startDaemon(result.d)
    doAssert r.isOk, "start: " & r.error.message
    result.up = true
    if live != nil:
      live[] = result
    let until = getMonoTime() + initDuration(seconds = Patience)
    while logText().count(serving) == before:
      doAssert getMonoTime() < until,
        "not serving: " & result.d.socketPath & "; the log:\n" & logText()
      sleep(5)
    for p in Providers:
      doAssert result.reaches(p, LogosNSRuntimeControlStateKind.Ready),
        p & " is not ready; the log:\n" & logText()

  proc hostsGone(): bool =
    let until = getMonoTime() + initDuration(seconds = Patience)
    while hostPids().len > 0:
      if getMonoTime() >= until:
        return false
      sleep(20)
    true

  proc finish(l: var Live) =
    if not l.up:
      return
    l.up = false
    discard runtimeRequestShutdown(l.d.rt)
    check int64(runtimeWaitForShutdown(l.d.rt).code) == 0
    check destroyRuntime(l.d).isOk
    l.d.release()
    l.lock.release()
    check hostsGone()
    check not fileExists(l.cli)

  # Commands, as logosctl's launcher runs them ---------------------------------------------

  type Ran = object
    exit: int
    output, errors: string ## what `lcn_call` wrote to stdout and stderr
    failure: string ## what the launcher printed itself, if anything

  var outputs: Atomic[int]

  proc outFile(dir: string): (string, cint) =
    let p = dir / ("o" & $outputs.fetchAdd(1))
    let fd = posix.open(cstring(p), O_CREAT or O_TRUNC or O_WRONLY or O_CLOEXEC, 0o600)
    doAssert fd >= 0, p & ": " & $strerror(errno)
    (p, fd)

  proc run(
      l: Live,
      cmd: LcnCliCommand,
      text = false,
      target = "",
      timeoutMs = Timeout,
      credOf: CredFn = nil,
  ): Ran =
    let (op, ofd) = outFile(l.outDir)
    let (ep, efd) = outFile(l.outDir)
    var msg = LcnCliMessage(
      command: cmd,
      output:
        if text:
          LcnCliOutput(kind: LcnCliOutputKind.Text)
        else:
          LcnCliOutput(kind: LcnCliOutputKind.Json),
    )
    if target.len > 0:
      msg.target = Opt.some(target)
    let r = launch(
      Launch(
        cliSocket: l.cli,
        ctlSocket: l.d.socketPath,
        message: msg,
        stdoutFd: ofd,
        stderrFd: efd,
        timeoutMs: timeoutMs,
        cancelFd: -1,
        credOf: credOf,
      )
    )
    discard posix.close(ofd)
    discard posix.close(efd)
    result.output = readFile(op)
    result.errors = readFile(ep)
    if r.isOk:
      result.exit = r.get
    else:
      result.exit = r.error.exit
      result.failure = r.error.message

  proc env(r: Ran): JsonNode =
    ## The one JSON envelope on stdout.
    try:
      parseJson(r.output.strip)
    except CatchableError as e:
      checkpoint("stdout: " & r.output & "; stderr: " & r.errors & "; " & e.msg)
      newJObject()

  proc said(r: Ran): string =
    "exit " & $r.exit & "; stdout: " & r.output & "; stderr: " & r.errors &
      "; launcher: " & r.failure

  func providerOf(module: string): LcnCliProvider =
    LcnCliProvider(module: module)

  func callOf(
      module, meth: string, args: openArray[(string, string)] = [], request = ""
  ): LcnCliCommand =
    var c = LcnCliCallCommand(`method`: meth, provider: providerOf(module))
    if args.len > 0:
      var xs: seq[LcnCliArg]
      for (k, v) in args:
        xs.add(
          LcnCliArg(
            kind: LcnCliArgKind.lcn_Cli_text_arg,
            arm_lcn_Cli_text_arg: LcnCliTextArg(name: k, value: v),
          )
        )
      c.args = Opt.some(xs)
    if request.len > 0:
      c.json = Opt.some(request)
    LcnCliCommand(
      kind: LcnCliCommandKind.lcn_Cli_call_command, arm_lcn_Cli_call_command: c
    )

  func describeOf(module: string): LcnCliCommand =
    LcnCliCommand(
      kind: LcnCliCommandKind.lcn_Cli_describe_command,
      arm_lcn_Cli_describe_command: LcnCliDescribeCommand(provider: providerOf(module)),
    )

  func meterRead(channel: int): LcnCliCommand =
    callOf("meter_module", "read", [("channel", $channel)])

  # A call held at the meter, from a thread of its own -----------------------------------

  var
    heldExit: Atomic[int]
    heldUnknown: Atomic[bool] ## its output says the outcome is unknown
    heldThread: Thread[(ptr Live, int)]
    holding: bool ## `heldThread` runs and is not joined yet

  proc heldCall(arg: (ptr Live, int)) {.thread.} =
    let (lp, channel) = arg
    let r = lp[].run(meterRead(channel))
    heldUnknown.store(
      "the outcome is unknown" in r.output or "the outcome is unknown" in r.errors or
        "the outcome is unknown" in r.failure
    )
    heldExit.store(r.exit)
    releasePerThread()

  proc meterDir(l: Live): string =
    l.s.modulesDir / MeterState

  proc heldLines(l: Live): int =
    try:
      readFile(l.meterDir / "held").countLines - 1
    except IOError:
      0

  proc hold(l: var Live, channel: int) =
    ## Starts a meter read on `channel` and waits until the meter holds it.
    heldExit.store(-1)
    heldUnknown.store(false)
    createThread(heldThread, heldCall, (addr l, channel))
    holding = true
    let until = getMonoTime() + initDuration(seconds = Patience)
    while l.heldLines == 0:
      doAssert getMonoTime() < until, "the meter holds no call; the log:\n" & logText()
      sleep(5)

  proc joinHeld() =
    if holding:
      joinThread(heldThread)
      holding = false

  var concurrent: array[6, Atomic[int]]

  proc reader(arg: (ptr Live, int)) {.thread.} =
    let (lp, i) = arg
    concurrent[i].store(lp[].run(meterRead(30 + i)).exit)
    releasePerThread()

  proc otherUid(fd: cint): Result[Peer, string] {.nimcall, gcsafe, raises: [].} =
    let p = ?peerOf(fd)
    ok(Peer(uid: p.uid + 1, pid: p.pid))

  # Cases ---------------------------------------------------------------------------------

  suite "cli.lcn_call: the CLI module in logosd (DAEMON.md §7a) [IMPL-DECISION G343] [IMPL-DECISION G344] [IMPL-DECISION G348] [IMPL-DECISION G349]":
    setup:
      var l {.inject.} = Live()
      live = addr l

    teardown:
      if live != nil:
        if holding and live[].up:
          try:
            writeFile(live[].meterDir / "open", "")
          except IOError:
            discard
        joinHeld()
        if live[].up:
          finish(live[])
      live = nil

    test "[BCP-0086] [BCP-0088] L-1: the first command starts lcn_call, later ones reuse it and its route; a restarted Runtime resumes it; after module stop the next command starts it again":
      let s = newSession()
      l = boot(s)
      check l.state(CliInstance) == LogosNSRuntimeControlStateKind.Unloaded
      check not fileExists(l.cli)
      let a = l.run(meterRead(7))
      checkpoint a.said
      check a.exit == 0
      let e = a.env
      check e{"status"}.getStr == "ok"
      check e{"result", "label"}.getStr == "ch7"
      check e{"result", "reading", "value"}.getInt == 70
      check l.state(CliInstance) == LogosNSRuntimeControlStateKind.Ready
      let first = l.cliRoutes
      check first.len == 1
      check l.run(meterRead(8)).exit == 0
      let second = l.cliRoutes
      check second.len == 1
      if first.len == 1 and second.len == 1:
        check second[0].route == first[0].route
      # [G350] Stopped by the operator, it is started again by the next command.
      l.stop("lcn_call", CliInstance)
      check l.reaches(CliInstance, LogosNSRuntimeControlStateKind.Unloaded)
      let b = l.run(meterRead(9))
      checkpoint b.said
      check b.exit == 0
      check l.state(CliInstance) == LogosNSRuntimeControlStateKind.Ready
      # [plan R1] The orchestrator resumes it after a restart: its retained
      # intent is `requested`.
      finish(l)
      l = boot(s)
      check l.reaches(CliInstance, LogosNSRuntimeControlStateKind.Ready)
      check l.run(meterRead(10)).exit == 0

    test "L-2: key=value typed from the request rule, --request, JSON and text output":
      l = boot(newSession())
      let a = l.run(meterRead(9))
      checkpoint a.said
      check a.exit == 0
      check a.env{"result", "label"}.getStr == "ch9"
      check a.errors == ""
      let t = l.run(meterRead(9), text = true)
      checkpoint t.said
      check t.exit == 0
      check "\"ch9\"" in t.output
      check t.errors == ""
      check "\"deployment\"" notin t.output # diagnostic notation, no envelope
      # [D26 (a)] The whole request as one JSON object; `reflect` answers with
      # it, which G89 renders as it was written.
      let r = l.run(callOf("shapes_module", "reflect", request = ReflectRequest))
      checkpoint r.said
      check r.exit == 0
      check r.env{"result"} == parseJson(ReflectRequest)
      # A value its field does not read is refused before any call (1).
      let bad = l.run(callOf("meter_module", "read", [("channel", "x")]))
      checkpoint bad.said
      check bad.exit == 1
      check bad.env{"status"}.getStr == "error"
      let badText =
        l.run(callOf("meter_module", "read", [("channel", "x")]), text = true)
      check badText.exit == 1
      check badText.output == ""
      check badText.errors.startsWith("logosctl: ")

    test "L-3: refusals (1), a Runtime Control failure (4) and the provider's error channel (5)":
      l = boot(newSession())
      for (cmd, what) in [
        (callOf("nosuch_module", "read", [("channel", "1")]), "an unknown module"),
        (callOf("meter_module", "nosuch"), "an unknown method"),
      ]:
        checkpoint what
        let r = l.run(cmd)
        checkpoint r.said
        check r.exit == 1
      let node = l.run(meterRead(1), target = "elsewhere")
      checkpoint node.said
      check node.exit == 1
      check "elsewhere" in node.env{"message"}.getStr
      # `discover` alone on bulk: describe works, the route is not authorised.
      check l.run(describeOf("bulk_module")).exit == 0
      let na = l.run(callOf("bulk_module", "send", [("size", "1")]))
      checkpoint na.said
      check na.exit == 4
      check na.env{"code"}.getStr == "NOT_AUTHORISED"
      check l.cliRoutes.allIt(it.module != "bulk_module")
      # Channel 13 fails with a message: the provider's error channel.
      let pe = l.run(meterRead(13))
      checkpoint pe.said
      check pe.exit == 5
      check pe.env{"status"}.getStr == "error"
      let peText = l.run(meterRead(13), text = true)
      check peText.exit == 5
      check "(declared)" in peText.errors

    test "[IFC-0942] L-4: describe prints the provider's contracts, roots and methods":
      l = boot(newSession())
      for (module, instance, root, meth) in [
        ("meter_module", MeterInstance, meterRoot, "read"),
        ("shapes_module", ShapesInstance, shapesRoot, "reflect"),
      ]:
        checkpoint module
        let d = l.run(describeOf(module))
        checkpoint d.said
        check d.exit == 0
        let r = d.env{"result"}
        check r{"module"}.getStr == module
        check r{"instance"}.getStr == instance
        check r{"selected"}.getStr == hexOf(root)
        check r{"record", "primary"}.getStr == hexOf(root)
        let cs = r{"contracts"}.getElems
        check cs.len == 1
        if cs.len == 1:
          check cs[0]{"role"}.getStr == "primary"
          check cs[0]{"root"}.getStr == hexOf(root)
        check r{"methods"}.getElems.anyIt(
          it{"method"}.getStr == meth and not it{"marked"}.getBool
        )
      let t = l.run(describeOf("meter_module"), text = true)
      checkpoint t.said
      check t.exit == 0
      check hexOf(meterRoot) & " (selected)" in t.output
      check "  read " in t.output

    test "L-5: a marked method is refused before any route; an unmarked one of the same provider is called":
      when ChannelsMove:
        l = boot(newSession())
        let d = l.run(describeOf("vault_module"))
        check d.exit == 0
        check d.env{"result", "methods"}.getElems.anyIt(
          it{"method"}.getStr == "store" and it{"marked"}.getBool
        )
        let s =
          l.run(callOf("vault_module", "store", [("slot", "1"), ("secret", "00")]))
        checkpoint s.said
        check s.exit == 1
        check "store" in s.env{"message"}.getStr
        check l.cliRoutes.len == 0
        let p = l.run(callOf("vault_module", "peek", [("slot", "1")]))
        checkpoint p.said
        check p.exit == 0
        check p.env{"result", "stored"}.getBool == false
        check l.cliRoutes.len == 1
      else:
        skip() # [DECISIONS G277] a refc build starts no marked provider

    test "[BCP-0089] L-6: the route is lcn_call's, to the hosted provider; the launcher gets an exit status and the output, no route":
      l = boot(newSession())
      let a = l.run(meterRead(7))
      check a.exit == 0
      let rs = l.cliRoutes
      check rs.len == 1
      if rs.len == 1:
        let r = rs[0]
        check r.consumer.module_instance_id == CliInstance
        check r.module == "meter_module"
        check r.instance == Opt.some(MeterInstance)
        check r.invocation.isNone
      var keys: seq[string]
      for k, _ in a.env.pairs:
        keys.add(k)
      check keys.sorted == @["command", "deployment", "result", "status"]

    test "[BCP-0087] L-7: activation cannot select: an instance or artifact field, or an unknown op, is refused protocol":
      l = boot(newSession())
      check l.run(meterRead(7)).exit == 0 # lcn_call is up
      let good =
        LcnCliMessage(
          command: meterRead(7),
          output: LcnCliOutput(kind: LcnCliOutputKind.Json),
          fds: @[
            LcnCliFdRole(kind: LcnCliFdRoleKind.Stdout),
            LcnCliFdRole(kind: LcnCliFdRoleKind.Stderr),
          ],
        ).toCbor
      var bad: seq[(string, CborValue)]
      for (field, value) in [("instance", cbor(MeterInstance)), ("artifact", cbor("x"))]:
        var v = good
        v.entries.add((cbor(field), value))
        bad.add((field, v))
      var unknownOp = good
      for e in unknownOp.entries.mitems:
        if e.key == cbor("command"):
          e.value = cborMap(
            (cbor("op"), cbor("frobnicate")),
            (cbor("provider"), cborMap((cbor("module"), cbor("meter_module")))),
          )
      bad.add(("an unknown op", unknownOp))
      for (what, v) in bad:
        checkpoint what
        let (_, ofd) = outFile(l.outDir)
        let (_, efd) = outFile(l.outDir)
        let fd = connectCtl(l.cli, Timeout).expect("a connection")
        check writeRequest(fd, encodeCbor(v), [ofd, efd], Timeout).isOk
        let reply = readReply(fd, Timeout)
        check reply.isOk
        if reply.isOk:
          check reply.get.outcome.kind == LcnCliOutcomeKind.lcn_Cli_refused
          if reply.get.outcome.kind == LcnCliOutcomeKind.lcn_Cli_refused:
            check reply.get.outcome.arm_lcn_Cli_refused.reason.kind ==
              LcnCliRefusedReasonChoiceKind.Protocol
        closeFd(fd)
        discard posix.close(ofd)
        discard posix.close(efd)
      check l.run(meterRead(7)).exit == 0 # still serving

    test "L-8: with workers = 1 a second command is refused busy until its timeout; a listener of another uid is refused; without discover, describe is a Runtime Control failure (4)":
      l = boot(newSession(Shape(workers: 1, bulkDiscover: false)))
      l.hold(22)
      let busy = l.run(meterRead(7), timeoutMs = 1_500 * Slow)
      checkpoint busy.said
      check busy.exit == 2
      check "busy" in busy.failure
      writeFile(l.meterDir / "open", "")
      joinHeld()
      check heldExit.load == 0
      check l.heldLines == 1
      check l.run(meterRead(7)).exit == 0
      # [K20] The launcher checks the listener's uid before it sends anything.
      let other = l.run(meterRead(7), credOf = otherUid)
      checkpoint other.said
      check other.exit == 2
      check other.output == "" and other.errors == ""
      let nd = l.run(describeOf("bulk_module"))
      checkpoint nd.said
      check nd.exit == 4
      check nd.env{"code"}.getStr == "NOT_AUTHORISED"

    test "L-9: lcn_call's host killed: the next command recovers it and succeeds":
      l = boot(newSession())
      let before = hostPids()
      check l.run(meterRead(7)).exit == 0
      let mine = hostPids().filterIt(it notin before)
      check mine.len == 1
      if mine.len == 1:
        check posix.kill(Pid(mine[0]), SIGKILL) == 0
        check l.reaches(CliInstance, LogosNSRuntimeControlStateKind.Error)
        let r = l.run(meterRead(7))
        checkpoint r.said
        check r.exit == 0
        check l.state(CliInstance) == LogosNSRuntimeControlStateKind.Ready
        check mine[0] notin hostPids()

    test "L-10: calls past a short decision validity, concurrent calls on one route, an idle close, and a call after the provider restarted":
      # [IMPL] A decision takes up to about 1.5 s on a loaded host (refc, or a
      # load of 100), and its validity runs from it. With 8 s and a command
      # every second, the next command renews the route before it ends; the
      # idle close comes only after the calls stop.
      let validity = 8_000 * Slow
      let idle = validity
      l = boot(newSession(Shape(validityMs: validity, routeIdleMs: idle)))
      check l.run(meterRead(7)).exit == 0
      let first = l.cliRoutes
      check first.len == 1
      # [G348] Past the decision's validity the route is renewed onto a new
      # handle: the calls go on, on the same route.
      let began = getMonoTime()
      var calls = 0
      while calls < 3 or
          getMonoTime() - began < initDuration(milliseconds = 2 * validity):
        let r = l.run(meterRead(7))
        checkpoint r.said
        check r.exit == 0
        inc calls
        sleep(validity div 8)
      let renewed = l.cliRoutes
      check renewed.len == 1
      if first.len == 1 and renewed.len == 1:
        check renewed[0].route == first[0].route
        check renewed[0].decision_id != first[0].decision_id
      # Six workers call on the one route at once.
      var threads: array[6, Thread[(ptr Live, int)]]
      for i in 0 ..< threads.len:
        concurrent[i].store(-1)
        createThread(threads[i], reader, (addr l, i))
      joinThreads(threads)
      for i in 0 ..< threads.len:
        check concurrent[i].load == 0
      check l.cliRoutes.len == 1
      # [G348, G350] Unused for `route_idle_ms`, lcn_call closes it.
      let closing = getMonoTime() + initDuration(milliseconds = idle + Patience * 1000)
      while l.cliRoutes.len > 0 and getMonoTime() < closing:
        sleep(50)
      check l.cliRoutes.len == 0
      check l.state(CliInstance) == LogosNSRuntimeControlStateKind.Ready
      check l.run(meterRead(7)).exit == 0
      let again = l.cliRoutes
      check again.len == 1
      if again.len == 1 and first.len == 1:
        check again[0].route != first[0].route
      # [G348; plan §3.5 step 8] After the provider restarted, the ended handle
      # is not used (rule 1) or a NOT_READY completion is retried once (rule 2).
      l.stop("meter_module", MeterInstance)
      check l.reaches(MeterInstance, LogosNSRuntimeControlStateKind.Unloaded)
      l.start("meter_module", MeterInstance)
      check l.reaches(MeterInstance, LogosNSRuntimeControlStateKind.Ready)
      let after = l.run(meterRead(7))
      checkpoint after.said
      check after.exit == 0

    test "L-13: a route ended while its call is in flight: exit 2, the outcome unknown, no retry; the provider saw one call":
      l = boot(newSession())
      check l.run(meterRead(7)).exit == 0
      # Channel 23 waits for `open` alone: the stop ends at its deadline, and
      # the provider's host with it, while the call is admitted and running.
      l.hold(23)
      l.stop("meter_module", MeterInstance)
      joinHeld()
      check heldExit.load == 2
      check heldUnknown.load
      check l.heldLines == 1
      check l.reaches(MeterInstance, LogosNSRuntimeControlStateKind.Unloaded)
else:
  import unittest2

  suite "cli.lcn_call: the CLI module in logosd (POSIX only)":
    test "[IMPL] logosd is a stub on this platform (DECISIONS G107); there is no lcn_call to run":
      skip()
