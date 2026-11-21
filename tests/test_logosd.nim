## logosd and logosctl as processes (Tier 4b step 4b-6; DECISIONS G88, G89,
## G296, G297, G299, G300, G302; docs/DAEMON.md): `init`, start, the status,
## shutdown by signal and by command, a restart after kill -9, the
## development switch and its banner, trust continuity, the offline writers'
## lock, concurrent shells, retirement, the socket path's limits, a Loader
## loss, a key bound to another Runtime, and the call-evidence store's
## commands.
##
## The children are built for the suite's variant (`daemonbuild.nim`): logosd
## with test hooks, logosctl without. They run with `posix_spawn`, their
## output in files (`daemonproc.nim`). A sanitizer report makes a child exit
## non-zero, so every clean stop checks the exit code and prints the child's
## stderr when it is not 0.

when defined(posix):
  import std/[json, monotimes, os, sequtils, strutils, times]
  import unittest2
  import logos_sdk/cbor
  import logos_sdk/crypto/blake3
  import
    ../src/logos_core/daemon/[
      config, daemon_config_types, evkey, evstore, session, sessioninit, trust_types,
      trustfile,
    ]
  from ../src/logos_core/runtime/evidence import
    newEvidenceContext, accept, verifyEvidence
  from ../src/logos_core/authority/scopes import encode, sortSet
  from ../src/logos_core/daemon/supervise import heldLocks
  from ../src/logos_core/runtime/plumbing import MaxDiagnostics
  from logos_sdk/iface/accept import acceptContractSet
  from ../src/logos_core/durable import
    acquire, ensurePrivateDir, release, removeIfPresent, writeAtomic
  import
    ./support/[
      clibuild, daemonbuild, daemonproc, evfixture, modulehostbuild, shortdir, slowdown
    ],
    logos_sdk/testing/[kitbuild, testdirs]

  import std/posix

  const
    ReadyMs = 120_000 * Slow
      ## [IMPL] Only bounds a wait for what comes: the socket answering, an
      ## instance's state, the chatter line, an expected exit. With 20 s
      ## times Slow, starts on a host at load 100 outlasted it under refc
      ## and ASan (4b-8's closing check).
    StopDeadlineMs = 10_000 * Slow
      ## `runtime.stop_deadline_ms` and `shutdown_grace_ms` here: the defaults
      ## (10 s), scaled under a sanitizer, where a Module Host's stop on a
      ## loaded CI runner outlasted them (CI on b3af640: exit 3, "cleanup
      ## unresolved"). No case is about these deadlines.
    StopMs = 3 * StopDeadlineMs
      ## how long a case waits for logosd to exit: past both deadlines
    HostsGoneMs = 10_000 * Slow
    SanitizerEnv =
      ["ASAN_OPTIONS", "LSAN_OPTIONS", "MSAN_OPTIONS", "TSAN_OPTIONS", "UBSAN_OPTIONS"]
      ## the Module Host's environment allow-list here: the sanitizers' settings
    ChatterLine = "chatter: beacon_module initialized in process "
      ## `tests/kit/chatter_impl.nim`'s line, which ends with the writer's pid
    ChatterInstance = "chatter-1"
    ChatterDelayVar = "LCN_CHATTER_INIT_DELAY_MS" ## `chatter_impl`'s init delay
    MeterInstance = "meter-1" ## a hosted provider `lcn_call` is granted
    LedgerInstance = "ledger-1" ## the confined ledger, `lcn_call`'s provider
    LedgerShells = 8 ## concurrent `logosctl call`s: `cli.workers`' default
    ledgerSkips = kitMm == "refc" or (defined(msan) and otherMm == "refc")
      ## [DECISIONS G277] a refc logosd refuses every route to a contract that
      ## marks a payload, as the ledger's `seal` does; [G342] a refc library is
      ## built without the sanitizer, and MemorySanitizer takes what it writes
      ## for uninitialized (I77)

  let
    dExe = logosdProgram()
    ctlExe = logosctlProgram()
    sensorLib = buildKitLibrary("sensor_impl.nim", "lgdsensor")
    hostExe = moduleHostProgram()
    chatterLib = buildKitLibrary("chatter_impl.nim", "lgdchatter")
    beaconRoot = @(
      acceptContractSet(readFile(repoDir / fixtureDir / "beacon_module.cddl"))
      .expect("the beacon_module contract set").primary.root
    ) ## so `chatter-1` provides it: a hosted provider's endpoint is made in `run/ep`
    cliArt = cliArtifact()
    meterLib = buildKitLibrary("meter_impl.nim", "lgdmeter")
    meterRoot = @(
      acceptContractSet(readFile(repoDir / "spec/mirrors/IFC/3.9.1.module.cddl"))
      .expect("the meter_module contract set").primary.root
    )
    # [DECISIONS G342, G335] The thread-confined ledger built with the other
    # memory manager: refc beside this orc logosd, the node's own pairing.
    # Under refc it is not built, since its cases skip (`ledgerSkips`).
    ledgerLib =
      if ledgerSkips:
        ""
      else:
        buildKitLibrary(
          "ledger_lib.nim", "lgdledger", otherMm, exports = "ledger_module"
        )
    ledgerRoot = @(
      acceptContractSet(readFile(repoDir / fixtureDir / "ledger_module.cddl"))
      .expect("the ledger_module contract set").primary.root
    )

  var cases = 0
  var children: seq[Child]

  proc digestOfFile(path: string): seq[byte] =
    var h: Blake3Hasher
    h.init()
    let bytes = readFile(path)
    h.update(bytes.toOpenArrayByte(0, bytes.high))
    @(h.finish())

  type Case = object
    dir: string ## the case's directory: the session is `dir/s`
    s: Session

  proc newCase(): Case =
    inc cases
    result.dir = makeShortBase("lgd" & $cases, deepest = "/s/run/logosctl.sock")
    result.s = Session(dir: result.dir / "s")

  proc ctl(c: Case, args: varargs[string]): Ran =
    ## Text output; a child's stdout is a file, where JSON is the default (G89).
    runOnce(
      ctlExe,
      @["--session-dir", c.s.dir, "--text"] & @args,
      c.dir,
      timeoutMs = 120_000 * Slow,
    )

  proc ctlJson(c: Case, args: varargs[string]): (int, JsonNode) =
    let r = runOnce(
      ctlExe,
      @["--session-dir", c.s.dir, "--json"] & @args,
      c.dir,
      timeoutMs = 120_000 * Slow,
    )
    try:
      (r.code, parseJson(r.stdout))
    except CatchableError:
      checkpoint("not JSON: " & r.stdout & r.stderr)
      (r.code, newJNull())

  proc sensorDecl(): LcnAppDeclaration =
    LcnAppDeclaration(
      module: "sensor_module",
      implementation: LcnAppImplementation(
        kind: LcnAppImplementationKind.Direct_dynamic,
        arm_Direct_dynamic: LcnAppImplementationARDirectDynamicMap(
          artifact: LcnAppArtifact(
            id: "sensor", local_path: sensorLib, hash: digestOfFile(sensorLib)
          )
        ),
      ),
    )

  proc chatterModule(): LcnAppModule =
    ## [E3] An operator provider realized by a Module Host.
    LcnAppModule(
      instance: ChatterInstance,
      module: "beacon_module",
      primary_contract: Opt.some(SchemaCommitment(schema_root: beaconRoot)),
      implementation: LcnAppImplementation(
        kind: LcnAppImplementationKind.Process_hosted_dynamic,
        arm_Process_hosted_dynamic: LcnAppImplementationARProcessHostedDynamicMap(
          artifact: LcnAppArtifact(
            id: "chatter", local_path: chatterLib, hash: digestOfFile(chatterLib)
          )
        ),
      ),
    )

  proc chatterPids(log: string): seq[int] =
    ## The pids `chatter_impl` reported, one per initialization, in log order.
    for line in log.splitLines:
      let at = line.find(ChatterLine)
      if at >= 0:
        try:
          result.add(parseInt(line[at + ChatterLine.len .. ^1].strip))
        except ValueError:
          discard

  proc hostsGone(ms = HostsGoneMs): bool =
    ## No Module Host of this build is left, polled for up to `ms`.
    let until = getMonoTime() + initDuration(milliseconds = ms)
    while hostPids().len > 0:
      if getMonoTime() >= until:
        return false
      sleep(20)
    true

  proc configFile(c: Case, dc: LcnDaemonConfig): string =
    result = c.dir / "config.cbor"
    writeFile(result, cast[string](dc.encode.expect("an encoding")))

  proc initWith(c: Case, dc: LcnDaemonConfig, extra: varargs[string]): Ran =
    var dc = dc
    when Slow > 1:
      dc.runtime.stop_deadline_ms = Opt.some(uint32(StopDeadlineMs))
      dc.runtime.shutdown_grace_ms = Opt.some(uint32(StopDeadlineMs))
    c.ctl(@["init", "--config", "@" & c.configFile(dc)] & @extra)

  proc initDefault(c: Case): Ran =
    var dc = defaultDaemonConfig("assigned-by-init")
    dc.declarations = Opt.some(@[sensorDecl()])
    c.initWith(dc)

  proc initHosted(c: Case, start: bool, hostEnv: seq[string] = @[]): Ran =
    ## The default configuration with the hosted `chatter-1`, which the
    ## orchestrator starts when `start` is set; `hostEnv` adds to the host's
    ## environment allow-list.
    var dc = defaultDaemonConfig("assigned-by-init")
    dc.declarations = Opt.some(@[sensorDecl()])
    dc.runtime.module_host = Opt.some(hostExe)
    dc.runtime.module_host_env = Opt.some(@SanitizerEnv & hostEnv)
    dc.modules = Opt.some(@[chatterModule()])
    if start:
      var o = dc.orchestration.get(LcnDcOrchestration())
      o.start = Opt.some(@[ChatterInstance])
      dc.orchestration = Opt.some(o)
    c.initWith(dc)

  proc editConfig(c: Case, edit: proc(dc: var LcnDaemonConfig)) =
    var (dc, _) = readDaemonConfig(c.s).expect("the daemon-config")
    edit(dc)
    check writeAtomic(c.s.dir, DaemonConfigName, dc.encode.expect("bytes")).isOk

  proc start(c: Case, name = "logosd", env: openArray[(string, string)] = []): Child =
    result = spawnChild(dExe, ["--session-dir", c.s.dir], c.dir, name, env)
    children.add(result)

  proc socketOf(c: Case): string =
    c.s.socketPath()

  proc ready(c: Case, d: Child): bool =
    ## The socket answers `status`, or the daemon ended.
    let until = ReadyMs div 20
    for _ in 0 ..< until:
      if not d.alive:
        return false
      if entryExists(c.socketOf):
        if c.ctl("status").code == 0:
          return true
      sleep(20)
    false

  proc stopped(d: Child): int =
    result = stopChild(d, StopMs)
    if result != 0:
      checkpoint("logosd stderr:\n" & d.errText)

  proc lockFree(c: Case): bool =
    ## The session lock (an `flock`, `durable.acquire`) is free: probed with
    ## the same call, since `lockf` does not see an `flock`.
    var l = acquire(c.s.dir).valueOr:
      return false
    l.release()
    true

  proc expectReady(c: Case, d: Child) =
    if not c.ready(d):
      checkpoint("logosd stderr:\n" & d.errText)
      fail()

  proc state(c: Case, instance: string): string =
    ## The instance's state in `module ls`; empty when it is not listed.
    let (code, j) = c.ctlJson("module", "ls")
    if code != 0:
      return ""
    for m in j{"result", "modules"}.getElems:
      if m{"instance"}.getStr == instance:
        return m{"state"}.getStr

  proc reaches(c: Case, instance, want: string): bool =
    ## Whether the instance reaches state `want` within `ReadyMs`.
    let until = getMonoTime() + initDuration(milliseconds = ReadyMs)
    var seen = c.state(instance)
    while seen != want and getMonoTime() < until:
      sleep(20)
      seen = c.state(instance)
    if seen != want:
      checkpoint(instance & " is " & seen & ", not " & want)
    seen == want

  proc startChatter(c: Case): Ran =
    c.ctl("module", "start", "beacon_module", "--instance", ChatterInstance)

  proc providerModule(
      instance, module, lib: string, root: seq[byte], hosted = true
  ): LcnAppModule =
    ## An operator provider realized from `lib` by a Module Host, or in
    ## logosd's own process when `hosted` is off (`direct_dynamic`).
    let artifact = LcnAppArtifact(id: module, local_path: lib, hash: digestOfFile(lib))
    LcnAppModule(
      instance: instance,
      module: module,
      primary_contract: Opt.some(SchemaCommitment(schema_root: root)),
      implementation:
        if hosted:
          LcnAppImplementation(
            kind: LcnAppImplementationKind.Process_hosted_dynamic,
            arm_Process_hosted_dynamic:
              LcnAppImplementationARProcessHostedDynamicMap(artifact: artifact),
          )
        else:
          LcnAppImplementation(
            kind: LcnAppImplementationKind.Direct_dynamic,
            arm_Direct_dynamic:
              LcnAppImplementationARDirectDynamicMap(artifact: artifact),
          ),
    )

  proc initCli(
      c: Case,
      provider = providerModule(MeterInstance, "meter_module", meterLib, meterRoot),
  ): Ran =
    ## [DAEMON.md §7a] The default configuration with the operator module
    ## `provider` (by default the hosted `meter-1`; not started), an operator
    ## rule granting `lcn_call` all of its provider actions, its event
    ## included, the provider's own `publish-event`, and `cli.artifact`
    ## naming the library `support/clibuild` builds.
    var dc = defaultDaemonConfig("assigned-by-init")
    dc.runtime.module_host = Opt.some(hostExe)
    dc.runtime.module_host_env = Opt.some(@SanitizerEnv)
    dc.modules = Opt.some(@[provider])
    let root = provider.primary_contract.get.schema_root
    var actions = @[
      LcnApAction(kind: LcnApActionKind.Discover),
      LcnApAction(kind: LcnApActionKind.Establish_route),
      LcnApAction(kind: LcnApActionKind.Renew_route),
      LcnApAction(kind: LcnApActionKind.Call),
      LcnApAction(kind: LcnApActionKind.Subscribe_event),
    ]
    sortSet(actions)
    dc.policy.arm_Capability_authority.rules = @[
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
                actions: actions,
              ),
            )
          ],
        ),
      ),
      # [SPEC CA l.244-247] The provider's own `publish-event`: a delivery
      # needs it as well as the subscriber's `subscribe-event`.
      LcnApRule(
        kind: LcnApRuleKind.lcn_Ap_allow,
        arm_lcn_Ap_allow: LcnApAllow(
          subject: LcnApSubject(instances: Opt.some(@[provider.instance])),
          scopes: @[
            LcnApScope(
              kind: LcnApScopeKind.lcn_Ap_provider_access,
              arm_lcn_Ap_provider_access: LcnApProviderAccess(
                contract: LcnApProviderAccessContractChoice(
                  kind: LcnApProviderAccessContractChoiceKind.logos_Schema_commitment,
                  arm_logos_Schema_commitment: SchemaCommitment(schema_root: root),
                ),
                actions: @[LcnApAction(kind: LcnApActionKind.Publish_event)],
              ),
            )
          ],
        ),
      ),
    ]
    sortSet(dc.policy.arm_Capability_authority.rules)
    dc.cli = Opt.some(LcnDcCli(artifact: Opt.some(cliArt)))
    c.initWith(dc)

  func hexOf(bytes: openArray[byte]): string =
    for b in bytes:
      result.add(toHex(b, 2).toLowerAscii)

  proc startMeter(c: Case): Ran =
    c.ctl("module", "start", "meter_module", "--instance", MeterInstance)

  proc lcn(c: Case, args: varargs[string]): Ran =
    ## A CLI command with no output flag: stdout is a file, so JSON (G89).
    runOnce(
      ctlExe, @["--session-dir", c.s.dir] & @args, c.dir, timeoutMs = 120_000 * Slow
    )

  proc cliSocket(c: Case): string =
    c.s.dir / "run" / "lcn_call.sock"

  proc chatterLogged(d: Child, count: int): seq[int] =
    ## The chatter pids in `d`'s log once there are `count`, or what there is
    ## after `ReadyMs`.
    let until = getMonoTime() + initDuration(milliseconds = ReadyMs)
    result = chatterPids(d.errText)
    while result.len < count and getMonoTime() < until:
      sleep(20)
      result = chatterPids(d.errText)

  proc ledgerCall(c: Case, args: varargs[string]): (int, JsonNode) =
    ## `logosctl call ledger_module …` with JSON output: its exit code and
    ## the response.
    let r = c.lcn(@["call", "ledger_module"] & @args)
    checkpoint r.stdout & r.stderr
    try:
      (r.code, parseJson(r.stdout){"result"})
    except CatchableError:
      (r.code, newJNull())

  proc settles(c: Case, instance: string): string =
    ## The instance's state once it is no longer `ready` or `stopping`, or
    ## what it is after `ReadyMs`.
    let until = getMonoTime() + initDuration(milliseconds = ReadyMs)
    result = c.state(instance)
    while result in ["ready", "stopping"] and getMonoTime() < until:
      sleep(20)
      result = c.state(instance)

  proc ledgerCase(hosted: bool) =
    ## [DECISIONS G342, G335-G338] The ledger, a thread-confined refc kit
    ## module, realized by orc logosd in its own process or by a Module Host;
    ## `lcn_call` calls it.
    let c = newCase()
    check c.initCli(
      providerModule(LedgerInstance, "ledger_module", ledgerLib, ledgerRoot, hosted)
    ).code == 0
    let d = c.start()
    c.expectReady(d)
    check c.ctl("module", "start", "ledger_module", "--instance", LedgerInstance).code ==
      0
    check c.ctl("module", "wait", "ledger_module", "--instance", LedgerInstance).code ==
      0
    # Its GC'd state is kept in the instance, on its module thread.
    let (a, first) = c.ledgerCall("post", "key=k", "amount=5")
    check a == 0
    check first{"total"}.getBiggestInt == 5
    let thread = first{"thread"}.getBiggestInt
    check thread != 0
    # [IF l.1899-1905, l.1942-1947] Calls that arrive at once, on whatever
    # threads the host calls from, all run on that thread.
    var shells: seq[Child]
    for i in 0 ..< LedgerShells:
      shells.add(
        spawnChild(
          ctlExe,
          [
            "--session-dir", c.s.dir, "call", "ledger_module", "post", "key=k",
            "amount=1",
          ],
          c.dir,
          "post" & $i,
        )
      )
    for sh in shells:
      check waitExit(sh, 120_000 * Slow) == 0
      try:
        check parseJson(sh.outText){"result", "thread"}.getBiggestInt == thread
      except CatchableError:
        checkpoint("not JSON: " & sh.outText & sh.errText)
        fail()
    let (b, after) = c.ledgerCall("post", "key=k", "amount=0")
    check b == 0
    check after{"total"}.getBiggestInt == 5 + LedgerShells
    # [G338] An async handler, through the deferred surface; and a plain one
    # reading its caller.
    let (w, waited) = c.ledgerCall("wait", "channel=1", "millis=20", "value=7")
    check w == 0
    check waited{"value"}.getBiggestInt == 7
    check waited{"thread"}.getBiggestInt == thread
    check waited{"note"}.getStr == CliInstance
    let (p, probed) = c.ledgerCall("probe", "channel=1", "value=0")
    check p == 0
    check probed{"note"}.getStr == CliInstance
    check probed{"thread"}.getBiggestInt == thread
    # Stopped and started again: a new instance, with its own state.
    check c.ctl("module", "stop", "ledger_module", "--instance", LedgerInstance).code ==
      0
    check c.settles(LedgerInstance) in ["loaded", "unloaded"]
    check c.ctl("module", "start", "ledger_module", "--instance", LedgerInstance).code ==
      0
    check c.ctl("module", "wait", "ledger_module", "--instance", LedgerInstance).code ==
      0
    let (r, again) = c.ledgerCall("post", "key=k", "amount=2")
    check r == 0
    check again{"total"}.getBiggestInt == 2
    check d.stopped == 0
    check hostsGone()

  suite "daemon.logosd: logosd and logosctl as processes (DAEMON.md) [IMPL-DECISION G88] [IMPL-DECISION G89] [IMPL-DECISION G296]":
    teardown:
      for ch in children:
        if ch.alive:
          discard stopChild(ch, StopMs)
      children = @[]
      killAll()
      # Every case leaves no Module Host behind; a stray one is ended so the
      # next case's count starts at zero.
      if not hostsGone():
        checkpoint("Module Hosts left: " & $hostPids())
        for pid in hostPids():
          discard kill(Pid(pid), SIGKILL)
        fail()

    test "init: the layout and its modes, a UUIDv4 Runtime id, trust revision 1 with its mark, the evidence key and its binding":
      let c = newCase()
      let r = c.initDefault()
      check r.code == 0
      for d in ["", "keys", "state", "state/store", "state/modules", "work"]:
        var st: Stat
        check stat(cstring(c.s.dir / d), st) == 0
        check (int(st.st_mode) and 0o777) == 0o700
      let (dc, _) = readDaemonConfig(c.s).expect("the daemon-config")
      let id = dc.runtime.runtime_instance_id
      check id.len == 36 and id[14] == '4' and id[19] in {'8', '9', 'a', 'b'}
      let t = readTrust(c.s).expect("the trust file")
      check t.file.revision == 1 and not t.file.development
      check readMark(c.s).expect("the mark").isSome
      let keys = listEvidenceKeys(c.s.keysDir).expect("keys")
      check keys.len == 1
      var st: Stat
      check stat(cstring(keys[0].keyFile), st) == 0
      check (int(st.st_mode) and 0o777) == 0o600
      check st.st_size == 96
      let (code, j) = c.ctlJson("trust", "evidence-keys", "ls")
      check code == 0
      check j["result"]["keys"][0]["runtime_instance_id"].getStr == id
      check j["result"]["keys"][0]["public_key"].getStr.len == 96
      # [G89] stdout is not a terminal: JSON without --json.
      let plain = runOnce(ctlExe, @["--session-dir", c.s.dir, "trust", "show"], c.dir)
      check plain.code == 0
      check plain.stdout.startsWith(
        "{\"deployment\":\"production\",\"command\":\"trust show\""
      )

    test "[BCP-0021] [BCP-0022] [BCP-0023] [BCP-0024] [BCP-0088] start, status --json: production; the system instances ready; init's Runtime id; SIGTERM ends it cleanly":
      let c = newCase()
      check c.initDefault().code == 0
      let d = c.start()
      c.expectReady(d)
      let (code, j) = c.ctlJson("status")
      check code == 0
      check j["deployment"].getStr == "production"
      let (dc, _) = readDaemonConfig(c.s).expect("the daemon-config")
      check j["result"]["daemon"]["runtime_instance_id"].getStr ==
        dc.runtime.runtime_instance_id
      let (lc, ls) = c.ctlJson("module", "ls")
      check lc == 0
      var states: seq[(string, string)]
      for m in ls["result"]["modules"]:
        states.add((m{"instance"}.getStr, m["state"].getStr))
      for i in ["orchestrator", "authority", "logosctl"]:
        check (i, "ready") in states
      # [Rev R20] every instance names a Loader strategy; the Loader its own.
      proc strategy(i: string): string =
        let (sc, sj) = c.ctlJson("module", "summary", i)
        check sc == 0
        sj{"result", "selection", "implementation", "strategy"}.getStr

      for i in ["orchestrator", "authority", "logosctl"]:
        check strategy(i) == "direct_static"
      check strategy("logos_module_loader") == "implementation-specific"
      check "ready: runtime " & dc.runtime.runtime_instance_id in d.errText
      check d.stopped == 0
      check not entryExists(c.socketOf)
      check c.lockFree
      check c.ctl("status").code == 2

    test "[IMPL-DECISION G38] a value file is held to Logos deterministic CBOR when it is read, in either notation":
      let c = newCase()
      for (name, text) in [
        ("null.diag", "null"),
        ("undefined.diag", "undefined"),
        ("tag.diag", "1(2)"),
        ("null.cbor", "\xf6"),
        ("tag.cbor", "\xc1\x02"),
      ]:
        checkpoint name
        writeFile(c.dir / name, text)
        let r = c.ctl("init", "--config", "@" & (c.dir / name))
        check r.code != 0
        check "is not deterministic CBOR" in r.stdout & r.stderr

    test "daemon stop --wait: the daemon exits 0":
      let c = newCase()
      check c.initDefault().code == 0
      let d = c.start()
      c.expectReady(d)
      let r = c.ctl("daemon", "stop", "--wait")
      check r.code == 0
      check waitExit(d, StopMs) == 0

    test "[IMPL] kill -9, then a restart: the stale socket does not block, and module create --request-key returns the same instance":
      let c = newCase()
      check c.initDefault().code == 0
      var d = c.start()
      c.expectReady(d)
      let (c1, j1) =
        c.ctlJson("module", "create", "sensor_module", "--request-key", "lcli-k1")
      check c1 == 0
      killChild(d)
      check entryExists(c.socketOf)
      d = c.start("logosd2")
      c.expectReady(d)
      let (c2, j2) =
        c.ctlJson("module", "create", "sensor_module", "--request-key", "lcli-k1")
      check c2 == 0
      check j2["result"]["instance"] == j1["result"]["instance"]
      check j2["request_key"].getStr == "lcli-k1"
      check d.stopped == 0

    test "[BCP-0103] [BCP-0094] [BCP-0095] allow-all needs the switch; on, the banner shows in the log and in online and offline output; test_hooks needs it too":
      let c = newCase()
      check c.initDefault().code == 0
      c.editConfig(
        proc(dc: var LcnDaemonConfig) =
          dc.policy = LcnDcPolicy(kind: LcnDcPolicyKind.Allow_all)
      )
      var d = c.start()
      check waitExit(d, ReadyMs) == 1
      check "development switch" in d.errText
      c.editConfig(
        proc(dc: var LcnDaemonConfig) =
          dc.policy = defaultDaemonConfig("x").policy
          dc.test_hooks =
            Opt.some(LcnDcTestHooks(ctl_command_delay_ms: Opt.some(1'u32)))
      )
      d = c.start("logosd2")
      check waitExit(d, ReadyMs) == 1
      check "test_hooks: needs the development switch" in d.errText
      c.editConfig(
        proc(dc: var LcnDaemonConfig) =
          dc.policy = LcnDcPolicy(kind: LcnDcPolicyKind.Allow_all)
          dc.test_hooks = Opt.none(LcnDcTestHooks)
      )
      check c.ctl("trust", "development", "on").code == 0
      d = c.start("logosd3")
      c.expectReady(d)
      check "NON-PRODUCTION" in d.errText
      let (code, j) = c.ctlJson("status")
      check code == 0
      check j["deployment"].getStr == "non-production"
      check "NON-PRODUCTION" in c.ctl("status").stdout
      let (oc, oj) = c.ctlJson("trust", "show")
      check oc == 0
      check oj["deployment"].getStr == "non-production"
      check "NON-PRODUCTION" in c.ctl("trust", "show").stdout
      check d.stopped == 0

    test "[BCP-0096] with the switch on under capability-authority, module stop logos_module_loader is still NOT_AUTHORISED (exit 4)":
      let c = newCase()
      check c.initDefault().code == 0
      check c.ctl("trust", "development", "on").code == 0
      let d = c.start()
      c.expectReady(d)
      let r = c.ctl("module", "stop", "logos_module_loader")
      check r.code == 4
      check "NOT_AUTHORISED" in r.stderr
      check d.stopped == 0

    test "[RUN-1113] [RUN-1114] module start --if-revision with a stale revision: the code and the current revision, exit 4, and --json carries the error arm":
      # [re-pin P4a] A typed error is a successful call whose response holds
      # the error arm; logosctl exits as for any Runtime Control refusal.
      let c = newCase()
      check c.initDefault().code == 0
      let d = c.start()
      c.expectReady(d)
      let (made, j) = c.ctlJson("module", "create", "sensor_module")
      check made == 0
      let instance = j["result"]["instance"].getStr
      let (listed, ls) = c.ctlJson("module", "ls", "--module", "sensor_module")
      check listed == 0
      # A revision above 2^53 is a JSON string (G89); a persistent engine's
      # revisions start at its epoch shifted left by 32.
      proc uintOf(n: JsonNode): uint64 =
        if n.kind == JString:
          parseBiggestUInt(n.getStr).uint64
        else:
          n.getBiggestInt.uint64

      let rev = uintOf(ls["result"]["modules"][0]["execution"]["revision"])
      let args = @[
        "module",
        "start",
        "sensor_module",
        "--instance",
        instance,
        "--if-revision",
        $(rev + 1),
      ]
      let r = c.ctl(args)
      check r.code == 4
      check ("stale-revision: current revision " & $rev) in r.stderr
      let (code, answer) = c.ctlJson(args)
      check code == 4
      check answer["result"]["error"]["code"].getStr == "stale-revision"
      check uintOf(answer["result"]["error"]["current_revision"]) == rev
      check c.state(instance) == "unloaded"
      check d.stopped == 0

    test "[PKG-0418] [PKG-0419] [PKG-0420] [PKG-0421] trust continuity across starts":
      let c = newCase()
      check c.initDefault().code == 0
      proc put(revision: uint64, development: bool) =
        check writeTrustFile(
          c.s, LcnPackageTrust(revision: revision, development: development)
        ).isOk

      proc startsWith(code: int): bool =
        let d = c.start()
        if code == 0:
          result = c.ready(d) and d.stopped == 0
        else:
          result = waitExit(d, ReadyMs) == code
        if not result:
          checkpoint(d.errText)

      put(3, false)
      check startsWith(0)
      check readMark(c.s).expect("a mark").get.revision == 3
      put(2, false)
      check startsWith(1)
      put(3, true) # same revision, other content
      check startsWith(1)
      put(3, false) # identical replay
      check startsWith(0)
      check removeIfPresent(c.s.stateDir / TrustMarkName).isOk
      check startsWith(1)
      check c.ctl("trust", "reestablish", "--revision", "3").code == 0
      check startsWith(0)

    test "[IMPL-DECISION G192] a session whose state store was lost does not start again under its Runtime id (exit 1; RUNTIME l.2630-2632)":
      let c = newCase()
      check c.initDefault().code == 0
      let d = c.start()
      c.expectReady(d)
      check d.stopped == 0
      # The whole of state/ lost: the trust mark re-established, the store not.
      removeDir(c.s.stateDir)
      check ensurePrivateDir(c.s.stateDir).isOk
      check c.ctl("trust", "reestablish", "--revision", "1").code == 0
      let again = c.start()
      check waitExit(again, ReadyMs) == 1
      check "the Runtime state store is missing" in again.errText
      check "logosctl init" in again.errText
      check not fileExists(c.s.storeDir / "runtime-state.cbor")

    test "offline writers are refused while logosd runs (exit 1); read-only offline commands work":
      let c = newCase()
      check c.initDefault().code == 0
      let d = c.start()
      c.expectReady(d)
      let w = c.ctl("trust", "development", "on")
      check w.code == 1
      let held = "another logosd or an offline logosctl command holds this session"
      check held in w.stderr
      check c.ctl("trust", "show").code == 0
      check c.ctl("daemon", "config", "get").code == 0
      check c.ctl("trust", "evidence-keys", "ls").code == 0
      check d.stopped == 0

    test "[BCP-0092] 8 concurrent shells, module create with distinct keys: 8 instances; retire says the state is kept":
      let c = newCase()
      check c.initDefault().code == 0
      let d = c.start()
      c.expectReady(d)
      var shells: seq[Child]
      for i in 0 ..< 8:
        shells.add(
          spawnChild(
            ctlExe,
            ["--session-dir", c.s.dir, "module", "create", "sensor_module"],
            c.dir,
            "sh" & $i,
          )
        )
      for sh in shells:
        check waitExit(sh, 120_000 * Slow) == 0
      let (code, j) = c.ctlJson("module", "ls", "--module", "sensor_module")
      check code == 0
      check j["result"]["modules"].len == 8
      let one = j["result"]["modules"][0]["instance"].getStr
      let r = c.ctl("module", "retire", one)
      check r.code == 0
      check "retired; its state directory is kept" in r.stdout
      check d.stopped == 0

    test "a socket path longer than sun_path: exit 1 naming ctl.socket_dir; a ctl.socket_dir with group access: exit 1":
      let c = newCase()
      check c.initDefault().code == 0
      let long = c.dir / repeat("d", 120)
      createDir(long)
      discard chmod(cstring(long), 0o700)
      c.editConfig(
        proc(dc: var LcnDaemonConfig) =
          dc.ctl = Opt.some(LcnDcCtl(socket_dir: Opt.some(long)))
      )
      var d = c.start()
      check waitExit(d, ReadyMs) == 1
      check "ctl.socket_dir" in d.errText
      let open = c.dir / "open"
      createDir(open)
      discard chmod(cstring(open), 0o750)
      c.editConfig(
        proc(dc: var LcnDaemonConfig) =
          dc.ctl = Opt.some(LcnDcCtl(socket_dir: Opt.some(open)))
      )
      d = c.start("logosd2")
      check waitExit(d, ReadyMs) == 1
      check "ctl.socket_dir" in d.errText

    test "[G302] a Loader loss (test_hooks.loader_failure_after_ms, the switch on): logosd logs the termination and exits 4":
      let c = newCase()
      check c.initDefault().code == 0
      check c.ctl("trust", "development", "on").code == 0
      c.editConfig(
        proc(dc: var LcnDaemonConfig) =
          dc.test_hooks = Opt.some(
            LcnDcTestHooks(loader_failure_after_ms: Opt.some(uint32(500 * Slow)))
          )
      )
      let d = c.start()
      check waitExit(d, ReadyMs + StopMs) == 4
      let log = d.errText
      check "the Module Loader failed; termination required" in log
      check "exiting with 4" in log
      # [I95 amended 2026-11-16] Drained before the exit: the Runtime's line,
      # the Loader's own words quoted and attributed (BCP l.551).
      check (
        "info: runtime: the Module Loader has failed: reported-by-module: " &
        "\"a failure injected by the test\" (text from logos_module_loader)"
      ) in log
      check c.lockFree

    test "[IMPL] [I95 amended 2026-11-16] the Runtime's diagnostics in logosd's log: text it did not write one line and attributed, and a wrap of its ring counted in one line (DAEMON.md §12; BCP l.551)":
      # test_hooks.diagnostics records count lines once the start's own
      # diagnostics are logged, before the drain's thread first reads: past the
      # ring's size, its next read finds the oldest dropped.
      let c = newCase()
      check c.initDefault().code == 0
      check c.ctl("trust", "development", "on").code == 0
      c.editConfig(
        proc(dc: var LcnDaemonConfig) =
          dc.test_hooks = Opt.some(
            LcnDcTestHooks(
              diagnostics: Opt.some(
                LcnDcTestDiagnostics(
                  text: "injected\nlogosd[1]: error: a forged line",
                  count: uint32(MaxDiagnostics + 5),
                )
              )
            )
          )
      )
      let d = c.start()
      c.expectReady(d)
      let until = getMonoTime() + initDuration(milliseconds = ReadyMs)
      while "diagnostics dropped" notin d.errText and getMonoTime() < until:
        sleep(50)
      check d.stopped == 0
      let lines = d.errText.splitLines
      let injected = lines.filterIt(
        (
          "info: runtime: a diagnostic injected by the test: " &
          "\"injected logosd[1]: error: a forged line\" (text from test_hooks)"
        ) in it
      )
      checkpoint($injected.len & " injected lines logged")
      check injected.len == MaxDiagnostics
      check lines.allIt(not it.startsWith("logosd[1]:"))
      let dropped =
        lines.filterIt("warn: runtime: " in it and "diagnostics dropped" in it)
      check dropped.len == 1
      if dropped.len == 1:
        let n = dropped[0].split("warn: runtime: ")[1].split(' ')[0]
        checkpoint(dropped[0])
        check parseInt(n) >= 5

    test "a key whose binding names another Runtime id: start exits 1":
      let c = newCase()
      check c.initDefault().code == 0
      let keys = listEvidenceKeys(c.s.keysDir).expect("keys")
      var (dc, _) = readDaemonConfig(c.s).expect("the daemon-config")
      var b = keys[0].binding
      b.runtime_instance_id = "00000000-0000-4000-8000-000000000000"
      check writeAtomic(c.s.keysDir, bindingFileName(b.kid), b.encode.expect("bytes")).isOk
      dc.call_audit = Opt.some(
        LcnDcCallAudit(
          evidence:
            Opt.some(LcnAppEvidenceKey(kid: b.kid, secret_key_file: keys[0].keyFile))
        )
      )
      check writeAtomic(c.s.dir, DaemonConfigName, dc.encode.expect("bytes")).isOk
      let d = c.start()
      check waitExit(d, ReadyMs) == 1
      check "belongs to Runtime 00000000-0000-4000-8000-000000000000" in d.errText

    test "[IMPL-DECISION G146] a hosted operator module in orchestration.start: ready, its stderr in logosd's log unfiltered; logosd's stop ends its host":
      let c = newCase()
      check c.initHosted(start = true).code == 0
      let d = c.start()
      c.expectReady(d)
      check c.reaches(ChatterInstance, "ready")
      let pids = d.chatterLogged(1)
      check pids.len == 1
      if pids.len == 1:
        check pids[0] != int(d.pid)
        check pids[0] in hostPids()
      check d.stopped == 0
      check hostsGone()
      check heldLocks(c.s.workDir).len == 0
      check c.lockFree

    test "[RUN-0998] [RUN-0925] [RUN-1000] [IMPL-DECISION I96] a hosted operator module replaced by state_transfers move: the next start retires it and gives its directory to the replacement, which the orchestrator starts":
      let c = newCase()
      var dc = defaultDaemonConfig("assigned-by-init")
      dc.runtime.module_host = Opt.some(hostExe)
      dc.runtime.module_host_env = Opt.some(@SanitizerEnv)
      var old = chatterModule()
      old.state_assignment = Opt.some("chatter-1-state")
      dc.modules = Opt.some(@[old])
      dc.orchestration =
        Opt.some(LcnDcOrchestration(start: Opt.some(@[ChatterInstance])))
      check c.initWith(dc).code == 0
      var d = c.start()
      c.expectReady(d)
      check c.reaches(ChatterInstance, "ready")
      check d.stopped == 0
      check hostsGone()
      let fromDir = c.s.modulesDir / "chatter-1-state"
      let toDir = c.s.modulesDir / "chatter-2-state"
      check dirExists(fromDir)
      writeFile(fromDir / "data", "chatter-1's state")
      # The operator's edit, offline: the replacement instead of the old one.
      c.editConfig(
        proc(dc: var LcnDaemonConfig) =
          var m = chatterModule()
          m.instance = "chatter-2"
          m.state_assignment = Opt.some("chatter-2-state")
          dc.modules = Opt.some(@[m])
          dc.orchestration =
            Opt.some(LcnDcOrchestration(start: Opt.some(@["chatter-2"])))
          dc.state_transfers = Opt.some(
            @[
              LcnAppStateTransfer(
                `from`: ChatterInstance,
                to: "chatter-2",
                mode: LcnAppStateTransferModeChoice(
                  kind: LcnAppStateTransferModeChoiceKind.Move
                ),
              )
            ]
          )
      )
      check c.ctl("daemon", "config", "check").code == 0
      d = c.start("logosd2")
      c.expectReady(d)
      check c.reaches("chatter-2", "ready")
      check c.state(ChatterInstance) == ""
      check not dirExists(fromDir)
      check readFile(toDir / "data") == "chatter-1's state"
      # [I95 amended 2026-11-16] The transfer's diagnostic, drained at start.
      check (
        "info: runtime: state transfer: chatter-1 (chatter-1-state) to chatter-2 " &
        "(chatter-2-state), move"
      ) in d.errText
      check d.stopped == 0
      check hostsGone()
      # Applied once: the entry left in place changes nothing at the next start.
      d = c.start("logosd3")
      c.expectReady(d)
      check c.reaches("chatter-2", "ready")
      check readFile(toDir / "data") == "chatter-1's state"
      check d.stopped == 0
      # [G143; I96 part 7c] Offline, the store says where the state went.
      let (code, j) = c.ctlJson("state", "list")
      check code == 0
      var seen = 0
      for e in j{"result", "entries"}.getElems:
        if e{"name"}.getStr == "chatter-2-state":
          check e{"holder"}.getStr == "live" and e{"instance"}.getStr == "chatter-2"
          check e{"origin"}.getStr == "from chatter-1 (chatter-1-state), move"
          inc seen
        if e{"name"}.getStr == "chatter-1-state":
          check e{"holder"}.getStr == "retired" and not e{"present"}.getBool
          check e{"moved"}.getStr == "to chatter-2, move"
          inc seen
      check seen == 2
      let text = c.ctl("state", "list")
      check text.code == 0
      check "chatter-2-state  live chatter-2" in text.stdout
      check "from chatter-1 (chatter-1-state), move" in text.stdout
      # Not a terminal and no `--yes`: nothing is purged.
      let unasked = c.ctl("state", "purge", ChatterInstance)
      check unasked.code == 1 and "add --yes" in unasked.stderr
      # A live instance's state is never purged; the moved one has nothing left.
      let live = c.ctl("state", "purge", "chatter-2", "--yes")
      check live.code == 1 and "retire it first" in live.stderr
      let moved = c.ctl("state", "purge", ChatterInstance, "--yes")
      check moved.code == 0 and "nothing to purge" in moved.stdout
      check dirExists(toDir)

    test "[BCP-0028] [BCP-0036] [BCP-0049] [BCP-0050] a selected profile that fails (run/ep made unwritable): the hosted start fails, no Module Host runs and nothing realizes the module elsewhere; usable again, it starts":
      let c = newCase()
      check c.initHosted(start = false).code == 0
      let d = c.start()
      c.expectReady(d)
      let ep = c.s.endpointDir
      check chmod(cstring(ep), 0o500) == 0
      # The realization fails: `start_module` answers with the instance in
      # `error` (the call itself succeeds), and nothing replaces the endpoint.
      let r = c.startChatter()
      checkpoint("module start: " & $r.code & " " & r.stdout & r.stderr)
      check r.code == 0 and r.stdout.strip == ChatterInstance & ": error"
      check c.state(ChatterInstance) == "error"
      check chatterPids(d.errText).len == 0
      check hostPids().len == 0
      check chmod(cstring(ep), 0o700) == 0
      var again = c.startChatter()
      if again.code != 0:
        checkpoint("start after the failure: " & again.stderr)
        check c.ctl("module", "recover", ChatterInstance).code == 0
        again = c.startChatter()
      check again.code == 0
      check c.reaches(ChatterInstance, "ready")
      let pids = d.chatterLogged(1)
      check pids.len == 1 and pids[0] != int(d.pid)
      check d.stopped == 0

    test "[Rev R21] kill -9 with a hosted module running, restart at once: the instance starts once the old host's restart lock is free, never beside it":
      let c = newCase()
      check c.initHosted(start = false).code == 0
      var d = c.start()
      c.expectReady(d)
      check c.startChatter().code == 0
      let old = d.chatterLogged(1)
      check old.len == 1
      killChild(d)
      d = c.start("logosd2")
      c.expectReady(d)
      # On Linux the old host is gone already (PDEATHSIG, carrier EOF); on macOS
      # it may outlive the daemon, and while it holds its restart lock the start
      # is refused. Both orders are accepted.
      let until = getMonoTime() + initDuration(milliseconds = ReadyMs)
      var started = false
      var refused = 0
      var last = ""
      while getMonoTime() < until:
        let r = c.startChatter()
        if r.code == 0:
          started = true
          break
        inc refused
        last = r.stderr
        sleep(50)
      checkpoint("refused " & $refused & " times; last: " & last)
      check started
      # The invariant: when the new realization starts, the old host is gone.
      for pid in old:
        check pid notin hostPids()
      let now = d.chatterLogged(1)
      check now.len == 1
      if now.len == 1:
        check now[0] notin old and now[0] != int(d.pid)
      check d.stopped == 0

    test "[Rev R7] [G302] a Loader loss with a hosted module running: logosd exits 4 without hanging, its Module Host gone and every restart lock free":
      # The module is started here once the socket answers, not by the
      # orchestrator, whose start list waits for the authority binding (CI on
      # b3af640). The Loader fails once the case makes the trigger file, after
      # `module start` has answered: a timer from logosd's start fired before
      # the hosted start ended under a sanitizer (CI on 1ca4710).
      let c = newCase()
      let trigger = c.dir / "fail-loader"
      check c.initHosted(start = false).code == 0
      check c.ctl("trust", "development", "on").code == 0
      c.editConfig(
        proc(dc: var LcnDaemonConfig) =
          dc.test_hooks =
            Opt.some(LcnDcTestHooks(loader_failure_on_file: Opt.some(trigger)))
      )
      let d = c.start()
      c.expectReady(d)
      let begun = getMonoTime()
      let started = c.startChatter()
      checkpoint(
        "module start: " & $started.code & " after " &
          $(getMonoTime() - begun).inMilliseconds & " ms " & started.stderr
      )
      check started.code == 0
      check d.chatterLogged(1).len == 1
      check d.alive # nothing has failed the Loader yet
      writeFile(trigger, "")
      check waitExit(d, StopMs) == 4
      let log = d.errText
      checkpoint(log)
      check chatterPids(log).len == 1
      check "the Module Loader failed; termination required" in log
      check "exiting with 4" in log
      check "Module Host locks still held" notin log
      check hostsGone(2_000 * Slow)
      check heldLocks(c.s.workDir).len == 0
      check c.lockFree

    test "[RUN-0705] SIGTERM while a hosted provider's _MODULE_init still runs: logosd shuts down cleanly (exit 0), the start does not complete and its host is gone":
      # The realization in flight is cancelled and its host ended; the race
      # where the Loader's reply arrives after shutdown began is test_hosted_routes
      # P-5b's.
      let c = newCase()
      check c.initHosted(start = false, hostEnv = @[ChatterDelayVar]).code == 0
      let d = c.start(env = [(ChatterDelayVar, $(1_500 * Slow))])
      c.expectReady(d)
      let sh = spawnChild(
        ctlExe,
        [
          "--session-dir", c.s.dir, "--text", "module", "start", "beacon_module",
          "--instance", ChatterInstance,
        ],
        c.dir,
        "start",
      )
      children.add(sh)
      # The line comes from `_MODULE_init`, which then waits: realize is in flight.
      check d.chatterLogged(1).len == 1
      check c.state(ChatterInstance) != "ready"
      check d.stopped == 0
      let log = d.errText
      checkpoint(log)
      check "the Module Loader failed" notin log
      check "stopped" in log
      discard waitExit(sh, StopMs)
      check hostsGone()
      check heldLocks(c.s.workDir).len == 0

    test "[CAP-0415] [CAP-0416] [CAP-0417] [IMPL-DECISION G301] the call-evidence store: one daemon-config change turns it on and logosd opens it; audit evidence ls lists what the store's API wrote, export --seq N writes call evidence that verifies, to a new 0600 file or to a pipe; an existing file and a reaped seq are refused":
      let c = newCase()
      check c.initDefault().code == 0
      let k = listEvidenceKeys(c.s.keysDir).expect("keys")[0]
      let rid = k.binding.runtime_instance_id
      c.editConfig(
        proc(dc: var LcnDaemonConfig) =
          dc.call_audit = Opt.some(
            LcnDcCallAudit(
              evidence: Opt.some(
                LcnAppEvidenceKey(kid: k.binding.kid, secret_key_file: k.keyFile)
              ),
              store: Opt.some(LcnDcEvidenceStore()),
            )
          )
      )
      let d = c.start()
      c.expectReady(d)
      check stopped(d) == 0
      check "call-evidence store: boot 1, next seq 0" in d.errText
      check segmentNames(c.s.evidenceDir).mapIt(it[0]) == @[0'u64]
      # Records as logosd's store keeps them, written through its API while
      # logosd is stopped (no call here retains one).
      let records = (0 ..< 3).mapIt(meterCallRecordBytes(rid, "d-" & $it, uint64(it)))
      var o = StoreOptions(
        dir: c.s.evidenceDir,
        producer: rid,
        kid: k.binding.kid,
        maxRecords: 1_000,
        maxAgeDays: 30,
        queue: 64,
      )
      var st = openStore(o).expect("the store")
      check st.boot == 2
      for i, r in records:
        st.offer(uint64(i), r)
      closeStore(st)
      let (code, j) = c.ctlJson("audit", "evidence", "ls")
      check code == 0
      let segs = j{"result", "segments"}.getElems
      check segs.len == 1
      if segs.len == 1:
        check segs[0]{"records"}.getInt == 3
        check segs[0]{"end_seq"}.getInt == 3
        check segs[0]{"producer"}.getStr == rid
        check segs[0]{"boot"}.getInt == 2
      var ctx = newEvidenceContext()
      check ctx.accept(k.binding.kid, rid, k.binding.public_key).isOk
      proc verifies(bytes: string, want: seq[byte]): bool =
        let v = verifyEvidence(bytes.toOpenArrayByte(0, bytes.high), ctx)
        if v.isErr:
          checkpoint(v.error)
          return false
        v.get.producer == rid and v.get.proofs.isNone and
          encode(v.get.record).expect("an encoding") == want

      let outFile = c.dir / "seq1.cose"
      let wrote = c.ctl("audit", "evidence", "export", "--seq", "1", "--out", outFile)
      check wrote.code == 0
      check ("written to " & outFile) in wrote.stdout
      var fst: Stat
      check stat(cstring(outFile), fst) == 0
      check (int(fst.st_mode) and 0o777) == 0o600
      check verifies(readFile(outFile), records[1])
      let again = c.ctl("audit", "evidence", "export", "--seq", "1", "--out", outFile)
      check again.code == 1
      check "exists" in again.stderr
      # stdout is a file here, not a terminal: the container itself.
      let piped = runOnce(
        ctlExe,
        @["--session-dir", c.s.dir, "audit", "evidence", "export", "--seq", "2"],
        c.dir,
        timeoutMs = 120_000 * Slow,
      )
      check piped.code == 0
      check verifies(piped.stdout, records[2])
      # Reaped: an open bounded to one seq drops the older segment.
      o.maxRecords = 1
      closeStore(openStore(o).expect("the store"))
      let reaped =
        c.ctl("audit", "evidence", "export", "--seq", "1", "--out", outFile & ".2")
      check reaped.code == 1
      check "seq 1 is not retained" in reaped.stderr
      check not fileExists(outFile & ".2")

    test "[IMPL-DECISION G343] [IMPL-DECISION G349] call, describe and module wait as processes: the first command starts lcn_call; JSON on a file, diagnostic notation with --text; exits 1, 2 and 5":
      let c = newCase()
      check c.initCli().code == 0
      let d = c.start()
      c.expectReady(d)
      check c.startMeter().code == 0
      let mw = c.ctl("module", "wait", "meter_module", "--instance", MeterInstance)
      checkpoint mw.stderr
      check mw.code == 0
      # [G350] Not started with logosd: a wait for it ends at the timeout (2).
      let early =
        c.ctl("--timeout", "300", "module", "wait", CliModule, "--state", "ready")
      checkpoint early.stderr
      check early.code == 2
      check "last state unloaded" in early.stderr
      check not entryExists(c.cliSocket)
      # [G89] JSON when stdout is not a terminal, as here.
      let a = c.lcn("call", "meter_module", "read", "channel=7")
      checkpoint a.stdout & a.stderr
      check a.code == 0
      check a.stderr == ""
      let j = parseJson(a.stdout)
      check j{"command"}.getStr == "call meter_module.read"
      check j{"status"}.getStr == "ok"
      check j{"result", "label"}.getStr == "ch7"
      check j{"result", "reading", "value"}.getInt == 70
      check c.state(CliInstance) == "ready"
      check entryExists(c.cliSocket)
      check c.ctl("module", "wait", CliModule).code == 0
      let t = c.ctl("call", "meter_module", "read", "channel=8")
      checkpoint t.stdout & t.stderr
      check t.code == 0
      check "\"ch8\"" in t.stdout
      check "\"deployment\"" notin t.stdout
      let desc = c.lcn("describe", "meter_module")
      checkpoint desc.stdout & desc.stderr
      check desc.code == 0
      let r = parseJson(desc.stdout){"result"}
      check r{"instance"}.getStr == MeterInstance
      check r{"selected"}.getStr == hexOf(meterRoot)
      check r{"methods"}.getElems.anyIt(it{"method"}.getStr == "read")
      let dt = c.ctl("describe", "meter_module")
      check dt.code == 0
      check hexOf(meterRoot) & " (selected)" in dt.stdout
      # A value its field does not read (1); the provider's error channel (5).
      let bad = c.ctl("call", "meter_module", "read", "channel=x")
      check bad.code == 1
      check bad.stdout == ""
      check bad.stderr.startsWith("logosctl: ")
      let pe = c.ctl("call", "meter_module", "read", "channel=13")
      checkpoint pe.stderr
      check pe.code == 5
      # [G349 N-2d] A malformed argument is named by its position, never
      # echoed: the launcher cannot tell a marked one.
      let typo = c.ctl("call", "meter_module", "read", "QZXtypo7")
      checkpoint typo.stderr
      check typo.code == 1
      check "QZXtypo7" notin typo.stdout & typo.stderr
      check "argument 1 after the method" in typo.stderr
      check d.stopped == 0
      check hostsGone()

    test "[IMPL-DECISION G349] subscribe as a process: SIGINT ends it (130) and lcn_call serves the next command; a stream open at logosd's stop ends (6), logosd exits 0 and lcn_call's socket is gone":
      let c = newCase()
      check c.initCli().code == 0
      let d = c.start()
      c.expectReady(d)
      check c.startMeter().code == 0
      check c.ctl("module", "wait", "meter_module", "--instance", MeterInstance).code ==
        0
      proc streaming(c: Case, name: string): Child =
        ## `logosctl subscribe meter_module changed`, once its first event is
        ## on stdout: channel 15 publishes one, and a publication before the
        ## subscription is active reaches no one.
        result = spawnChild(
          ctlExe,
          ["--session-dir", c.s.dir, "subscribe", "meter_module", "changed"],
          c.dir,
          name,
        )
        children.add(result)
        let until = getMonoTime() + initDuration(milliseconds = ReadyMs)
        while "meter.changed_event" notin result.outText and result.alive and
            getMonoTime() < until:
          discard c.lcn("call", "meter_module", "read", "channel=15")
          sleep(20)
        checkpoint(name & ": " & result.outText & result.errText)
        check "{\"event\":\"meter.changed_event\",\"data\":{\"value\":150}}" in
          result.outText

      let first = c.streaming("sub1")
      check posix.kill(first.pid, SIGINT) == 0
      let firstExit = waitExit(first, StopMs)
      checkpoint("sub1 exit " & $firstExit & ": " & first.outText & first.errText)
      if firstExit != 130:
        checkpoint("logosd: " & d.errText)
      check firstExit == 130
      check first.errText == ""
      let after = c.lcn("call", "meter_module", "read", "channel=7")
      checkpoint after.stdout & after.stderr
      check after.code == 0
      # [plan §3.7] lcn_call ends the stream as logosd stops (6, not 130):
      # lcn_call stopping, or the meter's route ending first.
      let second = c.streaming("sub2")
      check d.stopped == 0
      let secondExit = waitExit(second, StopMs)
      checkpoint("sub2 exit " & $secondExit)
      check secondExit == 6
      checkpoint second.outText & second.errText
      check "\"status\":\"error\"" in second.outText
      check not entryExists(c.cliSocket)
      check hostsGone()

    test "[IMPL-DECISION G289] [IMPL-DECISION G350] kill -9 with lcn_call ready, then a restart: lcn_call comes back, resumed or recovered, and the next logosctl call succeeds":
      let c = newCase()
      check c.initCli().code == 0
      var d = c.start()
      c.expectReady(d)
      check c.startMeter().code == 0
      check c.ctl("module", "wait", "meter_module", "--instance", MeterInstance).code ==
        0
      check c.lcn("call", "meter_module", "read", "channel=7").code == 0
      check c.state(CliInstance) == "ready"
      killChild(d)
      d = c.start("logosd2")
      c.expectReady(d)
      # Both were restored as `error`, `host-terminated` (RUN-1194), with
      # requested intent: the orchestrator's first pass resumes them (G289),
      # and a command that comes first recovers lcn_call itself (DAEMON.md
      # §7a, Activation). Neither is `unloaded`: the intent was kept.
      check c.state(CliInstance) in ["error", "loaded", "ready"]
      check c.ctl("module", "wait", "meter_module", "--instance", MeterInstance).code ==
        0
      let b = c.lcn("call", "meter_module", "read", "channel=9")
      checkpoint b.stdout & b.stderr
      check b.code == 0
      if b.code == 0:
        check parseJson(b.stdout){"result", "label"}.getStr == "ch9"
      check c.state(CliInstance) == "ready"
      check d.stopped == 0
      check hostsGone()

    test "[IMPL-DECISION G342] [IMPL-DECISION G335] a thread-confined refc kit module in orc logosd's own process (direct_dynamic): its state on its module thread under concurrent calls, an async handler, its caller, stop and start again":
      if ledgerSkips:
        skip()
      else:
        ledgerCase(hosted = false)

    test "[IMPL-DECISION G342] [IMPL-DECISION G335] the same module realized by a Module Host (hosted_dynamic): the same calls, stop and start again, and no host left after logosd stops":
      if ledgerSkips:
        skip()
      else:
        ledgerCase(hosted = true)
else:
  import unittest2

  suite "daemon.logosd: logosd and logosctl as processes (POSIX only)":
    test "[IMPL] logosd and logosctl need unix-stream; on this platform both are stubs that exit 2":
      skip()
