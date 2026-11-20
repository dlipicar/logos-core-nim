## logosd and logosctl as processes (Tier 4b step 4b-6; DECISIONS G88, G89,
## G296, G297, G299, G300, G302; docs/DAEMON.md): `init`, start, the status,
## shutdown by signal and by command, a restart after kill -9, the
## development switch and its banner, trust continuity, the trust anchor
## commands and their refusals (G397), the offline writers' lock, concurrent
## shells, retirement, the socket path's limits, a Loader loss, a key bound to
## another Runtime, and the call-evidence store's commands.
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
  from ../src/logos_core/authority/scopes import encode
  from ../src/logos_core/daemon/supervise import heldLocks
  from ../src/logos_core/runtime/plumbing import MaxDiagnostics
  from logos_sdk/iface/accept import acceptContractSet
  from ../src/logos_core/durable import
    acquire, ensurePrivateDir, release, removeIfPresent, writeAtomic
  import
    ./support/[daemonbuild, daemonproc, evfixture, modulehostbuild, shortdir, slowdown],
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

  proc chatterLogged(d: Child, count: int): seq[int] =
    ## The chatter pids in `d`'s log once there are `count`, or what there is
    ## after `ReadyMs`.
    let until = getMonoTime() + initDuration(milliseconds = ReadyMs)
    result = chatterPids(d.errText)
    while result.len < count and getMonoTime() < until:
      sleep(20)
      result = chatterPids(d.errText)

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

    test "[PKG-0418] [PKG-0419] [PKG-0420] [PKG-0421] trust continuity across starts, with an anchor in the file":
      let c = newCase()
      check c.initDefault().code == 0
      proc put(revision: uint64, development: bool) =
        let anchor = LcnTrustAnchor(
          kid: @[byte 1], public_key: newSeq[byte](48), packages: @["logos.storage"]
        )
        check writeTrustFile(
          c.s,
          LcnPackageTrust(
            revision: revision,
            development: development,
            signing: LcnTrustSigning(anchors: @[anchor]),
          ),
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

    test "[PKG-0418] [TXT-0463] [IMPL-DECISION G397] logosctl trust anchor and development: each change writes revision + 1, one added name included, and logosd starts with it; a change that changes nothing writes nothing and exits 0; a Tier 4b v1 session upgrades by its first change":
      let c = newCase()
      check c.initDefault().code == 0
      # A Tier 4b session: the v1 file and the mark of its bytes.
      let v1 = LcnTrustFile(revision: 1, development: false).encode.expect("v1")
      check writeAtomic(c.s.dir, TrustName, v1).isOk
      check writeMark(c.s, TrustFileState(file: floorTrust(), digest: @(blake3(v1)))).isOk
      let key = repeat("ab", 48)
      proc wrote(args: varargs[string]): JsonNode =
        let (code, j) = c.ctlJson(@["trust"] & @args)
        check code == 0
        if code != 0:
          checkpoint($j)
          return newJObject()
        j["result"]

      var r = wrote("anchor", "add", "--kid", "org", "--key", key, "logos.storage")
      check r{"revision"}.getInt == 2 and r{"changed"}.getBool
      check r{"kid"}.getStr == "6f7267"
      # A hex kid, the key in lcn-pkg keygen's line, a development anchor.
      writeFile(c.dir / "dev.pub", "public key: " & repeat("cd", 48) & "\n")
      r = wrote(
        "anchor",
        "add",
        "--kid",
        "hex:6465",
        "--key",
        "@" & c.dir / "dev.pub",
        "--development",
        "logos.example",
      )
      check r{"revision"}.getInt == 3
      # One added name is a new revision (PM l.420).
      r = wrote("anchor", "add-names", "--kid", "org", "logos.wallet")
      check r{"revision"}.getInt == 4 and r{"changed"}.getBool
      # A change that changes nothing writes nothing.
      let before = digestOfFile(c.s.trustPath)
      for args in [
        @["anchor", "add-names", "--kid", "org", "logos.wallet"],
        @["anchor", "remove-names", "--kid", "org", "logos.chat"],
        @["anchor", "remove", "--kid", "none"],
        @[
          "anchor", "add", "--kid", "org", "--key", key, "logos.storage", "logos.wallet"
        ],
        @["development", "off"],
      ]:
        checkpoint(args.join(" "))
        r = wrote(args)
        check r{"revision"}.getInt == 4 and not r{"changed"}.getBool
      check digestOfFile(c.s.trustPath) == before
      check "unchanged at trust revision 4" in
        c.ctl("trust", "development", "off").stdout
      check "unchanged at trust revision 4: no anchor has kid 6e6f6e65; nothing was written" in
        c.ctl("trust", "anchor", "remove", "--kid", "none").stdout
      let on = c.ctl("trust", "development", "on")
      check on.code == 0
      check "trust revision 5: development switch on, 1 development anchor enters force" in
        on.stdout
      let again = c.ctl("trust", "development", "on")
      check again.code == 0 and "unchanged at trust revision 5" in again.stdout
      let written = readFile(c.s.trustPath)
      check decodeCbor(written.toOpenArrayByte(0, written.high)).get
        .lookup("format").get.getText == Opt.some(TrustFormat)
      # logosd starts with it, without re-establishment: the mark moves to 5.
      let d = c.start()
      c.expectReady(d)
      check readMark(c.s).expect("the mark").get.revision == 5
      check d.stopped == 0
      let shown = c.ctl("trust", "show")
      check shown.code == 0
      check "NON-PRODUCTION" in shown.stdout
      check "accepted (the revision in use)" in shown.stdout
      check "2 (2 in force)" in shown.stdout
      check "\"logos.storage\" \"logos.wallet\"" in shown.stdout
      let (sc, sj) = c.ctlJson("trust", "show")
      check sc == 0
      check sj["deployment"].getStr == "non-production"
      let anchors = sj["result"]["signing"]["anchors"]
      check anchors.len == 2
      check anchors[0]["kid"].getStr == "6465" and anchors[0]["kid_text"].getStr == "de"
      check anchors[0]["development"].getBool and anchors[0]["in_force"].getBool
      check anchors[1]["kid_text"].getStr == "org"
      check anchors[1]["packages"] == %["logos.storage", "logos.wallet"]
      check anchors[1]["public_key"].getStr == key
      check sj["result"]["provenance"] == newJObject()
      check not sj["result"].hasKey("refused")
      # Off again: the development anchor leaves force.
      check "1 development anchor leaves force" in
        c.ctl("trust", "development", "off").stdout

    test "[PKG-0435] [PKG-0169] [IMPL-DECISION G398] [IMPL-DECISION G397] logosctl trust refusals exit 1 and write nothing; on a file logosd refuses, trust show prints the reason, every writer says to correct the file and trust reestablish writes no mark":
      let c = newCase()
      check c.initDefault().code == 0
      let key = repeat("ab", 48)
      check c.ctl(
        "trust", "anchor", "add", "--kid", "org", "--key", key, "logos.storage"
      ).code == 0
      let (_, keys) = c.ctlJson("trust", "evidence-keys", "ls")
      let evidence = keys["result"]["keys"][0]["public_key"].getStr
      let before = digestOfFile(c.s.trustPath)
      for (args, says) in [
        (
          @["anchor", "add", "--kid", "org", "--key", repeat("cd", 48), "logos.storage"],
          "is already an anchor",
        ),
        (
          @["anchor", "add", "--kid", "new", "--key", repeat("ab", 47), "x"],
          "96 hex digits",
        ),
        (
          @["anchor", "add", "--kid", "new", "--key", evidence, "x"],
          "is a call-evidence key of this session",
        ),
        (
          @["anchor", "add", "--kid", "new", "--key", key, repeat("n", 129)],
          "1 to 128 bytes",
        ),
        (@["anchor", "add", "--kid", "hex:6", "--key", key, "x"], "--kid hex:"),
        (@["anchor", "add", "--kid", "new", "--key", key], "needs at least one NAME"),
        (@["anchor", "add-names", "--kid", "dev", "x"], "no anchor has kid"),
        (
          @["anchor", "remove-names", "--kid", "org", "logos.storage"],
          "trust anchor remove withdraws the anchor",
        ),
      ]:
        checkpoint(args.join(" "))
        let r = c.ctl(@["trust"] & args)
        check r.code == 1 and says in r.stderr
      check digestOfFile(c.s.trustPath) == before
      # A provenance profile selected by hand, at the next revision.
      var f = readTrust(c.s).expect("the file").file
      f.revision = 3
      f.provenance.selected = Opt.some("logos.package-provenance.slsa-v1.2")
      check writeTrustFile(c.s, f).isOk
      let selected = digestOfFile(c.s.trustPath)
      let shown = c.ctl("trust", "show")
      check shown.code == 0
      check "selects \"logos.package-provenance.slsa-v1.2\"" in shown.stdout
      check "supports no provenance profile" in shown.stdout
      let (sc, sj) = c.ctlJson("trust", "show")
      check sc == 0
      check "supports no provenance profile" in sj["result"]["refused"].getStr
      check sj["result"]["provenance"]["selected"].getStr ==
        "logos.package-provenance.slsa-v1.2"
      for args in [
        @["development", "on"],
        @["development", "off"],
        @["anchor", "add-names", "--kid", "org", "logos.chat"],
      ]:
        checkpoint(args.join(" "))
        let r = c.ctl(@["trust"] & args)
        check r.code == 1
        check "supports no provenance profile" in r.stderr
        check "correct trust.cbor by hand" in r.stderr
      check digestOfFile(c.s.trustPath) == selected
      let mark = readMark(c.s).expect("the mark").get
      let re = c.ctl("trust", "reestablish", "--revision", "3")
      check re.code == 1 and "no mark was written" in re.stderr
      check readMark(c.s).expect("the mark").get == mark
      # logosd refuses it too, naming the profile, and the mark stays.
      let d = c.start()
      check waitExit(d, ReadyMs) == 1
      check "supports no provenance profile" in d.errText
      check readMark(c.s).expect("the mark").get == mark

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
else:
  import unittest2

  suite "daemon.logosd: logosd and logosctl as processes (POSIX only)":
    test "[IMPL] logosd and logosctl need unix-stream; on this platform both are stubs that exit 2":
      skip()
