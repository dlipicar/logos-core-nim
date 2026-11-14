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
## `test_loader`; S-4's frame after the attempt ended and S-7 to S-16 and S-18
## come with 4b-3.1b. After every case no host of this build is left.

when defined(posix):
  import std/[atomics, monotimes, os, sequtils, strutils, times, typedthreads]
  import unittest2
  import ../src/logos_core/runtime/engine
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
  import ./support/[fakeca, kitbuild, kitruntime, modulehostbuild, withoutloader]
  import ./kit/meter_impl
  import ./generated/meter_module_calls

  let
    repo = currentSourcePath().parentDir.parentDir
    work = repo / "build" / "hosted" / kitVariant
  removeDir(work)
  createDir(work)

  include ./support/routefixture

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

  proc probe(hosted = true, placement = "process", digest = probeDigest): ModuleRecord =
    ## The probe library, `hosted_dynamic` or `direct_dynamic`, with state `p`.
    ModuleRecord(
      module: "probe_module",
      strategy: (if hosted: stHostedDynamic else: stDirectDynamic),
      placement: (if hosted: placement else: ""),
      artifact: ArtifactRecord(
        id: "probe", localPath: probeLib, hash: digest, hashSuite: HashSuiteId
      ),
      stateAssignment: Opt.some("p"),
    )

  proc hostedConfig(host = true, extra: seq[StaticRegistration] = @[]): EngineConfig =
    ## The fixture's configuration with a state root, the fixed Runtime
    ## instance id, and with `host` the Module Host program.
    result = config(extra = extra)
    result.runtimeInstanceId = RuntimeId
    result.stateRoot = Opt.some(result.workDir / "state")
    if host:
      result.moduleHost = Opt.some(hostProgram)
      result.moduleHostEnv = @SanitizerEnv

  proc prepare(cfg: EngineConfig, commands: varargs[string]): string =
    ## The probe's state directory, holding `commands` before its start.
    result = cfg.stateRoot.get / "p"
    createDir(result)
    writeFile(result / "probe.cmd", commands.join("\n") & "\n")

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
else:
  import unittest2

  suite "run.hosted: hosted realization (POSIX only)":
    test "[IMPL] hosted placement is not supported on this platform":
      skip()
