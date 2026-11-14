## Hosted realization at engine level (Tier 4b step 4b-3, part 4b-3.1a;
## DECISIONS I91, G264-G268, G271, G272; plan §4.3): an engine with a Module
## Host program (`EngineConfig.moduleHost`), 4b-1's Module Loader realizing
## `hosted_dynamic` records through real `logos-module-host` processes, and
## the probe module (`tests/kit/probe_impl.nim`), consumer-only, which reads
## what to do from its state directory and writes what it saw there.
##
## The same library realized `direct_dynamic` on an engine with the same
## Runtime instance id is the reference: what the probe sees through Runtime
## Control in a host is what it sees in process (RUNTIME l.970).
##
## S-1 (the Loader's capabilities with and without a host program) is in
## `test_loader`. Part 4b-3.1b adds S-4's request after the attempt ended and
## the ends of a host, S-7 to S-16 (G268-G270, G275); S-18, a stopping hosted
## consumer's calls into other endpoints, needs 4b-3.3's handles. S-19 shows
## the release waiting for a handler still running (G267). After every case no
## host of this build is left.

when defined(posix):
  import std/[atomics, monotimes, os, sequtils, strutils, times, typedthreads]
  import std/posix except Time
  import unittest2
  import ../src/logos_core/runtime/engine
  import ../src/logos_core/runtime/[hostlock, hostsup, store]
  import ../src/logos_core/abi/types
  import ../src/logos_core/cbor
  import ../src/logos_core/commitment
  import ../src/logos_core/crypto/blake3
  import ../src/logos_core/iface/[accept, outcome, surface]
  import ../src/logos_core/iface/common_types
  import ../src/logos_core/authority/scopes except
    LogosNSRuntimeModuleInstanceAddress, LogosNSRuntimeModuleInstanceId,
    LogosNSRuntimeModuleName, LogosNSRuntimeModuleProviderAddress,
    LogosNSRuntimeModuleProviderId, LogosNSRuntimeModuleStateAssignmentId,
    LogosNSRuntimeRouteId, LogosNSRuntimeRuntimeInstanceId
  import ../src/logos_core/loader/contract
  import ../src/logos_core/pins
  import
    ./support/[
      fakeca, kitbuild, kitruntime, modulehostbuild, shortdir, tunerconfig,
      withoutloader,
    ]
  import ./kit/meter_impl
  import ./generated/meter_module_calls

  let
    repo = currentSourcePath().parentDir.parentDir
    work = repo / "build" / "hosted" / kitVariant
  removeDir(work)
  createDir(work)

  include ./support/routefixture
  include ./support/configrc

  # [R10] A route with a hosted end is local-transport: its endpoints go
  # under a short private base, `<base>/e<n>/<8 hex>/logos_meter_module.sock`.
  let shortBase = makeShortBase("lcnhs", "/e999/12345678/logos_meter_module.sock")

  const
    RuntimeId = "0b6f2d4e-8a1c-4f3b-9d2e-7c5a1b3e9f40"
      ## both engines of a comparison: the probe's own address is the same
    SanitizerEnv =
      ["ASAN_OPTIONS", "LSAN_OPTIONS", "MSAN_OPTIONS", "TSAN_OPTIONS", "UBSAN_OPTIONS"]
      ## the host's environment allow-list here: the sanitizers' settings only
    ModuleStateEv = "logos.runtime_control.module_state_changed_event"

  let
    hostProgram = moduleHostProgram()
    probeLib = buildKitLibrary("probe_impl.nim", "probe")

  # Set-up -------------------------------------------------------------------------------

  proc digestOf(path: string): array[32, byte] =
    var h: Blake3Hasher
    h.init()
    let bytes = readFile(path)
    h.update(bytes.toOpenArrayByte(0, bytes.high))
    h.finish()

  let probeDigest = digestOf(probeLib)

  proc probe(
      hosted = true, placement = "process", digest = probeDigest, state = "p"
  ): ModuleRecord =
    ## The probe library, `hosted_dynamic` or `direct_dynamic`, with state
    ## assignment `state`.
    ModuleRecord(
      module: "probe_module",
      strategy: (if hosted: stHostedDynamic else: stDirectDynamic),
      placement: (if hosted: placement else: ""),
      artifact: ArtifactRecord(
        id: "probe", localPath: probeLib, hash: digest, hashSuite: HashSuiteId
      ),
      stateAssignment: Opt.some(state),
    )

  proc hostedConfig(host = true, extra: seq[StaticRegistration] = @[]): EngineConfig =
    ## The fixture's configuration with a state root, the fixed Runtime
    ## instance id, and with `host` the Module Host program.
    result = config(extra = extra)
    result.runtimeInstanceId = RuntimeId
    result.stateRoot = Opt.some(result.workDir / "state")
    result.endpointDir = shortBase / ("e" & $engines)
    if host:
      result.moduleHost = Opt.some(hostProgram)
      result.moduleHostEnv = @SanitizerEnv

  proc prepareAt(cfg: EngineConfig, state: string, commands: varargs[string]): string =
    ## The state directory `state`, holding the probe's `commands`.
    result = cfg.stateRoot.get / state
    createDir(result)
    writeFile(result / "probe.cmd", commands.join("\n") & "\n")

  proc prepare(cfg: EngineConfig, commands: varargs[string]): string =
    ## The probe's state directory, holding `commands` before its start.
    cfg.prepareAt("p", commands)

  proc lines(dir, file: string): seq[string] =
    try:
      readFile(dir / file).splitLines.filterIt(it.len > 0)
    except IOError:
      @[]

  func hex(b: openArray[byte]): string =
    for x in b:
      result.add(toHex(x, 2).toLowerAscii)

  func text(b: openArray[byte]): string =
    result = newString(b.len)
    for i, x in b:
      result[i] = char(x)

  proc hostsLeft(): seq[int] =
    hostPids(hostProgram)

  proc noHostLeft(): bool =
    waitUntil(
      proc(): bool =
        hostsLeft().len == 0
    )

  proc failureOf(v: InstanceView): string =
    if v.failure.isSome: v.failure.get.classification else: ""

  proc address(e: Engine, instance: string): LogosNSRuntimeModuleInstanceAddress =
    LogosNSRuntimeModuleInstanceAddress(
      runtime_instance_id: e.runtimeInstanceId, module_instance_id: instance
    )

  proc summary(
      rc: ptr LogosRuntimeControlBinding, e: Engine, instance: string
  ): LogosNSRuntimeControlGetExecutionSummaryResponse =
    let r = rcCall(
      rc,
      "get_execution_summary",
      encode(
        LogosNSRuntimeControlGetExecutionSummaryRequest(target: e.address(instance))
      ).tryGet,
    )
    check r.code == ecOk
    LogosNSRuntimeControlGetExecutionSummaryResponse.decode(r.response).tryGet

  proc realizations(e: Engine): int =
    e.loaderJournalForTests().countIt(it.meth == $lmRealize)

  proc settled(dir, file: string, atLeast: int): seq[string] =
    ## `file`'s lines once there are `atLeast` and no more arrive for a while.
    discard waitUntil(
      proc(): bool =
        lines(dir, file).len >= atLeast
    )
    var last = -1
    while true:
      result = lines(dir, file)
      if result.len == last:
        return
      last = result.len
      sleep(150 * Slow)

  type Transition = (string, string, string) ## instance, state, failure

  proc transitions(e: Engine): seq[Transition] =
    for c in e.changes().withoutLoader:
      result.add((c.view.instance, $c.view.state, c.view.failureOf))

  # S-2, S-3 ---------------------------------------------------------------------------

  suite "run.hosted: a hosted consumer (RUNTIME §4.2.1; LOADER §5.2, §12)":
    teardown:
      leftover()
      check noHostLeft()

    test "[RUN-0169] [LDR-0045] [LDR-0149] S-2 a hosted consumer-only probe is ready in a process of its own; no record or answer names the host program, the artifact, the work directory or the host's process":
      let cfg = hostedConfig()
      let dir = cfg.prepare("env")
      let e = fixtureEngine(cfg)
      let (_, rc) = e.startClient("c")
      discard e.create(probe(), "p").tryGet
      check e.start("p").tryGet.state == msReady
      check lines(dir, "inits") == @["init"]
      let pids = hostsLeft()
      check pids.len == 1
      # [plan R4] The host's environment holds allow-listed names only (on
      # macOS, CoreFoundation sets its own in the process when it is absent;
      # H-14 shows the spawn passes none).
      for name in lines(dir, "env"):
        check name in SanitizerEnv or
          (defined(macosx) and name == "__CF_USER_TEXT_ENCODING")
      let s = rc.summary(e, "p")
      type
        R = LogosNSRuntimeControlGetExecutionSummaryResponseRealizationChoiceKind
        K = LogosNSRuntimeControlExecutionSelectionImplementationChoiceKind
        P =
          LogosNSRuntimeControlExecutionSelectionImplementationARHostedDynamicPlacementChoiceKind

      check s.realization.kind == R.Current
      check s.selection.isSome
      let impl = s.selection.get.implementation
      check impl.kind == K.Hosted_dynamic
      if impl.kind == K.Hosted_dynamic:
        check impl.arm_Hosted_dynamic.placement.kind == P.Process
      let answers = @[
        rcCall(
          rc,
          "get_execution_summary",
          encode(
            LogosNSRuntimeControlGetExecutionSummaryRequest(target: e.address("p"))
          ).tryGet,
        ),
        rcCall(
          rc, "list_modules", encode(LogosNSRuntimeControlListModulesRequest()).tryGet
        ),
        rc.readiness("probe_module", Opt.some("p")),
      ]
      for a in answers:
        check a.code == ecOk
        let t = text(a.response)
        for secret in [hostProgram, probeLib, cfg.workDir, dir]:
          check secret notin t
      for line in e.diagnostics():
        for secret in @[hostProgram, probeLib, cfg.workDir, dir] & pids.mapIt($it):
          check secret notin line
      check e.stop("p").tryGet.state == msUnloaded
      check lines(dir, "destroyed") == @["destroyed"]
      check rc.summary(e, "p").realization.kind == R.Absent
      check noHostLeft()
      e.finish()

    test "[RUN-0170] [RUN-0171] [RUN-0172] [RUN-0180] S-3 Runtime Control from the host gives the probe the values, errors and transitions it gets in process":
      proc requests(): seq[string] =
        let
          self = encode(
            LogosNSRuntimeControlGetReadinessRequest(
              module: "probe_module", instance: Opt.some("p")
            )
          ).tryGet
          client = encode(
            LogosNSRuntimeControlGetReadinessRequest(
              module: "client_module", instance: Opt.some("c")
            )
          ).tryGet
          unknown = encode(
            LogosNSRuntimeControlGetReadinessRequest(module: "nope_module")
          ).tryGet
          startC = encode(
            LogosNSRuntimeControlStartModuleRequest(
              module: "client_module", instance: Opt.some("c")
            )
          ).tryGet
          stopM = encode(
            LogosNSRuntimeControlStopModuleRequest(
              module: "meter_module", instance: Opt.some("m")
            )
          ).tryGet
        @[
          "rc get_self a0",
          "rc get_readiness " & hex(self),
          "rc get_readiness " & hex(client),
          "rc get_readiness " & hex(unknown),
          "rc get_self ff",
          "rc no_such_method a0",
          "rc get_execution_permissions a0",
          "rc start_module " & hex(startC),
          "rc stop_module " & hex(stopM),
          "rc get_readiness " & hex(self),
        ]

      proc run(hosted: bool): (seq[string], seq[Transition]) =
        let cfg = hostedConfig(hosted)
        let dir = cfg.prepare(requests())
        let e = fixtureEngine(cfg)
        discard e.startClient("c")
        discard e.started(meter(), "m")
        discard e.create(probe(hosted), "p").tryGet
        check e.start("p").tryGet.state == msReady
        check e.view("m").tryGet.state == msUnloaded # stopped by the probe
        result = (lines(dir, "rc"), e.transitions)
        e.finish()

      let (direct, directChanges) = run(false)
      let (hosted, hostedChanges) = run(true)
      check direct.len == requests().len
      # get_self: the probe's own address, from the Runtime's launch state.
      let selfBytes = direct[0].split(' ')[^1].parseHexStr.mapIt(byte(it))
      let self = LogosNSRuntimeControlGetSelfResponse.decode(selfBytes)
      check self.isOk
      if self.isOk:
        check self.get.consumer.runtime_instance_id == RuntimeId
        check self.get.consumer.module_instance_id == "p"
      check direct[4].startsWith($ord(ecInvalidParams) & " ")
      check hosted == direct
      check hostedChanges == directChanges

  # S-5 ---------------------------------------------------------------------------------

  suite "run.hosted: Runtime Control Events in a host (RUNTIME §9.3; G178, G225)":
    teardown:
      leftover()
      check noHostLeft()

    test "[IMPL-DECISION G178] S-5 a host's subscription sees the committed order, one handler at a time, and its handler calls Runtime Control, as in process":
      proc run(hosted: bool): seq[string] =
        let cfg = hostedConfig(hosted)
        let dir = cfg.prepare("subscribe " & ModuleStateEv)
        let e = fixtureEngine(cfg)
        discard e.create(probe(hosted), "p").tryGet
        check e.start("p").tryGet.state == msReady
        discard e.create(slow(), "s").tryGet
        for i in 0 ..< 3:
          check e.start("s").tryGet.state == msReady
          check e.stop("s").tryGet.state == msUnloaded
        # The probe's own start, then two transitions per start and per stop.
        result = settled(dir, "events", 1 + 1 + 1 + 12)
        e.finish()

      let direct = run(false)
      let hosted = run(true)
      check direct.len >= 15
      check "overlap" notin direct
      check direct.anyIt(it.startsWith("rc "))
      check hosted == direct

    test "[IMPL-DECISION G225] S-5 a host's handler past the queue bound loses its subscription with the in-process diagnostic":
      var cfg = hostedConfig()
      cfg.limits.rcQueue = 4
      let dir = cfg.prepare("subscribe " & ModuleStateEv, "block-handler")
      let e = fixtureEngine(cfg)
      discard e.create(probe(), "p").tryGet
      check e.start("p").tryGet.state == msReady
      # The probe's own `loaded` to `ready` is held in its handler.
      check waitUntil(
        proc(): bool =
          lines(dir, "events").anyIt(it.startsWith(ModuleStateEv))
      )
      discard e.create(slow(), "s").tryGet
      for i in 0 ..< 4:
        check e.start("s").tryGet.state == msReady
        check e.stop("s").tryGet.state == msUnloaded
      check waitUntil(
        proc(): bool =
          e.diagnostics().anyIt(" of p lost: its handler fell behind (G225)" in it)
      )
      writeFile(dir / "go-handler", "")
      sleep(150 * Slow)
      let delivered = lines(dir, "events").countIt(it.startsWith(ModuleStateEv))
      check delivered == 1 # the one held; the queue went
      check e.start("s").tryGet.state == msReady
      sleep(150 * Slow)
      check lines(dir, "events").countIt(it.startsWith(ModuleStateEv)) == delivered
      e.finish()

    test "[IMPL-DECISION G267] S-19 a stop releases the host only once an event handler still running has returned: `_MODULE_destroy` comes after it":
      var cfg = hostedConfig()
      let dir = cfg.prepare("subscribe " & ModuleStateEv, "block-handler")
      let e = fixtureEngine(cfg)
      discard e.create(probe(), "p").tryGet
      check e.start("p").tryGet.state == msReady
      # The probe's own `loaded` to `ready` is held in its handler.
      check waitUntil(
        proc(): bool =
          lines(dir, "events").anyIt(it.startsWith(ModuleStateEv))
      )
      var stopping: Thread[(Engine, string)]
      proc stopOn(arg: (Engine, string)) {.thread.} =
        discard arg[0].stop(arg[1])

      createThread(stopping, stopOn, (e, "p"))
      sleep(300 * Slow)
      check lines(dir, "destroyed").len == 0
      check e.view("p").tryGet.state == msStopping
      writeFile(dir / "go-handler", "")
      joinThread(stopping)
      check e.view("p").tryGet.state == msUnloaded
      check lines(dir, "destroyed") == @["destroyed"]
      e.finish()

  # S-6 ---------------------------------------------------------------------------------

  suite "run.hosted: what is not hosted (LOADER §3, §6; RUNTIME §8)":
    teardown:
      leftover()
      check noHostLeft()

    test "[LDR-0067] [LDR-0068] S-6 a placement the Loader did not advertise, or no host program, fails `loader-unsupported-strategy` before any code is loaded":
      for (host, placement) in [
        (true, "sandbox"), (true, "container"), (false, "process")
      ]:
        let cfg = hostedConfig(host)
        let dir = cfg.prepare()
        let e = fixtureEngine(cfg)
        discard e.create(probe(placement = placement), "p").tryGet
        let v = e.start("p").tryGet
        check v.state != msReady
        check v.failureOf == "loader-unsupported-strategy"
        check lines(dir, "inits").len == 0
        check hostsLeft().len == 0
        e.finish()

    test "[LDR-0025] S-6 an artifact whose bytes do not match its digest fails `loader-artifact-integrity-failed`; no host is started":
      let cfg = hostedConfig()
      let dir = cfg.prepare()
      let e = fixtureEngine(cfg)
      var wrong = probeDigest
      wrong[0] = wrong[0] xor 1
      discard e.create(probe(digest = wrong), "p").tryGet
      let v = e.start("p").tryGet
      check v.failureOf == "loader-artifact-integrity-failed"
      check lines(dir, "inits").len == 0
      check hostsLeft().len == 0
      e.finish()

    test "[RUN-0284] S-6 a hosted record with a static binding and no artifact is refused":
      let e = fixtureEngine(hostedConfig())
      let r = e.create(
        ModuleRecord(
          module: "probe_module",
          strategy: stHostedDynamic,
          placement: "process",
          binding: "probe",
        ),
        "p",
      )
      check r.isErr and r.error.code == ecInvalidParams
      e.finish()

  # S-17 --------------------------------------------------------------------------------

  suite "run.hosted: execution authorization (CA §3.3; plan §2.11)":
    teardown:
      leftover()
      check noHostLeft()

    test "[CAP-0065] [CAP-0066] S-17 a hosted start under a Capability Authority asks for `local-transport` in a `process`; a deny refuses before the Loader realizes":
      resetFake()
      var cfg = hostedConfig(extra = @[fakeCaRegistration()])
      cfg.authority = Opt.some(
        AuthorityPolicy(instance: "ca", evaluationDeadline: initDuration(seconds = 60))
      )
      let dir = cfg.prepare()
      let e = fixtureEngine(cfg)
      check e.bootstrap(
        @[
          BootstrapInstance(instance: "orch", record: client()),
          BootstrapInstance(instance: "ca", record: fakeCaRecord()),
        ],
        "orch",
      ).isOk
      let orch = cast[ptr LogosRuntimeControlBinding](clients[
        (clientInits.load - 1) mod MaxClients
      ].load)
      check orch.lifecycle("start_module", CaModuleName, Opt.some("ca")).code == ecOk
      check e.authorityBound()[0]
      discard e.create(probe(), "p").tryGet
      forget()
      check orch.lifecycle("start_module", "probe_module", Opt.some("p")).code == ecOk
      let ex = received().filterIt(it.what == "execute")
      check ex.len == 1
      if ex.len == 1:
        let req = LogosNSCapabilityAuthorityEvaluateRequest.decode(ex[0].request).tryGet
        check req.scopes.len == 1 and req.scopes[0].kind == skExecution
        let me = req.scopes[0].me
        check me.instance == Opt.some("p")
        check me.modes.get(@[]).mapIt(it.kind) == @[ExecModeKind.Local_transport]
        check me.placements.get(@[]).mapIt(it.kind) == @[PlacementKind.Process]
      check lines(dir, "inits") == @["init"]
      check orch.lifecycle("stop_module", "probe_module", Opt.some("p")).code == ecOk
      check noHostLeft()
      let before = e.realizations
      setScript(
        rule(
          vDeny,
          "execute",
          code = ord(LogosNSCapabilityAuthorityDenialCodeKind.Scope_denied),
        )
      )
      check orch.lifecycle("start_module", "probe_module", Opt.some("p")).code ==
        ecNotAuthorised
      let v = e.view("p").tryGet
      check v.failure.isSome and v.failure.get.kind == fkAuthorityDenied
      check e.realizations == before
      check lines(dir, "inits") == @["init"]
      check hostsLeft().len == 0
      e.finish()
  # 4b-3.1b: the ends of a host ---------------------------------------------------------

  proc hostOf(e: Engine, instance: string): Host =
    ## The instance's Module Host, retained: `dropHost` it.
    e.moduleHostForTests(instance)

  proc killHost(e: Engine, instance: string): bool =
    ## SIGKILL to the instance's host process, from outside the Runtime.
    let h = e.hostOf(instance)
    if h.isNil:
      return false
    let pid = pidOf(h)
    dropHost(h)
    pid > 0 and posix.kill(Pid(pid), SIGKILL) == 0

  proc realization(
      rc: ptr LogosRuntimeControlBinding, e: Engine, instance: string
  ): LogosNSRuntimeControlGetExecutionSummaryResponseRealizationChoiceKind =
    rc.summary(e, instance).realization.kind

  type R = LogosNSRuntimeControlGetExecutionSummaryResponseRealizationChoiceKind

  proc errorWith(e: Engine, instance, classification: string): bool =
    waitUntil(
      proc(): bool =
        let v = e.view(instance).tryGet
        v.state == msError and v.failureOf == classification
    )

  proc absentAgain(
      e: Engine, rc: ptr LogosRuntimeControlBinding, instance: string
  ): bool =
    waitUntil(
      proc(): bool =
        rc.realization(e, instance) == R.Absent and not e.cleanupPending(instance)
    )

  proc releases(e: Engine, instance: string): int =
    e.loaderJournalForTests().countIt(it.meth == $lmRelease and it.instance == instance)

  suite "run.hosted: a request after the attempt ended (RUNTIME §4.2.1)":
    teardown:
      leftover()
      check noHostLeft()

    test "[RUN-0172] S-4 a Runtime Control request the host makes from `_MODULE_destroy` is answered as in process":
      let self = encode(
        LogosNSRuntimeControlGetReadinessRequest(
          module: "probe_module", instance: Opt.some("p")
        )
      ).tryGet
      proc run(hosted: bool): seq[string] =
        let cfg = hostedConfig(hosted)
        let dir =
          cfg.prepare("rc-destroy get_readiness " & hex(self), "rc-destroy get_self a0")
        let e = fixtureEngine(cfg)
        discard e.create(probe(hosted), "p").tryGet
        check e.start("p").tryGet.state == msReady
        check e.stop("p").tryGet.state == msUnloaded
        result = lines(dir, "rc-destroy")
        e.finish()

      let direct = run(false)
      check direct.len == 2
      check run(true) == direct

  suite "run.hosted: a host that ends by itself (RUNTIME l.975-976; G268)":
    teardown:
      leftover()
      check noHostLeft()

    test "[RUN-0812] [RUN-0813] [IMPL-DECISION G268] S-7 a host whose module exits, or that is killed from outside: `error` with `host-terminated`, its routes failed, its record released, intent kept, nothing restarted":
      for how in ["quit", "kill"]:
        let cfg = hostedConfig()
        var commands = @["rc establish_route " & hex(establishReq("k"))]
        if how == "quit":
          commands.add("subscribe " & ModuleStateEv)
          commands.add("quit-handler")
        let dir = cfg.prepare(commands)
        let e = fixtureEngine(cfg)
        let (_, rc) = e.startClient("c")
        discard e.started(meter(), "m")
        discard e.create(probe(), "p").tryGet
        let v = e.start("p").tryGet
        check v.state in {msReady, msError}
        check lines(dir, "rc").len == 1 and lines(dir, "rc")[0].startsWith("0 ")
        if how == "quit":
          # The probe's first handler call exits the host.
          discard e.started(slow(), "s")
        else:
          check e.killHost("p")
        check e.errorWith("p", "host-terminated")
        let realizes = e.realizations
        let after = e.view("p").tryGet
        check after.execution.intent == inRequested
        check e.absentAgain(rc, "p")
        check e.releases("p") == 1
        let mine = e.routes().filterIt(it.consumer.module_instance_id == "p")
        check mine.len == 1
        if mine.len == 1:
          check mine[0].state.kind == LogosNSRuntimeControlRouteStateKind.Failed
        check e.diagnostics().anyIt("Module Host of p ended unexpectedly" in it)
        check noHostLeft()
        sleep(200 * Slow)
        check e.realizations == realizes # no restart
        check e.view("p").tryGet.state == msError
        # A later start is a new realization in a new host.
        writeFile(dir / "probe.cmd", "\n")
        check e.start("p").tryGet.state == msReady
        check e.stop("p").tryGet.state == msUnloaded
        e.finish()

    test "[RUN-0812] [IMPL-DECISION G268] S-8 a carrier that breaks: the host is ended at once, `host-terminated` with the carrier's failure":
      let cfg = hostedConfig()
      let dir = cfg.prepare("subscribe " & ModuleStateEv)
      let e = fixtureEngine(cfg)
      let (_, rc) = e.startClient("c")
      discard e.create(probe(), "p").tryGet
      check e.start("p").tryGet.state == msReady
      discard settled(dir, "events", 2)
      let h = e.hostOf("p")
      check h != nil
      breakCarrier(h)
      dropHost(h)
      # The host's next frame (its acknowledgement of a delivery) breaks it.
      discard e.started(slow(), "s")
      check e.errorWith("p", "host-terminated")
      let v = e.view("p").tryGet
      check v.failure.get.reason ==
        "the carrier to the Module Host failed: a malformed frame"
      check e.diagnostics().anyIt(
        "the Module Host of p ended: the carrier to the Module Host failed" in it
      )
      check hostEnds()[^1].carrierLost.len > 0
      check e.absentAgain(rc, "p")
      e.finish()

  # S-9 to S-11 --------------------------------------------------------------------------

  suite "run.hosted: deadlines end the host (G61; G269)":
    teardown:
      holdEnds(false)
      leftover()
      check noHostLeft()

    test "[RUN-0227] [IMPL-DECISION G269] S-9 past the startup deadline: `error` with `startup-timeout`, `unknown` until the host's end is confirmed, then `absent`; the next start is accepted":
      var cfg = hostedConfig()
      # [IMPL] The first start waits this out; the second must finish within it
      # on a loaded host, which 300 ms did not always allow (refc, 2026-11-14).
      cfg.startupDeadline = initDuration(milliseconds = 1500 * Slow)
      let dir = cfg.prepare("block-init")
      let e = fixtureEngine(cfg)
      let (_, rc) = e.startClient("c")
      discard e.create(probe(), "p").tryGet
      # The host's end is held from before its spawn until the case has looked,
      # so the deadline cannot end it first.
      var started: Thread[(Engine, string)]
      var held: Host
      proc startOn(arg: (Engine, string)) {.thread.} =
        discard arg[0].start(arg[1])

      holdEnds(true)
      createThread(started, startOn, (e, "p"))
      check waitUntil(
        proc(): bool =
          let h = e.hostOf("p")
          if h != nil and pidOf(h) > 0:
            held = h
            return true
          if h != nil:
            dropHost(h)
          false
      )
      joinThread(started)
      let v = e.view("p").tryGet
      check v.state == msError and v.failureOf == "startup-timeout"
      check rc.realization(e, "p") == R.Unknown
      check e.start("p").error.code == ecNotReady
      holdEnds(false)
      holdEnd(held, false) # wakes its supervision
      dropHost(held)
      check e.absentAgain(rc, "p")
      check e.view("p").tryGet.failureOf == "startup-timeout"
      let ends = hostEnds()
      check ends[^1].byRuntime and ends[^1].terminated
      writeFile(dir / "probe.cmd", "\n")
      check e.start("p").tryGet.state == msReady
      e.finish()

    test "[IMPL-DECISION G269] [IMPL-DECISION G180] S-10 past the stop deadline with `_MODULE_destroy` blocked: `cleanup-timeout`, the host ended, the release succeeds, `absent`; a later stop gives `unloaded`":
      var cfg = hostedConfig()
      cfg.stopDeadline = PassingStop
      let dir = cfg.prepare("block-destroy")
      let e = fixtureEngine(cfg)
      let (_, rc) = e.startClient("c")
      discard e.create(probe(), "p").tryGet
      check e.start("p").tryGet.state == msReady
      let v = e.stop("p").tryGet
      check v.state == msError and v.failureOf == "cleanup-timeout"
      check e.absentAgain(rc, "p")
      check e.releases("p") == 1
      check lines(dir, "destroyed").len == 0 # ended inside destroy
      check hostEnds()[^1].byRuntime
      check e.view("p").tryGet.failureOf == "cleanup-timeout"
      check e.stop("p").tryGet.state == msUnloaded
      e.finish()

    test "[IMPL-DECISION G269] S-11 shutdown with a host whose `_MODULE_destroy` blocks completes after the grace period; the host is ended":
      var cfg = hostedConfig()
      cfg.shutdownGrace = PassingStop
      discard cfg.prepare("block-destroy")
      let e = fixtureEngine(cfg)
      discard e.create(probe(), "p").tryGet
      check e.start("p").tryGet.state == msReady
      let began = getMonoTime()
      e.requestShutdown()
      discard e.awaitShutdown()
      check getMonoTime() - began >= PassingStop
      check noHostLeft()
      check e.view("p").tryGet.failureOf == "cleanup-timeout"
      live = nil
      check e.close(initDuration(seconds = 10 * Slow))

  # S-12, S-13 ---------------------------------------------------------------------------

  var applyCode: Atomic[int] ## the code of `applyOn`'s call; -2 while it runs

  proc applyOn(
      arg: (ptr LogosRuntimeControlBinding, LogosNSRuntimeModuleInstanceAddress, uint64)
  ) {.thread.} =
    var t = arg[1]
    applyCode.store(ord(arg[0].applyOf(t, arg[2]).code))

  proc liveProbe(a: AcceptedConfiguration): ModuleRecord =
    result = probe()
    result.configuration = Opt.some(a.digest)

  proc staged(rc: ptr LogosRuntimeControlBinding, e: Engine, station: string): uint64 =
    ## A value whose station tells the probe's hook what to do, staged.
    let t = e.target("p")
    rc.stage(t, rc.summary(t).state_revision, tunerValue(station)).updated.state_revision

  proc applyingIn(
      rc: ptr LogosRuntimeControlBinding,
      e: Engine,
      station: string,
      th:
        var Thread[
          (ptr LogosRuntimeControlBinding, LogosNSRuntimeModuleInstanceAddress, uint64)
        ],
  ) =
    let revision = rc.staged(e, station)
    applyCode.store(-2)
    createThread(th, applyOn, (rc, e.target("p"), revision))

  proc liveStart(cfg: EngineConfig): (Engine, ptr LogosRuntimeControlBinding) =
    let a = tunerAccepted(default = Opt.some(tunerValue()), live = true)
    let e = fixtureEngine(cfg)
    let (_, rc) = e.startClient("c")
    discard e.create(liveProbe(a), "p", configuration = Opt.some(a)).tryGet
    check e.start("p").tryGet.state == msReady
    (e, rc)

  suite "run.hosted: live configuration in a host (LOADER §8; CONFIG §8; G269, G270)":
    teardown:
      leftover()
      check noHostLeft()

    test "[LDR-0111] [LDR-0112] S-12 a live application runs the hook in the host: applied, or rejected with nothing changed":
      let cfg = hostedConfig()
      let dir = cfg.prepare()
      let (e, rc) = liveStart(cfg)
      let t = e.target("p")
      let ok = rc.applyOf(t, rc.staged(e, "radio-9"))
      check ok.code == ecOk
      check lines(dir, "applied").len == 1
      let rejected = rc.applyOf(t, rc.staged(e, "reject"))
      check rejected.code == ecModule
      check lines(dir, "applied").len == 2
      check e.view("p").tryGet.state == msReady
      check e.stop("p").tryGet.state == msUnloaded
      e.finish()

    test "[IMPL-DECISION G269] S-12 past the apply deadline: MODULE_ERROR and `configuration-indeterminate`; a hook that still does not return ends its host a stop deadline later":
      var cfg = hostedConfig()
      cfg.applyDeadline = PassingStop
      cfg.stopDeadline = PassingStop
      let dir = cfg.prepare()
      let (e, rc) = liveStart(cfg)
      var th: Thread[
        (ptr LogosRuntimeControlBinding, LogosNSRuntimeModuleInstanceAddress, uint64)
      ]
      rc.applyingIn(e, "block", th)
      joinThread(th)
      check applyCode.load == ord(ecModule)
      check e.errorWith("p", "configuration-indeterminate")
      check e.absentAgain(rc, "p")
      check hostEnds()[^1].byRuntime
      check e.view("p").tryGet.failureOf == "configuration-indeterminate"
      check lines(dir, "destroyed").len == 0
      e.finish()

    test "[IMPL-DECISION G270] S-13 a live application whose host ends (killed, its carrier broken, its module exiting in the hook): MODULE_ERROR to the caller, `error` with `host-terminated`":
      for how in ["kill", "carrier", "quit"]:
        let cfg = hostedConfig()
        let dir = cfg.prepare()
        let (e, rc) = liveStart(cfg)
        var th: Thread[
          (ptr LogosRuntimeControlBinding, LogosNSRuntimeModuleInstanceAddress, uint64)
        ]
        rc.applyingIn(e, (if how == "quit": "quit" else: "block"), th)
        check waitUntil(
          proc(): bool =
            lines(dir, "applied").len == 1
        )
        case how
        of "kill":
          check e.killHost("p")
        of "carrier":
          let h = e.hostOf("p")
          breakCarrier(h)
          dropHost(h)
          writeFile(dir / "go-apply", "") # the host's `applied` breaks it
        else:
          discard
        joinThread(th)
        check applyCode.load == ord(ecModule)
        check e.errorWith("p", "host-terminated")
        check e.absentAgain(rc, "p")
        e.finish()

  # S-14, S-15 ---------------------------------------------------------------------------

  suite "run.hosted: the Module Loader's loss with live hosts (RUNTIME l.3813-3825)":
    teardown:
      if live != nil:
        live.clearLoaderFaultsForTests()
      leftover()
      check noHostLeft()

    test "[RUN-1067] [RUN-1069] [RUN-1070] S-14 the Loader fails with two live hosts: both instances `error`, both hosts ended, intent kept, nothing realized; once both ends are confirmed nothing is left to clean":
      let cfg = hostedConfig()
      discard cfg.prepareAt("p1")
      discard cfg.prepareAt("p2")
      let e = fixtureEngine(cfg)
      for id in ["p1", "p2"]:
        discard e.create(probe(state = id), id).tryGet
        check e.start(id).tryGet.state == msReady
      check hostsLeft().len == 2
      let realizes = e.realizations
      check e.setLoaderFaultsForTests(LoaderFaults(reportFailure: true)).isOk
      for id in ["p1", "p2"]:
        let v = e.view(id).tryGet
        check v.state == msError and v.failureOf == "other"
        check v.execution.intent == inRequested
      check noHostLeft()
      check waitUntil(
        proc(): bool =
          not e.cleanupPending("p1") and not e.cleanupPending("p2")
      )
      for id in ["p1", "p2"]:
        check e.start(id).error.code == ecNotReady
        check e.view(id).tryGet.state == msError
      check e.realizations == realizes
      check e.releases("p1") == 0 and e.releases("p2") == 0
      check not e.diagnostics().anyIt("termination required" in it)
      e.requestShutdown()
      check e.awaitShutdown().isOk
      live = nil
      check e.close(initDuration(seconds = 10 * Slow))

    test "[RUN-1068] [RUN-1070] S-15 the Loader fails while a host's end is not yet confirmed: cleanup stays unresolved and nothing starts until it is":
      let cfg = hostedConfig()
      discard cfg.prepare()
      let e = fixtureEngine(cfg)
      discard e.startClient("c")
      discard e.create(probe(), "p").tryGet
      check e.start("p").tryGet.state == msReady
      let h = e.hostOf("p")
      holdEnd(h, true)
      check e.setLoaderFaultsForTests(LoaderFaults(reportFailure: true)).isOk
      check e.view("p").tryGet.state == msError
      sleep(200 * Slow)
      # The client is lost with the Loader: the Runtime is asked directly.
      check e.realizationForTests("p") == "rsUnknown"
      check e.cleanupPending("p")
      check e.start("p").error.code == ecNotReady
      holdEnd(h, false)
      dropHost(h)
      check waitUntil(
        proc(): bool =
          not e.cleanupPending("p")
      )
      check e.start("p").error.code == ecNotReady # until a host restart (K4)
      e.confirmTerminationForTests() # the client, realized directly
      e.finish()

  # S-16 ---------------------------------------------------------------------------------

  proc crash(dir: string, ids: openArray[string]) =
    ## The store as an unclean end leaves it: `ids` still `ready` (G193).
    var (s, snap) = openStore(dir).tryGet
    var x = snap.get
    for i in 0 ..< x.instances.len:
      if x.instances[i].instance in ids:
        x.instances[i].state = msReady
        x.instances[i].failure = Opt.none(Failure)
    s.write(x).tryGet
    s.close()

  suite "run.hosted: after an unclean end (G193; G275)":
    teardown:
      leftover()
      check noHostLeft()

    test "[RUN-0814] [IMPL-DECISION G275] [IMPL-DECISION G193] S-16 a hosted instance restored with its restart lock held is `unknown` and not started until the lock is free; with the lock free G193 holds":
      var cfg = hostedConfig()
      cfg.storeDir = Opt.some(cfg.workDir / "store")
      discard cfg.prepare()
      block:
        let e = openEngine(cfg).tryGet
        live = e
        discard e.create(probe(), "p").tryGet
        check e.start("p").tryGet.state == msReady
        e.finish()
      for held in [true, false]:
        crash(cfg.storeDir.get, ["p"])
        var fd = cint(-1)
        if held:
          # A stand-in for a host of the previous run: an open file holding it.
          let (taken, lock) = takeHostLock(cfg.workDir, "p")
          check taken == loTaken
          fd = lock
        let e = openEngine(cfg).tryGet
        live = e
        let (_, rc) = e.startClient("c" & $held)
        let v = e.view("p").tryGet
        check v.state == msError and v.failureOf == "other"
        if held:
          check rc.realization(e, "p") == R.Unknown
          let r = e.start("p")
          check r.isErr and r.error.code == ecNotReady
          if r.isErr:
            check r.error.message ==
              "a Module Host of the previous run may still be running"
          check e.cleanupPending("p")
          closeLock(fd)
          check waitUntil(
            proc(): bool =
              rc.realization(e, "p") == R.Absent
          )
        else:
          check rc.realization(e, "p") == R.Absent
        check e.start("p").tryGet.state == msReady
        e.finish()
else:
  import unittest2

  suite "run.hosted: hosted realization (POSIX only)":
    test "[IMPL] hosted placement is not supported on this platform":
      skip()
