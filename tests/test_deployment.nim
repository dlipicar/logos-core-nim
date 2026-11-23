## The BCP §5.4 deployment document against the code (Tier 4b step 4b-8b;
## DECISIONS I97, G309; plan §4.3).
##
## `docs/DEPLOYMENT.md` describes the deployment logosd is, and its facts block
## (the fenced `json deployment-facts` block) states the values a reader can
## check. Each case compares one part of that block with the code that makes
## it so, so the document cannot drift from the build: the Module Loader's
## advertised mappings, the transport profile, the permission registry, the
## deadlines' defaults and the store's bounds; and, on a logosd assembled and
## started in this process (the `test_ctl_module` pattern) with one hosted
## provider, the host's user and process group, the session's modes, the state
## kept after retirement and the execution summary's selection.
## `spectrace deploydoc` checks the document's tables against the claims.

when defined(posix):
  import std/[algorithm, json, locks, monotimes, os, sequtils, strutils, tables, times]
  import unittest2
  import ./support/sanitizerenv
  import logos_sdk/crypto/blake3
  import ../src/logos_core/permissions
  import ../src/logos_core/runtime/[engine, host], logos_sdk/kit/[rc_arms, rc_types]
  from ../src/logos_core/runtime/plumbing import
    DefaultStartupDeadline, DefaultLoaderStartupDeadline, DefaultStopDeadline,
    DefaultShutdownGrace, DefaultApplyDeadline, MaxDiagnostics
  from ../src/logos_core/runtime/routing import RouteMode
  from ../src/logos_core/runtime/realizer import
    LoaderErrorCode, lecUnsupportedStrategy, lecAbiInvalid, ModuleCode, CodeKind,
    codeStatic, probeCode, completeProbe
  from ../src/logos_core/runtime/store import MaxStoreBytes
  from ../src/logos_core/authority/core import AuthorityLimits
  from ../src/logos_core/authority/policy import DefaultAuditRecords
  from ../src/logos_core/transport/io/api import defaultTransportConfig
  from ../src/logos_core/orchestration/accounting import nil
  from logos_sdk/iface/accept import acceptContractSet, acceptBinding, AcceptOptions
  from logos_sdk/iface/provider import callSurfaceDescriptor
  from ../src/logos_core/durable import DurableLock, release
  from ../src/logos_core/daemon/config import
    DefaultStoreQueue, DefaultStoreRecords, DefaultStoreAgeDays, OrchestratorInstance,
    CliInstance, CliModule, DefaultCliWorkers, DefaultCliStreams, DefaultIdleTimeoutMs,
    DefaultRouteIdleMs
  from ../src/logos_core/cli/hops import MaxHops
  from ../src/logos_core/orchestration/settings import OrchestratorModule
  from ../src/logos_core/daemon/evstore import
    DefaultSegmentEntries, DefaultSegmentBytes
  import
    ../src/logos_core/daemon/
      [assemble, ctlwire, daemon_config_types, logging, session, sessioninit]
  from ../src/logos_core/daemon/compose import prepareDaemon, CliEvents, cliSocketPath
  from ../src/logos_core/daemon/trustfile import TrustFileState, floorTrust
  import
    logos_sdk/testing/kitbuild,
    ./support/[loaderharness, modulehostbuild, shortdir, slowdown]
  import logos_sdk/testing/testdirs

  import std/posix

  const
    Patience = 20 * Slow ## seconds a bounding wait allows
    Timeout = 15_000 * Slow ## a client's wait for a reply, ms
    StopDeadlineMs = 10_000 * Slow
      ## `stop_deadline_ms` and `shutdown_grace_ms` here: the defaults, scaled
      ## under a sanitizer as `test_logosd` does; no case is about them
    ChatterInstance = "chatter-1"
    ChatterState = "chatter-state"
    Document = staticRead("../docs/DEPLOYMENT.md")
    FactsFence = "```json deployment-facts"

  proc deploymentFacts(): JsonNode =
    ## The document's one facts block, parsed.
    var body: seq[string]
    var inside = false
    for line in Document.splitLines:
      if inside:
        if line.startsWith("```"):
          break
        body.add(line)
      elif line.strip == FactsFence:
        inside = true
    doAssert inside, "docs/DEPLOYMENT.md has no facts block"
    parseJson(body.join("\n"))

  let facts = deploymentFacts()

  proc strings(n: JsonNode): seq[string] =
    for x in n:
      result.add(x.getStr)

  func hex(bytes: openArray[byte]): string =
    for b in bytes:
      result.add(toHex(int(b), 2).toLowerAscii)

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

  # A logosd in this process ---------------------------------------------------------------

  let
    hostExe = moduleHostProgram()
    chatterLib = buildKitLibrary("chatter_impl.nim", "dplchatter")
    beaconRoot = @(
      acceptContractSet(readFile(fixtureDir / "beacon_module.cddl"))
      .expect("the beacon_module contract set").primary.root
    ) ## so `chatter-1` is a provider: its endpoint is made in `run/ep`

  proc digestOfFile(path: string): seq[byte] =
    var h: Blake3Hasher
    h.init()
    let bytes = readFile(path)
    h.update(bytes.toOpenArrayByte(0, bytes.high))
    @(h.finish())

  proc chatterModule(): LcnAppModule =
    ## An operator provider in a Module Host, with persistent state.
    LcnAppModule(
      instance: ChatterInstance,
      module: "beacon_module",
      primary_contract: Opt.some(SchemaCommitment(schema_root: beaconRoot)),
      state_assignment: Opt.some(ChatterState),
      implementation: LcnAppImplementation(
        kind: LcnAppImplementationKind.Process_hosted_dynamic,
        arm_Process_hosted_dynamic: LcnAppImplementationARProcessHostedDynamicMap(
          artifact: LcnAppArtifact(
            id: "chatter", local_path: chatterLib, hash: digestOfFile(chatterLib)
          )
        ),
      ),
    )

  proc chatterDeclaration(): LcnAppDeclaration =
    ## The same provider, declared so that logosctl may create instances of it
    ## (each with fresh persistent state) that the host configuration does not
    ## name, and so may retire (RUNTIME l.3581-3582).
    LcnAppDeclaration(
      module: "beacon_module",
      primary_contract: Opt.some(SchemaCommitment(schema_root: beaconRoot)),
      persistent_state: Opt.some(true),
      implementation: chatterModule().implementation,
    )

  var sessions = 0

  proc newSession(hosted: bool): Session =
    ## `init`'s default configuration, with the test's Module Host program and,
    ## when `hosted`, `chatter-1`, which the orchestrator starts.
    inc sessions
    let base = makeShortBase(
      "dpl" & $sessions, deepest = "/s/run/ep/12345678/logos_beacon_module.sock"
    )
    let s = Session(dir: base / "s")
    var dc = defaultDaemonConfig("assigned-by-init")
    dc.runtime.module_host = Opt.some(hostExe)
    dc.runtime.module_host_env = Opt.some(@SanitizerEnv)
    when Slow > 1:
      dc.runtime.stop_deadline_ms = Opt.some(uint32(StopDeadlineMs))
      dc.runtime.shutdown_grace_ms = Opt.some(uint32(StopDeadlineMs))
    if hosted:
      dc.modules = Opt.some(@[chatterModule()])
      dc.declarations = Opt.some(@[chatterDeclaration()])
      var o = dc.orchestration.get(LcnDcOrchestration())
      o.start = Opt.some(@[ChatterInstance])
      dc.orchestration = Opt.some(o)
    let r = initSession(s, InitOptions(config: Opt.some(dc)))
    doAssert r.isOk, "init: " & r.error
    s

  type Live = object
    s: Session
    d: Daemon
    lock: DurableLock
    up: bool

  var live: ptr Live ## what the teardown ends, if a case left it running

  proc boot(s: Session): Live =
    ## Assembles and starts, then waits for the socket (DAEMON.md §4).
    result.s = s
    result.lock = lockSession(s).expect("the session lock")
    let d = assembleDaemon(s, AssembleOptions(version: "test", notify: notifyTest))
    doAssert d.isOk, "assemble: " & d.error.message
    result.d = d.get
    let serving = "logosctl: serving " & result.d.socketPath
    let before = logText().count(serving)
    let r = startDaemon(result.d)
    doAssert r.isOk, "start: " & r.error.message
    result.up = true
    let until = getMonoTime() + initDuration(seconds = Patience)
    while logText().count(serving) == before:
      doAssert getMonoTime() < until,
        "not serving: " & result.d.socketPath & "; the log:\n" & logText()
      sleep(5)

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

  proc client(l: Live): cint =
    connectCtl(l.d.socketPath, Timeout).expect("a connection")

  proc rc[Req](l: Live, m: LcnCtlMethodKind, req: Req): LcnCtlReply =
    # The reply is assigned before the socket closes; a `defer` with the
    # round trip as the trailing expression handed back a zeroed reply.
    let fd = l.client
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

  proc target(l: Live, instance: string): rc_types.LogosNSRuntimeModuleInstanceAddress =
    rc_types.LogosNSRuntimeModuleInstanceAddress(
      module_instance_id: instance,
      runtime_instance_id: l.d.prepared.config.value.runtime.runtime_instance_id,
    )

  proc summary(
      l: Live, instance: string
  ): LogosNSRuntimeControlGetExecutionSummaryResponse =
    let r = l.rc(
      LcnCtlMethodKind.Get_execution_summary,
      LogosNSRuntimeControlGetExecutionSummaryRequest(target: l.target(instance)),
    )
    LogosNSRuntimeControlGetExecutionSummaryResponse.decode(r.okBytes).expect(
      "a summary"
    )

  proc reaches(l: Live, instance: string, state: LogosNSRuntimeControlStateKind): bool =
    let until = getMonoTime() + initDuration(seconds = Patience)
    while getMonoTime() < until:
      if l.summary(instance).state.kind == state:
        return true
      sleep(20)
    l.summary(instance).state.kind == state

  proc hostedBoot(): Live =
    ## A logosd with `chatter-1` ready in its Module Host.
    result = boot(newSession(hosted = true))
    doAssert result.reaches(ChatterInstance, LogosNSRuntimeControlStateKind.Ready),
      "chatter-1 is not ready; the log:\n" & logText()

  # What the operating system says about a process ---------------------------------------

  when defined(macosx):
    type ProcBsdInfo {.importc: "struct proc_bsdinfo", header: "<sys/proc_info.h>".} = object
      pbi_uid: uint32

    proc procPidInfo(
      pid: cint, flavor: cint, arg: uint64, buffer: pointer, size: cint
    ): cint {.importc: "proc_pidinfo", header: "<libproc.h>".}

    const ProcPidTbsdInfo = 3.cint

  proc uidOf(pid: int): int =
    ## The process's effective uid, or -1.
    when defined(linux):
      try:
        for line in readFile("/proc/" & $pid & "/status").splitLines:
          if line.startsWith("Uid:"):
            return parseInt(line.splitWhitespace[2])
      except CatchableError:
        discard
      -1
    elif defined(macosx):
      var info: ProcBsdInfo
      let n = procPidInfo(cint(pid), ProcPidTbsdInfo, 0, addr info, cint(sizeof(info)))
      if n != cint(sizeof(info)):
        return -1
      int(info.pbi_uid)
    else:
      -1

  proc modeOf(path: string): (int, int) =
    ## Permission bits and owner, not following a final link.
    var st: Stat
    doAssert lstat(cstring(path), st) == 0, "lstat " & path
    (int(st.st_mode) and 0o7777, int(st.st_uid))

  # A module named as the Credential Store ------------------------------------------------

  const
    CredentialStoreModule = "logos_credential_store" ## CS l.162; BCP l.280
    CredentialStoreDoc =
      "_module = \"logos_credential_store\"\n\nstore.changed_event = {\n  n: uint64,\n}\n"
      ## a provider of one event, so it needs no per-method function

  let credSurfaceBytes = callSurfaceDescriptor(
      acceptBinding(
        CredentialStoreModule,
        Opt.some(CredentialStoreDoc),
        opts = AcceptOptions(system: true),
      )
        .expect("the call surface, as a system module's")
    )
    .expect("its descriptor")
  let credSurface = cast[ptr UncheckedArray[uint8]](allocShared0(credSurfaceBytes.len))
  for i, b in credSurfaceBytes:
    credSurface[i] = b
  let credSurfaceLen = credSurfaceBytes.len

  proc credName(): cstring {.cdecl, gcsafe, raises: [].} =
    CredentialStoreModule

  proc credCallSurface(outLen: ptr csize_t): ptr uint8 {.cdecl, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      outLen[] = csize_t(credSurfaceLen)
      cast[ptr uint8](credSurface)

  proc credNever() {.cdecl, gcsafe, raises: [].} =
    ## init, destroy, free and dispatch: binding calls none of them
    doAssert false

  proc credentialStoreCode(): ModuleCode =
    ## The module's code as a static table: the symbols a Module Host or the
    ## realizer of a `direct_dynamic` artifact would find in its library.
    var t = initTable[string, pointer]()
    t["logos_logos_credential_store_MODULE_name"] = cast[pointer](credName)
    t["logos_logos_credential_store_MODULE_call_surface"] =
      cast[pointer](credCallSurface)
    for s in ["init", "destroy", "free", "dispatch"]:
      t["logos_logos_credential_store_MODULE_" & s] = cast[pointer](credNever)
    ModuleCode(kind: codeStatic, table: t)

  # Cases ---------------------------------------------------------------------------------

  suite "bcp.deployment: docs/DEPLOYMENT.md's facts against the code (BCP §5.4; DECISIONS I97, G309)":
    setup:
      var l {.inject.} = Live()
      live = addr l

    teardown:
      if live != nil and live[].up:
        finish(live[])
      live = nil

    test "[BCP-0043] the Module Loader, wired as logosd wires it, advertises the facts' strategies and placements and never force_release; a sandbox or container placement is unsupported-strategy before anything is read":
      let f = facts["loader"]
      let work = makeShortBase("dplldr")
      var h = openHarness(@[], work, hosted = true).expect("the Loader")
      defer:
        h.close()
      let c = h.at.typed(
        "list_capabilities",
        LogosNSModuleLoaderListCapabilitiesRequest(),
        LogosNSModuleLoaderListCapabilitiesResponse,
      ).get.capabilities
      var strategies: seq[string]
      if c.direct_static == Opt.some(true):
        strategies.add("direct_static")
      if c.direct_dynamic == Opt.some(true):
        strategies.add("direct_dynamic")
      if c.hosted_dynamic.isSome:
        strategies.add("hosted_dynamic")
      check strategies == f["strategies"].strings
      var placements: seq[string]
      let p = c.hosted_dynamic.get(LogosNSModuleLoaderCapabilitiesHostedDynamicMap())
      if p.process == Opt.some(true):
        placements.add("process")
      if p.sandbox == Opt.some(true):
        placements.add("sandbox")
      if p.container == Opt.some(true):
        placements.add("container")
      check placements == f["hosted_placements"].strings
      check c.force_release.isSome == f["force_release"].getBool
      for name in f["unsupported_placements"].strings:
        let placement =
          if name == "sandbox":
            LogosNSModuleLoaderHostedPlacement(
              kind: LogosNSModuleLoaderHostedPlacementKind.Sandbox
            )
          else:
            LogosNSModuleLoaderHostedPlacement(
              kind: LogosNSModuleLoaderHostedPlacementKind.Container
            )
        let d = LogosNSModuleLoaderRealizationDescriptor(
          kind: LogosNSModuleLoaderRealizationDescriptorKind.Hosted_dynamic,
          arm_Hosted_dynamic: LogosNSModuleLoaderRealizationDescriptorARHostedDynamicMap(
            module: "beacon_module",
            artifact: LogosNSModuleLoaderArtifact(
              id: "nowhere",
              local_path: work / "does-not-exist.so",
              hash: newSeq[byte](32),
            ),
            placement: placement,
          ),
        )
        let x = h.realizeAs(realizeRequest("p-" & name, d))
        check x.response.isOk
        if x.response.isOk:
          check x.response.get.errorCode == Opt.some(lecUnsupportedStrategy)

    test "[BCP-0041] the local transport profile is the facts'; no remote profile: routes are direct or local-transport, and a hosted provider's endpoint is a unix-stream socket under run/ep":
      let f = facts["transport"]
      check LogosNSRuntimeControlInvocationDescriptorAR0Map().profile ==
        f["local_profile"].getStr
      check LogosNSModuleLoaderProviderEndpoint().profile == f["local_profile"].getStr
      check f["remote_profiles"].len == 0
      var modes: seq[RouteMode]
      for m in RouteMode:
        modes.add(m)
      check modes == @[rmDirect, rmLocalTransport]
      l = hostedBoot()
      check l.d.prepared.composition.appConfig.runtime.endpoint_dir ==
        Opt.some(l.s.endpointDir)
      var sockets: seq[string]
      for path in walkDirRec(l.s.endpointDir, yieldFilter = {pcFile}):
        var st: Stat
        if lstat(cstring(path), st) == 0 and S_ISSOCK(st.st_mode):
          sockets.add(path.extractFilename)
      check sockets == @["logos_beacon_module.sock"]

    test "[BCP-0044] the selected permission profile defines what the facts list, each enforced by Runtime admission, and logosd always selects it":
      let f = facts["permissions"]
      let profile = builtinProfile(f["profile"].getStr)
      check profile.isSome
      let p = build(profile.get)
      check p.name == f["profile"].getStr
      check p.definitions.len == f["definitions"].len
      for i, d in p.definitions:
        if i < f["definitions"].len:
          let want = f["definitions"][i]
          check d.name == want["name"].getStr
          check d.enforcement == epRuntimeAdmission
          check want["enforcer"].getStr == "Runtime admission"
          check d.active
          check d.name == HostAmbient
          check hex(HostAmbientConstraints) == want["constraints"].getStr
      l = boot(newSession(hosted = false))
      let perms = l.d.prepared.composition.appConfig.permissions
      check perms.isSome
      if perms.isSome:
        check perms.get.profile == f["profile"].getStr

    test "[BCP-0104] [TXT-0351] [TXT-0349] [TXT-0368] [TXT-0369] every `logos.` identifier the code names is one a Logos specification assigns: a mirrored name or its namespace, or one listed with its line; none names a provenance profile":
      const
        NameChars = {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_', '.', '-'}
        Assigned =
          [("logos.route-ticket.random-256", "TRANSPORT l.1004, outside a CDDL block")]
      proc tokens(text: string, quoted: bool): seq[string] =
        ## Each whole `logos.` token: starting a string literal (`quoted`), or
        ## not inside a longer name; a trailing dot, as in the bare prefix
        ## `"logos."`, leaves a namespace.
        var i = text.find("logos.")
        while i >= 0:
          var j = i + "logos.".len
          while j < text.len and text[j] in NameChars:
            inc j
          let before = (if i == 0: ' ' else: text[i - 1])
          if (quoted and before == '"') or (not quoted and before notin NameChars):
            result.add text[i ..< j].strip(leading = false, chars = {'.'})
          i = text.find("logos.", j)

      var mirrored: seq[string]
      for f in walkDirRec("spec" / "mirrors"):
        mirrored.add readFile(f).tokens(quoted = false)
      var seen = 0
      for root in ["src", "sdk" / "src"]:
        for f in walkDirRec(root):
          var found: seq[string]
          if f.endsWith(".nim"):
            found = readFile(f).tokens(quoted = true)
          elif f.endsWith(".cddl"):
            for line in readFile(f).splitLines:
              found.add line.split(';', 1)[0].tokens(quoted = false)
          for t in found:
            checkpoint f & ": " & t
            check t in mirrored or mirrored.anyIt(it.startsWith(t & ".")) or
              Assigned.anyIt(it[0] == t)
            check not t.startsWith("logos.package-provenance")
            inc seen
      check seen > 0

    test "[BCP-0045] a hosted module's Module Host runs under the daemon's user, in a process group of its own":
      check facts["hosts_run_as"].getStr == "the daemon's user"
      l = hostedBoot()
      check l.d.prepared.composition.appConfig.runtime.module_host == Opt.some(hostExe)
      let pids = hostPids()
      check pids.len == 1
      for pid in pids:
        check uidOf(pid) == int(geteuid())
        check int(getpgid(Pid(pid))) == pid
        check getpgid(Pid(pid)) != getpgrp()

    test "[BCP-0046] [BCP-0091] [BCP-0092] the session is owner-only, its directories 0700; retiring an instance keeps its state directory":
      let modes = facts["modes"]
      let dirMode = parseOctInt(modes["directory"].getStr)
      let fileMode = parseOctInt(modes["file"].getStr)
      let copyMode = parseOctInt(modes["artifact_copy"].getStr)
      check facts["state_after_retire"].getStr == "kept"
      l = hostedBoot()
      let uid = int(geteuid())
      check modeOf(l.s.dir) == (dirMode, uid)
      for path in walkDirRec(l.s.dir, yieldFilter = {pcDir, pcFile}, relative = false):
        let (mode, owner) = modeOf(path)
        checkpoint(path & " " & toOct(mode, 4))
        check owner == uid
        check (mode and 0o077) == 0
        if dirExists(path) and not symlinkExists(path):
          check mode == dirMode
        elif path.parentDir.extractFilename.startsWith("lcn-artifacts-"):
          check mode == copyMode
        else:
          check mode == fileMode
      for path in [l.s.configPath, l.s.trustPath]:
        check modeOf(path) == (fileMode, uid)
      check dirExists(l.s.modulesDir / ChatterState)
      # An instance the host configuration names cannot be retired, so the
      # retired one is created through logosctl, with state of its own.
      let before = toSeq(walkDir(l.s.modulesDir, relative = true)).mapIt(it.path)
      let made = LogosNSRuntimeControlCreateModuleResponse
        .decode(
          l.rc(
            LcnCtlMethodKind.Create_module,
            LogosNSRuntimeControlCreateModuleRequest(
              module: "beacon_module", request_key: "dpl-retire"
            ),
          ).okBytes
        )
        .expect("the created instance").accepted.get
      let started = l.rc(
        LcnCtlMethodKind.Start_module,
        LogosNSRuntimeControlStartModuleRequest(
          module: "beacon_module", instance: Opt.some(made.instance)
        ),
      )
      discard started.okBytes
      check l.reaches(made.instance, LogosNSRuntimeControlStateKind.Ready)
      let fresh = toSeq(walkDir(l.s.modulesDir, relative = true))
        .mapIt(it.path)
        .filterIt(it notin before)
      check fresh.len == 1
      let stopped = l.rc(
        LcnCtlMethodKind.Stop_module,
        LogosNSRuntimeControlStopModuleRequest(
          module: "beacon_module", instance: Opt.some(made.instance)
        ),
      )
      discard stopped.okBytes
      check l.reaches(made.instance, LogosNSRuntimeControlStateKind.Unloaded)
      let revision = l.summary(made.instance).execution.revision
      let retired = l.rc(
        LcnCtlMethodKind.Retire_module,
        LogosNSRuntimeControlRetireModuleRequest(
          target: l.target(made.instance), expected_execution_revision: revision
        ),
      )
      discard retired.okBytes
      for name in fresh:
        let kept = l.s.modulesDir / name
        check dirExists(kept)
        check modeOf(kept) == (dirMode, uid)

    test "[BCP-0078] the five deadlines' defaults are the facts', and init's configuration leaves each to its default":
      let f = facts["deadlines"]
      check DefaultLoaderStartupDeadline.inMilliseconds == f["loader_startup"].getInt
      check DefaultStartupDeadline.inMilliseconds == f["startup"].getInt
      check DefaultApplyDeadline.inMilliseconds == f["apply"].getInt
      check DefaultStopDeadline.inMilliseconds == f["stop"].getInt
      check DefaultShutdownGrace.inMilliseconds == f["shutdown_grace"].getInt
      let r = defaultDaemonConfig("assigned-by-init").runtime
      check r.startup_deadline_ms.isNone
      check r.apply_deadline_ms.isNone
      check r.stop_deadline_ms.isNone
      check r.shutdown_grace_ms.isNone

    test "[BCP-0047] the call-evidence store is off by default, with the facts' bounds; the Runtime keeps the facts' number of diagnostics":
      let f = facts["evidence_store"]
      check f["default"].getStr == "off"
      let ca = defaultDaemonConfig("assigned-by-init").call_audit
      check ca.isNone or ca.get.store.isNone
      check DefaultStoreQueue == f["queue"].getInt
      check DefaultStoreRecords == f["max_records"].getInt
      check DefaultStoreAgeDays == f["max_age_days"].getInt
      check DefaultSegmentEntries == f["segment_entries"].getInt
      check DefaultSegmentBytes == f["segment_bytes"].getInt
      check MaxDiagnostics == facts["diagnostics_retained"].getInt

    test "[IMPL-DECISION G343] [IMPL-DECISION G344] [IMPL-DECISION G346] the CLI module's facts are the code's: its instance hosted in a process of its own, not started at boot, its socket, its defaults, the events it may follow and its bound on continuations":
      let f = facts["cli"]
      check f["instance"].getStr == CliInstance
      check f["socket"].getStr == "run" / "lcn_call.sock"
      let s = Session(dir: makeShortBase("dpcli") / "s")
      check cliSocketPath(s, "") == s.dir / f["socket"].getStr
      check f["workers"].getInt == DefaultCliWorkers
      check f["streams"].getInt == DefaultCliStreams
      check f["idle_timeout"].getInt == DefaultIdleTimeoutMs
      check f["route_idle"].getInt == DefaultRouteIdleMs
      check f["events"].getElems.mapIt(it.getStr) == CliEvents.sorted
      check f["max_hops"].getInt == MaxHops
      var dc = defaultDaemonConfig("assigned-by-init")
      dc.runtime.module_host = Opt.some(hostExe)
      dc.cli = Opt.some(
        LcnDcCli(
          artifact: Opt.some(
            LcnAppArtifact(
              id: "lcn_call",
              local_path: "/opt/lib/liblcn_call.so",
              hash: newSeq[byte](32),
            )
          )
        )
      )
      let p = prepareDaemon(s, dc.encode.get, TrustFileState(file: floorTrust()))
      check p.isOk
      if p.isOk:
        let comp = p.get.composition
        let m = comp.appConfig.modules.filterIt(it.instance == CliInstance)
        check m.len == 1
        if m.len == 1:
          check m[0].module == CliModule
          check f["placement"].getStr == "process"
          check m[0].implementation.kind ==
            LcnAppImplementationKind.Process_hosted_dynamic
        check f["started_at_boot"].getBool == false
        check comp.orchestrator.defaults.get(@[]).allIt(it.instance != CliInstance)

    test "[BCP-0102] [TXT-0555] [TXT-0350] the admission pools' totals and per-consumer limits are the facts', and so is the authority's audit bound; logosd's Runtime instance is the engine with the facts' orchestration module and instance; logosd composes no Credential Store and refuses an operator module named logos_credential_store; a Module Host refuses it at binding":
      # The pools (DEPLOYMENT.md §12, "Admission pools"), with logosd's
      # defaults: it sets no engine, authority or Transport limit.
      proc pool(total: int, perConsumer = -1): JsonNode =
        result = newJObject()
        result["total"] = %total
        result["per_consumer"] =
          if perConsumer < 0:
            newJNull()
          else:
            %perConsumer

      let
        el = EngineLimits().effective
        al = AuthorityLimits()
        tc = defaultTransportConfig()
        pools = {
          "prepared_calls": pool(MaxAsyncCalls),
          "module_instances": pool(MaxInstances),
          "call_workers": pool(MaxCallWorkers + MaxNestedCallWorkers),
          "evaluation_queue": pool(EvalQueue),
          "observation_snapshots": pool(el.snapshotsTotal, el.snapshotsPerConsumer),
          "observation_snapshot_bytes":
            pool(el.snapshotBytesTotal, el.snapshotBytesPerConsumer),
          "observe_end_registrations": pool(el.endRegsTotal, el.endRegsPerConsumer),
          "runtime_control_subscriptions": pool(el.rcSubsTotal, el.rcSubsPerSubscriber),
          "store_snapshot_bytes": pool(MaxStoreBytes),
          "authority_queued_requests": pool(al.moduleQueue),
          "authority_grants": pool(al.maxGrants),
          "authority_watches": pool(al.maxWatches, al.watchesPerConsumer),
          "transport_inbound": pool(tc.maxInbound),
          "transport_pending_hellos": pool(tc.maxPendingHellos),
          "transport_outbound": pool(tc.maxOutbound),
          "transport_calls": pool(tc.maxTotalCalls),
          "transport_subscriptions": pool(tc.maxTotalSubscriptions),
          "transport_subscription_ids": pool(tc.maxTotalSubscriptionIds),
          "transport_hello_input_bytes": pool(tc.maxHelloInputBytes),
          "transport_input_bytes": pool(tc.maxInputBytes),
          "transport_output_bytes": pool(tc.maxOutputBytes),
          "transport_pending_output_bytes": pool(tc.maxPendingOutputBytes),
          "orchestrator_open_episodes": pool(accounting.MaxEntries),
        }
        f = facts["admission_pools"]
      check f.len == pools.len
      for (name, want) in pools:
        checkpoint name
        check f.hasKey(name) and f[name] == want
      let dc = defaultDaemonConfig("assigned-by-init")
      check dc.transport.isNone
      # [CA l.1208; DECISIONS G376] acknowledged at the append, under this
      # bound (test_authority's G376 cases hold the behaviour).
      let a = facts["authority_audit"]
      check a["acknowledged"].getStr == "append"
      check a["unwritten_bound"].getInt == al.maxUnwritten
      check a["retained_records"].getInt == int(DefaultAuditRecords)

      # No Credential Store (§25): none in init's composition; [G490] logosd
      # refuses an operator's module of the name, and binding refuses it as a
      # provider that is no Logos system module.
      check facts["credential_store"].getStr == "none"
      let floor = TrustFileState(file: floorTrust())
      let s = Session(dir: makeShortBase("dplcs") / "s")
      let plain = prepareDaemon(s, dc.encode.get, floor).expect("init's configuration")
      check plain.composition.appConfig.modules.allIt(
        it.module != CredentialStoreModule
      )
      # [BCP l.286; RUNTIME l.66] The RUNTIME claim covers logosd's Runtime
      # instance: the engine with this orchestration module, by the code's names.
      let claim = facts["runtime_claim"]
      let orch = claim["orchestration_instance"].getStr
      check orch == OrchestratorInstance
      check claim["orchestration_module"].getStr == OrchestratorModule
      let app = plain.composition.appConfig
      check app.orchestration == orch
      check app.modules.anyIt(
        it.instance == orch and it.module == OrchestratorModule and
          it.implementation.kind == LcnAppImplementationKind.Direct_static
      )
      var op = dc
      var m = chatterModule()
      m.instance = "credential-store"
      m.module = CredentialStoreModule
      m.state_assignment = Opt.none(string)
      op.modules = Opt.some(@[m])
      op.runtime.module_host = Opt.some(hostExe)
      let p = prepareDaemon(s, op.encode.get, floor)
      check p.isErr
      if p.isErr:
        check "modules: instance credential-store uses the reserved module-name prefix logos_" in
          p.error
      let cs = credentialStoreCode()
      let bound = completeProbe(cs, probeCode(cs, CredentialStoreModule), false)
      check bound.isErr
      if bound.isErr:
        check bound.error.code == lecAbiInvalid
        check "reserved for Logos system modules" in bound.error.message
      # The same code as a Logos system module binds: the name alone refuses it.
      check completeProbe(cs, probeCode(cs, CredentialStoreModule), true).isOk

    test "[PKG-0422] a hosted instance's execution summary names its implementation and no signer or package: no execution depends on package-signing trust":
      l = hostedBoot()
      let s = l.summary(ChatterInstance)
      check s.selection.isSome
      if s.selection.isSome:
        let sel = s.selection.get
        check sel.signer.isNone
        check sel.package.isNone
        check sel.implementation.kind ==
          LogosNSRuntimeControlExecutionSelectionImplementationChoiceKind.Hosted_dynamic
else:
  import unittest2

  suite "bcp.deployment: docs/DEPLOYMENT.md's facts against the code (POSIX only)":
    test "[IMPL] logosd is a stub on this platform (DECISIONS G107); there is no deployment to check":
      skip()
