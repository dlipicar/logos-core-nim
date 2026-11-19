## Permissions for hosted instances (Tier 4b step 4b-4, part 4b-4c; DECISIONS
## I93, G272, G275, G284, G285; plan §R.c): the probe module
## (`tests/kit/probe_impl.nim`) realized `hosted_dynamic` in a `process`
## placement by real `logos-module-host` processes, under the test permission
## profile (`support/permfixture`) with every module provisioned with
## host-ambient unless a case says otherwise.
##
## `test_permissions` holds the direct cases. Its modules are the route
## fixture's `direct_static` bindings, which a host cannot realize, so the
## hosted variants are here: admission and the refusal classification (S-20,
## S-21), the snapshot through the carrier (S-22), reconciliation by stop and
## re-realize (S-23), the settlement of a stop the host's forced end completes
## and of one nothing ends (S-24, S-25), restoration with the restart lock held
## (S-26), and revocation (S-27). After every case no host of this build is
## left.

when defined(posix):
  import std/[algorithm, atomics, monotimes, os, sequtils, strutils, times]
  import unittest2
  import ../src/logos_core/runtime/engine
  import ../src/logos_core/runtime/[hostlock, hostsup, settings, store]
  import logos_sdk/abi/types
  import logos_sdk/cbor
  import logos_sdk/commitment
  import logos_sdk/crypto/blake3
  import logos_sdk/iface/[accept, outcome, surface]
  import logos_sdk/codegen/common_types
  import ../src/logos_core/authority/scopes except
    LogosNSRuntimeModuleInstanceAddress, LogosNSRuntimeModuleInstanceId,
    LogosNSRuntimeModuleName, LogosNSRuntimeModuleProviderAddress,
    LogosNSRuntimeModuleProviderId, LogosNSRuntimeModuleStateAssignmentId,
    LogosNSRuntimeRouteId, LogosNSRuntimeRuntimeInstanceId
  import ../src/logos_core/loader/contract
  from ../src/logos_core/runtime/authscopes import checkDecision, evaluateRequest
  import logos_sdk/pins
  import
    ./support/[fakeca, modulehostbuild, permfixture, shortdir],
    logos_sdk/testing/[kitbuild, kitruntime]
  import logos_sdk/testing/fixtures/meter_impl
  import logos_sdk/testing/generated/meter_module_calls

  let
    repo = currentSourcePath().parentDir.parentDir
    work = repo / "build" / "hosted_permissions" / kitVariant
  removeDir(work)
  createDir(work)

  include ./support/routefixture

  let shortBase = makeShortBase("lcnhp", "/e999/12345678/logos_meter_module.sock")

  const
    RuntimeId = "5d0c9a7e-3b2f-4e61-8c4d-2a9f1e7b6c30"
    SanitizerEnv =
      ["ASAN_OPTIONS", "LSAN_OPTIONS", "MSAN_OPTIONS", "TSAN_OPTIONS", "UBSAN_OPTIONS"]
    SettingsEvent = "logos.runtime_control.permission_settings_changed_event"
    Snapshot = "rc get_execution_permissions a0"
      ## the probe asks for its snapshot from `_MODULE_init`

  let
    hostProgram = moduleHostProgram()
    probeLib = buildKitLibrary("probe_impl.nim", "probe")

  proc digestOf(path: string): array[32, byte] =
    var h: Blake3Hasher
    h.init()
    let bytes = readFile(path)
    h.update(bytes.toOpenArrayByte(0, bytes.high))
    h.finish()

  let probeDigest = digestOf(probeLib)

  # Set-up -------------------------------------------------------------------------------

  proc probe(hosted = true): ModuleRecord =
    ModuleRecord(
      module: "probe_module",
      strategy: (if hosted: stHostedDynamic else: stDirectDynamic),
      placement: (if hosted: "process" else: ""),
      artifact: ArtifactRecord(
        id: "probe", localPath: probeLib, hash: probeDigest, hashSuite: HashSuiteId
      ),
      stateAssignment: Opt.some("p"),
    )

  proc hconfig(
      probeSettings = @[ambient()], profile = true, extra: seq[StaticRegistration] = @[]
  ): EngineConfig =
    ## The fixture's configuration with the Module Host program, a state root,
    ## and the test profile selected: the probe provisioned with
    ## `probeSettings`, every other module with host-ambient.
    result = config(extra = extra)
    result.runtimeInstanceId = RuntimeId
    result.stateRoot = Opt.some(result.workDir / "state")
    result.endpointDir = shortBase / ("e" & $engines)
    result.moduleHost = Opt.some(hostProgram)
    result.moduleHostEnv = @SanitizerEnv
    if profile:
      result.permissions = testProfile
      for m in ["client_module", CaModuleName]:
        result.initialSettings.add(
          InitialSettings(module: m, permissions: @[ambient()])
        )
      result.initialSettings.add(
        InitialSettings(module: "probe_module", permissions: probeSettings)
      )

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

  func unhex(s: string): seq[byte] =
    var i = 0
    while i + 1 < s.len:
      result.add(byte(fromHex[uint8](s[i .. i + 1])))
      i += 2

  proc noHostLeft(): bool =
    waitUntil(
      proc(): bool =
        hostPids(hostProgram).len == 0
    )

  proc hostAlive(): bool =
    hostPids(hostProgram).len > 0

  proc failureOf(v: InstanceView): string =
    if v.failure.isSome: v.failure.get.classification else: ""

  proc target(e: Engine, id: string): LogosNSRuntimeModuleInstanceAddress =
    LogosNSRuntimeModuleInstanceAddress(
      runtime_instance_id: e.runtimeInstanceId, module_instance_id: id
    )

  type SettingsView = LogosNSRuntimeControlPermissionSettingsState

  func status(s: SettingsView): string =
    ($s.application.kind).toLowerAscii

  proc settingsOf(
      rc: ptr LogosRuntimeControlBinding, e: Engine, id: string
  ): SettingsView =
    let r = rcCall(
      rc,
      "get_permission_settings",
      encode(LogosNSRuntimeControlGetPermissionSettingsRequest(target: e.target(id))).tryGet,
    )
    check r.code == ecOk
    if r.code == ecOk:
      result = LogosNSRuntimeControlGetPermissionSettingsResponse.decode(r.response).tryGet.state

  proc replace(
      rc: ptr LogosRuntimeControlBinding,
      e: Engine,
      id: string,
      revision: uint64,
      xs: seq[PermissionSetting],
  ): SettingsView =
    let r = rcCall(
      rc,
      "update_permission_settings",
      encode(
        LogosNSRuntimeControlUpdatePermissionSettingsRequest(
          target: e.target(id), expected_revision: revision, permissions: xs.toRc
        )
      ).tryGet,
    )
    check r.code == ecOk
    if r.code == ecOk:
      result = r.accepted(LogosNSRuntimeControlUpdatePermissionSettingsResponse).state

  proc statusIs(rc: ptr LogosRuntimeControlBinding, e: Engine, id, s: string): bool =
    waitUntil(
      proc(): bool =
        rc.settingsOf(e, id).status == s
    )

  proc stateIs(e: Engine, id: string, s: ModuleState): bool =
    waitUntil(
      proc(): bool =
        e.view(id).tryGet.state == s
    )

  proc snapshots(dir: string): seq[Opt[seq[PermissionSetting]]] =
    ## What each `_MODULE_init` of the probe got from
    ## `get_execution_permissions`: the snapshot, or none for `unavailable`.
    ## A failed answer is one `_MODULE_destroy` got (`rc-destroy` has it).
    for l in lines(dir, "rc"):
      let w = l.split(' ')
      if w[0] != "0" or w.len < 2:
        continue
      let a =
        LogosNSRuntimeControlGetExecutionPermissionsResponse.decode(unhex(w[1])).tryGet
      case a.kind
      of LogosNSRuntimeControlGetExecutionPermissionsResponseKind.Available:
        result.add(Opt.some(fromRc(a.arm_Available.permissions)))
      of LogosNSRuntimeControlGetExecutionPermissionsResponseKind.Unavailable:
        result.add(Opt.none(seq[PermissionSetting]))

  proc realizes(e: Engine, id: string): int =
    e.loaderJournalForTests().countIt(it.meth == $lmRealize and it.instance == id)

  proc executeAnswers(e: Engine, id: string): int =
    e.answers().countIt(it.request.action == aaExecute and it.request.instance == id)

  # The event ------------------------------------------------------------------------------

  const
    EventCap = 32
    EventBytes = 512

  type Seen = object
    count: Atomic[int]
    lens: array[EventCap, int]
    data: array[EventCap, array[EventBytes, byte]]

  var seen: Seen

  proc onSettings(
      name: cstring, data: ptr UncheckedArray[uint8], len: csize_t, userData: pointer
  ) {.cdecl, gcsafe, raises: [].} =
    let s = cast[ptr Seen](userData)
    let i = s.count.load
    if i < EventCap:
      let n = min(int(len), EventBytes)
      for j in 0 ..< n:
        s.data[i][j] = data[j]
      s.lens[i] = n
    s.count += 1

  proc events(): seq[(string, uint64, string)] =
    for i in 0 ..< min(seen.count.load, EventCap):
      var b = newSeq[byte](seen.lens[i])
      for j in 0 ..< b.len:
        b[j] = seen.data[i][j]
      let ev = LogosNSRuntimeControlPermissionSettingsChangedEvent.decode(b).tryGet
      result.add((ev.target.module_instance_id, ev.state.revision, ev.state.status))

  # S-20, S-21: admission ------------------------------------------------------------------

  proc authorityEngine(
      cfg: var EngineConfig
  ): (Engine, ptr LogosRuntimeControlBinding) =
    ## An engine whose orchestration instance `orch` started the fake authority
    ## `ca`: a start `orch` asks for is decided by it.
    resetFake()
    cfg.authority = Opt.some(
      AuthorityPolicy(instance: "ca", evaluationDeadline: initDuration(seconds = 60))
    )
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
    (e, orch)

  suite "run.hosted.permissions: admission (CA l.349-353, l.364; RUNTIME l.2538)":
    teardown:
      setScript()
      leftover()
      check noHostLeft()

    test "[CAP-0065] [CAP-0066] [CAP-0063] [IMPL-DECISION G217] [IMPL-DECISION G272] S-20 a hosted start's execution decision covers the execution scope in `local-transport` with `process` and one permission scope per saved setting, as a set; a deny realizes nothing":
      let wide = @[setting(Quota, quota(7)), ambient()]
      var cfg = hconfig(probeSettings = wide, extra = @[fakeCaRegistration()])
      let dir = cfg.prepare()
      let (e, orch) = authorityEngine(cfg)
      discard e.create(probe(), "p").tryGet
      forget()
      check orch.lifecycle("start_module", "probe_module", Opt.some("p")).code == ecOk
      let ex = received().filterIt(it.what == "execute")
      check ex.len == 1
      if ex.len == 1:
        let req = LogosNSCapabilityAuthorityEvaluateRequest.decode(ex[0].request).tryGet
        check req.scopes.len == 3
        check isSet(req.scopes)
        let execs = req.scopes.filterIt(it.kind == skExecution)
        check execs.len == 1
        if execs.len == 1:
          let me = execs[0].me
          check me.instance == Opt.some("p")
          check me.actions.mapIt(it.kind) == @[MeActionKind.Start]
          check me.modes.get(@[]).mapIt(it.kind) == @[ExecModeKind.Local_transport]
          check me.placements.get(@[]).mapIt(it.kind) == @[PlacementKind.Process]
        let perms = req.scopes.filterIt(it.kind == skPermission)
        check perms.mapIt(it.pm.permission).sorted == @[Quota, HostAmbient].sorted
      check lines(dir, "inits") == @["init"]
      check orch.stoppedVia("probe_module", Opt.some("p")).code == ecOk
      check noHostLeft()
      let before = e.realizes("p")
      setScript(
        rule(
          vDeny,
          "execute",
          code = ord(LogosNSCapabilityAuthorityDenialCodeKind.Scope_denied),
        )
      )
      check orch.lifecycle("start_module", "probe_module", Opt.some("p")).code ==
        ecNotAuthorised
      check e.view("p").tryGet.failureOf == "authority-denied"
      check e.realizes("p") == before
      check lines(dir, "inits") == @["init"]
      check not hostAlive()
      e.finish()

    test "[CAP-0065] [RUN-0469] [CAP-0068] [IMPL-DECISION G284] [IMPL-DECISION G281] S-21 settings that lack host-ambient, or that failed, refuse a hosted start before any decision: NOT_AUTHORISED, intent kept, no host started":
      let cfg = hconfig(probeSettings = @[])
      let dir = cfg.prepare()
      let e = fixtureEngine(cfg)
      let (_, rc) = e.startClient("c")
      discard e.create(probe(), "p").tryGet
      let answers = e.executeAnswers("p")
      let r = e.start("p")
      check r.isErr and r.error.code == ecNotAuthorised
      var v = e.view("p").tryGet
      check v.state == msUnloaded and v.failureOf == "authority-denied"
      check v.execution.intent == inRequested
      check e.executeAnswers("p") == answers
      check e.realizes("p") == 0
      check lines(dir, "inits").len == 0
      check not hostAlive()
      # [G281] No realization: a definition no active point enforces fails at
      # once, and the start is refused for that.
      let s = rc.replace(e, "p", 1, @[unenforced(), ambient()])
      check s.revision == 2 and s.status == "failed"
      let r2 = e.start("p")
      check r2.isErr and r2.error.code == ecNotAuthorised
      v = e.view("p").tryGet
      check v.state == msUnloaded and v.failureOf == "permission-enforcement-failed"
      check v.execution.intent == inRequested
      check e.executeAnswers("p") == answers
      check e.realizes("p") == 0
      check not hostAlive()
      # An accepted retry applies; the start then realizes a host.
      check rc.replace(e, "p", 2, @[ambient()]).status == "applied"
      check e.start("p").tryGet.state == msReady
      check lines(dir, "inits") == @["init"]
      e.finish()

  suite "run.hosted.permissions: what a hosted execution can enforce (CA l.413; G272)":
    test "[IMPL-DECISION G272] [CAP-0068] [CAP-0066] [BCP-0081] an allow for `local-transport` in a `process` with the permission scopes is accepted; one placing the execution in a sandbox or a container is an evaluation failure":
      let q = AuthzRequest(
        action: aaExecute,
        operation: "execute",
        consumer: "orch",
        target: "p",
        instance: "p",
        module: "probe_module",
        hosted: true,
        permissions: @[setting(Quota, quota(2)), ambient()],
      )
      let req = evaluateRequest(q, RuntimeId).tryGet
      proc decide(allowed: seq[Scope]): Decision =
        Decision(
          consumer: req.consumer,
          decision_id: "d-1",
          issued_at: 1,
          valid_until: Opt.some(LogosNSCapabilityAuthorityTimestamp(2)),
          policy_revision: 1,
          requested_scopes: req.scopes,
          allowed_scopes: Opt.some(allowed),
          result: LogosNSCapabilityAuthorityDecisionResult(
            kind: LogosNSCapabilityAuthorityDecisionResultKind.Allow
          ),
        )

      check checkDecision(req, decide(req.scopes), RuntimeId, testProfile()).isOk
      for k in [PlacementKind.Sandbox, PlacementKind.Container]:
        var allowed = req.scopes
        for i in 0 ..< allowed.len:
          if allowed[i].kind == skExecution:
            allowed[i].me.placements = Opt.some(@[Placement(kind: k)])
        let r = checkDecision(req, decide(allowed), RuntimeId, testProfile())
        check r.isErr
        if r.isErr:
          check r.error in [
            "an allowed scope is not covered by a requested scope",
            "an allowed scope has no enforcement point here",
          ]

  # S-22: the snapshot through the carrier ---------------------------------------------

  suite "run.hosted.permissions: get_execution_permissions in a host (RUNTIME l.2562-2575)":
    teardown:
      leftover()
      check noHostLeft()

    test "[RUN-0906] [RUN-0907] [RUN-0905] [RUN-0908] [RUN-0904] S-22 a host's `get_execution_permissions` answers what admission installed from `_MODULE_init` on, `unavailable` with no profile, and NOT_READY once the realization is no longer current, as in process":
      let wide = @[setting(Quota, quota(3)), ambient()]
      proc run(hosted, profile: bool): (seq[Opt[seq[PermissionSetting]]], seq[string]) =
        let cfg = hconfig(probeSettings = wide, profile = profile)
        let dir = cfg.prepare(Snapshot, "rc-destroy get_execution_permissions a0")
        let e = fixtureEngine(cfg)
        discard e.create(probe(hosted), "p").tryGet
        check e.start("p").tryGet.state == msReady
        check e.stop("p").tryGet.state == msUnloaded
        result = (snapshots(dir), lines(dir, "rc-destroy"))
        e.finish()

      let (hosted, gone) = run(true, true)
      check hosted == @[Opt.some(wide)]
      check gone.len == 1
      if gone.len == 1:
        check gone[0].split(' ')[0] == $ord(ecNotReady)
      check run(false, true) == (hosted, gone)
      let (none, _) = run(true, false)
      check none == @[Opt.none(seq[PermissionSetting])]

  # S-23 to S-25: reconciliation and settlement ------------------------------------------

  proc unhooked() =
    ## A teardown after injected faults: held calls reply and the protected
    ## mechanism confirms what nothing else can clean.
    if live != nil:
      live.clearLoaderFaultsForTests()
      live.confirmTerminationForTests()

  suite "run.hosted.permissions: reconciliation and settlement (RUNTIME l.2590-2601; G285)":
    teardown:
      unhooked()
      leftover()
      check noHostLeft()

    test "[RUN-0914] [RUN-1066] [RUN-0912] [RUN-0916] [RUN-0909] S-23 narrowing a ready hosted instance: pending while its host is released, then unloaded with no failure and intent and origin kept, then applied; its recovery is admitted with the narrowed settings":
      let cfg = hconfig(probeSettings = @[setting(Quota, quota(9)), ambient()])
      let dir = cfg.prepare(Snapshot)
      let e = fixtureEngine(cfg)
      let (_, rc) = e.startClient("c")
      discard e.create(probe(), "p").tryGet
      check e.start("p").tryGet.state == msReady
      check hostAlive()
      let s = rc.replace(e, "p", 1, @[ambient()])
      check s.revision == 2 and s.status == "pending"
      check e.stateIs("p", msUnloaded)
      check rc.statusIs(e, "p", "applied")
      check noHostLeft()
      check lines(dir, "destroyed") == @["destroyed"]
      let v = e.view("p").tryGet
      check v.failure.isNone
      check v.execution.intent == inRequested
      check v.intentOrigin.host
      # [RUN-0915] Nothing restarts it; a recovery does, under the narrowed
      # settings, and the new realization sees its own snapshot.
      check e.realizes("p") == 1
      check e.recover("p", v.execution.revision).tryGet.state == msReady
      check snapshots(dir) ==
        @[Opt.some(@[setting(Quota, quota(9)), ambient()]), Opt.some(@[ambient()])]
      e.finish()

    test "[IMPL-DECISION G285] [IMPL-DECISION G269] [RUN-0916] [RUN-0912] S-24 a hosted reconciliation stop past its deadline: `cleanup-timeout`, the settings pending until the forced end of the host is confirmed, a replacement meanwhile pending too, then applied, the instance staying `error`":
      var cfg = hconfig()
      cfg.stopDeadline = PassingStop
      let dir = cfg.prepare("block-destroy")
      let e = fixtureEngine(cfg)
      let (_, rc) = e.startClient("c")
      seen.count.store(0)
      var id: LogosSubscriptionId
      check toResult(
        rc.vtable.subscribe(rc, SettingsEvent, onSettings, addr seen, addr id)
      ).code == ecOk
      discard e.create(probe(), "p").tryGet
      check e.start("p").tryGet.state == msReady
      let h = e.moduleHostForTests("p")
      check h != nil
      holdEnd(h, true) # its end, once forced, is confirmed only when released
      check rc.replace(e, "p", 1, @[]).status == "pending"
      check waitUntil(
        proc(): bool =
          let v = e.view("p").tryGet
          v.state == msError and v.failureOf == "cleanup-timeout"
      )
      # The host was ended by force; until that end is confirmed the
      # realization remains and nothing is enforced yet.
      sleep(100 * Slow)
      check rc.settingsOf(e, "p").status == "pending"
      check e.cleanupPending("p")
      let again = rc.replace(e, "p", 2, @[ambient()])
      check again.revision == 3 and again.status == "pending"
      check events().filterIt(it[0] == "p" and it[2] == "failed").len == 0
      holdEnd(h, false)
      dropHost(h)
      check rc.statusIs(e, "p", "applied")
      check noHostLeft()
      check not e.cleanupPending("p")
      let v = e.view("p").tryGet
      check v.state == msError and v.failureOf == "cleanup-timeout"
      check v.execution.intent == inRequested
      check lines(dir, "destroyed").len == 0 # ended inside destroy
      check hostEnds()[^1].byRuntime
      check waitUntil(
        proc(): bool =
          events().filterIt(it[0] == "p") ==
            @[("p", 2'u64, "pending"), ("p", 3'u64, "pending"), ("p", 3'u64, "applied")]
      )
      discard toResult(rc.vtable.unsubscribe(rc, id))
      e.finish()

    test "[IMPL-DECISION G285] [RUN-0479] [RUN-0480] S-25 a hosted reconciliation stop whose release fails while its host lives (`cleanup-failed`): nothing ends the host, so the settings fail, the instance stays stopped":
      let cfg = hconfig()
      discard cfg.prepare()
      let e = fixtureEngine(cfg)
      let (_, rc) = e.startClient("c")
      discard e.create(probe(), "p").tryGet
      check e.start("p").tryGet.state == msReady
      check e.setLoaderFaultsForTests(LoaderFaults(failInvocation: {lmRelease})).isOk
      discard rc.replace(e, "p", 1, @[])
      check waitUntil(
        proc(): bool =
          e.view("p").tryGet.failureOf == "cleanup-failed"
      )
      check rc.statusIs(e, "p", "failed")
      check hostAlive()
      check e.start("p").error.code == ecNotReady
      # The protected mechanism ends the host later: the settings stay failed
      # and nothing is restored (RUNTIME l.2592).
      e.clearLoaderFaultsForTests()
      e.confirmTerminationForTests()
      check noHostLeft()
      let s = rc.settingsOf(e, "p")
      check s.revision == 2 and s.status == "failed"
      check e.view("p").tryGet.state == msError
      e.finish()

  # S-26: restoration with the restart lock held -------------------------------------------

  proc crash(dir: string, settings: SettingsState) =
    ## The store as an unclean end leaves it: `p` still `ready` (G193), with
    ## `settings` saved for it.
    var (s, snap) = openStore(dir).tryGet
    var x = snap.get
    for i in 0 ..< x.instances.len:
      if x.instances[i].instance == "p":
        x.instances[i].state = msReady
        x.instances[i].failure = Opt.none(Failure)
    s.write(x).tryGet
    s.putSide(PrmSide, "p", prmBytes(settings).tryGet).tryGet
    s.close()

  suite "run.hosted.permissions: after an unclean end (G275; RUNTIME l.2590, l.2600)":
    teardown:
      leftover()
      check noHostLeft()

    test "[IMPL-DECISION G275] [RUN-0478] [RUN-0895] [RUN-0916] [RUN-0482] S-26 settings pending at an unclean end stay pending while the hosted instance's restart lock is held, and settle once it is free, with the event; with the lock free they settle at the open":
      var cfg = hconfig()
      cfg.storeDir = Opt.some(cfg.workDir / "store")
      discard cfg.prepare()
      block:
        let e = openEngine(cfg).tryGet
        live = e
        discard e.create(probe(), "p").tryGet
        check e.start("p").tryGet.state == msReady
        e.finish()
      let pending =
        SettingsState(revision: 2, permissions: @[ambient()], application: saPending)
      for held in [true, false]:
        crash(cfg.storeDir.get, pending)
        var fd = cint(-1)
        if held:
          # A stand-in for a host of the previous run: an open file holding it.
          let (taken, lock) = takeHostLock(cfg.workDir, "p")
          check taken == loTaken
          fd = lock
        let e = openEngine(cfg).tryGet
        live = e
        let (_, rc) = e.startClient("c" & $held)
        seen.count.store(0)
        var id: LogosSubscriptionId
        check toResult(
          rc.vtable.subscribe(rc, SettingsEvent, onSettings, addr seen, addr id)
        ).code == ecOk
        let v = e.view("p").tryGet
        check v.state == msError and v.failureOf == "other"
        if held:
          let s = rc.settingsOf(e, "p")
          check s.revision == 2 and s.status == "pending"
          check e.start("p").error.code == ecNotReady
          sleep(100 * Slow)
          check rc.settingsOf(e, "p").status == "pending"
          check events().len == 0
          closeLock(fd)
          check rc.statusIs(e, "p", "applied")
          check rc.settingsOf(e, "p").revision == 2
          check waitUntil(
            proc(): bool =
              events() == @[("p", 2'u64, "applied")]
          )
        else:
          let s = rc.settingsOf(e, "p")
          check s.revision == 2 and s.status == "applied"
          check events().len == 0 # nothing is published at the open
        check e.start("p").tryGet.state == msReady
        discard toResult(rc.vtable.unsubscribe(rc, id))
        e.finish()

  # S-27: revocation --------------------------------------------------------------------------

  suite "run.hosted.permissions: revocation (CA l.915-916)":
    teardown:
      setScript()
      leftover()
      check noHostLeft()

    test "[CAP-0192] [RUN-1066] S-27 revoking the grant that covered host-ambient ends the hosted execution: its host is released, `authority-revoked`, intent and origin kept, the settings untouched":
      var cfg = hconfig(extra = @[fakeCaRegistration()])
      discard cfg.prepare()
      let (e, orch) = authorityEngine(cfg)
      discard e.create(probe(), "p").tryGet
      setScript(allow("execute", grants = @["gh"]))
      check orch.lifecycle("start_module", "probe_module", Opt.some("p")).code == ecOk
      check hostAlive()
      setScript()
      check publish(
        GrantChangedName,
        grantChanged("gh", GrantStatusKind.Revoked, "orch", e.runtimeInstanceId),
      )
      check e.stateIs("p", msUnloaded)
      check noHostLeft()
      let v = e.view("p").tryGet
      check v.failureOf == "authority-revoked"
      check v.execution.intent == inRequested
      check v.intentOrigin.instance == "orch"
      let s = orch.settingsOf(e, "p")
      check s.revision == 1 and s.status == "applied"
      e.finish()
else:
  import unittest2

  suite "run.hosted.permissions: hosted realization (POSIX only)":
    test "[IMPL] hosted placement is not supported on this platform":
      skip()
