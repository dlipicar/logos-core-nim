## logosd and logosctl as processes (Tier 4b step 4b-6; DECISIONS G88, G89,
## G296, G297, G299, G300, G302; docs/DAEMON.md): `init`, start, the status,
## shutdown by signal and by command, a restart after kill -9, the
## development switch and its banner, trust continuity, the offline writers'
## lock, concurrent shells, retirement, the socket path's limits, a Loader
## loss, and a key bound to another Runtime.
##
## The children are built for the suite's variant (`daemonbuild.nim`): logosd
## with test hooks, logosctl without. They run with `posix_spawn`, their
## output in files (`daemonproc.nim`). A sanitizer report makes a child exit
## non-zero, so every clean stop checks the exit code and prints the child's
## stderr when it is not 0.

import std/[json, monotimes, os, strutils, times]
import unittest2
import ../src/logos_core/cbor
import ../src/logos_core/crypto/blake3
import
  ../src/logos_core/daemon/
    [config, daemon_config_types, evkey, session, sessioninit, trust_types, trustfile]
from ../src/logos_core/daemon/supervise import heldLocks
from ../src/logos_core/iface/accept import acceptContractSet
from ../src/logos_core/durable import writeAtomic, removeIfPresent
import
  ./support/[daemonbuild, daemonproc, kitbuild, modulehostbuild, shortdir, slowdown]

when defined(posix):
  import std/posix

const
  ReadyMs = 20_000 * Slow
  StopMs = 10_000 * Slow
  HostsGoneMs = 10_000 * Slow
  SanitizerEnv =
    ["ASAN_OPTIONS", "LSAN_OPTIONS", "MSAN_OPTIONS", "TSAN_OPTIONS", "UBSAN_OPTIONS"]
    ## the Module Host's environment allow-list here: the sanitizers' settings
  ChatterLine = "chatter: beacon_module initialized in process "
    ## `tests/kit/chatter_impl.nim`'s line, which ends with the writer's pid
  ChatterInstance = "chatter-1"

let
  dExe = logosdProgram()
  ctlExe = logosctlProgram()
  sensorLib = buildKitLibrary("sensor_impl.nim", "lgdsensor")
  hostExe = moduleHostProgram()
  chatterLib = buildKitLibrary("chatter_impl.nim", "lgdchatter")
  beaconRoot = @(
    acceptContractSet(
      readFile(currentSourcePath().parentDir / "kit" / "beacon_module.cddl")
    )
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
  c.ctl(@["init", "--config", "@" & c.configFile(dc)] & @extra)

proc initDefault(c: Case): Ran =
  var dc = defaultDaemonConfig("assigned-by-init")
  dc.declarations = Opt.some(@[sensorDecl()])
  c.initWith(dc)

proc initHosted(c: Case, start: bool): Ran =
  ## The default configuration with the hosted `chatter-1`, which the
  ## orchestrator starts when `start` is set.
  var dc = defaultDaemonConfig("assigned-by-init")
  dc.declarations = Opt.some(@[sensorDecl()])
  dc.runtime.module_host = Opt.some(hostExe)
  dc.runtime.module_host_env = Opt.some(@SanitizerEnv)
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

proc start(c: Case, name = "logosd"): Child =
  result = spawnChild(dExe, ["--session-dir", c.s.dir], c.dir, name)
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
  let fd = posix.open(cstring(c.s.dir / "lock"), O_RDWR or O_CLOEXEC)
  if fd < 0:
    return true
  result = lockf(fd, F_TLOCK, 0) == 0
  discard posix.close(fd)

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

  test "daemon stop --wait: the daemon exits 0":
    let c = newCase()
    check c.initDefault().code == 0
    let d = c.start()
    c.expectReady(d)
    let r = c.ctl("daemon", "stop", "--wait")
    check r.code == 0
    check waitExit(d, StopMs) == 0

  test "[RUN-0347] kill -9, then a restart: the stale socket does not block, and module create --request-key returns the same instance":
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

  test "[BCP-0093] [BCP-0094] [BCP-0095] allow-all needs the switch; on, the banner shows in the log and in online and offline output; test_hooks needs it too":
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
        dc.test_hooks = Opt.some(LcnDcTestHooks(ctl_command_delay_ms: Opt.some(1'u32)))
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

  test "[PKG-0418] [PKG-0419] [PKG-0420] [PKG-0421] trust continuity across starts":
    let c = newCase()
    check c.initDefault().code == 0
    proc put(revision: uint64, development: bool) =
      check writeTrustFile(
        c.s, LcnTrustFile(revision: revision, development: development)
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

  test "offline writers are refused while logosd runs (exit 1); read-only offline commands work":
    let c = newCase()
    check c.initDefault().code == 0
    let d = c.start()
    c.expectReady(d)
    let w = c.ctl("trust", "development", "on")
    check w.code == 1
    check "another logosd or an offline logosctl command holds this session" in w.stderr
    check c.ctl("trust", "show").code == 0
    check c.ctl("daemon", "config", "get").code == 0
    check c.ctl("trust", "evidence-keys", "ls").code == 0
    check d.stopped == 0

  test "[RUN-0347] [BCP-0092] 8 concurrent shells, module create with distinct keys: 8 instances; retire says the state is kept":
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
    check c.lockFree

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

  test "[BCP-0036] [BCP-0049] [BCP-0050] a selected profile that fails (run/ep made unwritable): the hosted start fails, no Module Host runs and nothing realizes the module elsewhere; usable again, it starts":
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
    let c = newCase()
    check c.initHosted(start = true).code == 0
    check c.ctl("trust", "development", "on").code == 0
    c.editConfig(
      proc(dc: var LcnDaemonConfig) =
        dc.test_hooks = Opt.some(
          LcnDcTestHooks(loader_failure_after_ms: Opt.some(uint32(1_500 * Slow)))
        )
    )
    let d = c.start()
    check waitExit(d, ReadyMs + StopMs) == 4
    let log = d.errText
    checkpoint(log)
    check chatterPids(log).len == 1
    check "the Module Loader failed; termination required" in log
    check "exiting with 4" in log
    check "Module Host locks still held" notin log
    check hostsGone(2_000 * Slow)
    check heldLocks(c.s.workDir).len == 0
    check c.lockFree
