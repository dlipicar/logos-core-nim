## The harness of the suites that run `lcn_call` in a logosd in this process
## (Tier 5 step N-2; `test_lcn_call` and the erasure suite `test_wipe_cli`),
## included in their `when defined(posix)` block. The including suite defines
## `LivePrefix`, its short directories' prefix. Library paths follow the tests
## directory, not this file: `liveTree`.

import
  std/[
    algorithm, atomics, json, locks, monotimes, os, sequtils, strutils, tables, times,
    typedthreads,
  ]
import std/posix except Time
import unittest2
import logos_sdk/cbor
import logos_sdk/crypto/blake3
from logos_sdk/base/perthread import releasePerThread
from logos_sdk/base/wipe import ChannelsMove
from logos_sdk/iface/accept import acceptContractSet
import ../../src/logos_core/runtime/[engine, host], logos_sdk/kit/[rc_arms, rc_types]
from ../../src/logos_core/durable import DurableLock, release
from ../../src/logos_core/authority/scopes import sortSet
import
  ../../src/logos_core/daemon/
    [assemble, ctlwire, daemon_config_types, logging, session, sessioninit]
from ../../src/logos_core/daemon/config import CliInstance
from ../../src/logos_core/daemon/compose import cliSocketPath
import ../../src/logos_core/cli/[cli_types, launcher]
from ../../src/logos_core/cli/wire import writeRequest, readReply
from ../../src/logos_core/runtime/authscopes import caRoots, AuthorityModule
import logos_sdk/testing/testdirs
import ./[clibuild, modulehostbuild, shortdir, slowdown]

let liveTree = kitTreeOf(currentSourcePath().parentDir.parentDir / "test_lcn_call.nim")
  ## [kitbuild] the tests directory's tree, as a suite there would use

const
  Load = when compileOption("mm", "refc"): 4 else: 1
    ## [IMPL] `Slow` for a refc build of the whole stack. CI's refc jobs run
    ## the heaviest refc suites side by side: there test_lcn_call took 1207 s
    ## (x86_64) and 936 s (arm64) against 245 s under orc-release (run
    ## 44888184613), and its waits ran out; on the Mac refc takes 1.3 times
    ## orc's time. Like `Slow`, it multiplies only bounds, never a deadline a
    ## case is about. A shutdown takes 0.5 to 1.3 s on a loaded Mac.
  Patience = 60 * Slow * Load ## seconds a bounding wait allows
  Timeout = 30_000 * Slow * Load ## a command's, and a client's, wait, ms
  IdleMs = min(60_000 * Slow * Load, 600_000)
    ## `ctl.idle_timeout_ms` and `cli.idle_timeout_ms` where no case is about
    ## them (test_ctl_module's reason)
  RenewMarginMs = 5_000'i64
    ## [G348] lcn_call renews a route with less than this, or a tenth of its
    ## validity, left (routes.nim's own constant; L-10)
  StopDeadlineMs = 5_000 * Slow
    ## L-13's `stop_deadline_ms`: its provider ignores its cancellation, so
    ## its stop ends at this deadline
  StopBoundMs = Patience * 1000
    ## every other session's `stop_deadline_ms`, and every session's
    ## `shutdown_grace_ms`: a bound, since a stop past it is a cleanup timeout
    ## and the shutdown's result MODULE_ERROR (CI's refc and MSan runs went
    ## past 5 s and 15 s)
  HelloMs = Timeout
    ## `transport.hello_timeout_ms`: a hosted provider's Hello asks the
    ## Runtime about the ticket over the carrier (test_hosted_routes' `roomy`)
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
  meterLib = buildKitLibraryIn(liveTree, "meter_impl.nim", "lcmeter")
  shapesLib = buildKitLibraryIn(liveTree, "shapes_impl.nim", "lcshapes")
  vaultLib = buildKitLibraryIn(liveTree, "vault_impl.nim", "lcvault")
  bulkLib = buildKitLibraryIn(liveTree, "bulk_impl.nim", "lcbulk")
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
        artifact: LcnAppArtifact(id: instance, local_path: lib, hash: digestOfFile(lib))
      ),
    ),
  )
  if state.len > 0:
    result.state_assignment = Opt.some(state)

func cliSubject(): LcnApSubject =
  LcnApSubject(instances: Opt.some(@[CliInstance]))

proc accessTo(root: seq[byte], actions: openArray[LcnApActionKind]): LcnApScope =
  var xs: seq[LcnApAction]
  for a in actions:
    xs.add(LcnApAction(kind: a))
  sortSet(xs)
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

proc grant(root: seq[byte], actions: openArray[LcnApActionKind]): LcnApRule =
  ## [DAEMON.md §7a, "Grants"] An operator rule for `lcn_call` on one contract.
  LcnApRule(
    kind: LcnApRuleKind.lcn_Ap_allow,
    arm_lcn_Ap_allow:
      LcnApAllow(subject: cliSubject(), scopes: @[accessTo(root, actions)]),
  )

proc publishes(instance: string, root: seq[byte]): LcnApRule =
  ## [SPEC CA l.244-247] A delivery needs the provider's `publish-event` as
  ## well as the subscriber's `subscribe-event`: without it every
  ## publication is skipped, unseen by the stream.
  LcnApRule(
    kind: LcnApRuleKind.lcn_Ap_allow,
    arm_lcn_Ap_allow: LcnApAllow(
      subject: LcnApSubject(instances: Opt.some(@[instance])),
      scopes: @[accessTo(root, [LcnApActionKind.Publish_event])],
    ),
  )

proc selfIssue(root: seq[byte], actions: openArray[LcnApActionKind]): seq[LcnApRule] =
  ## [SPEC CA l.696-792] `lcn_call` may issue itself grants of `actions` on one
  ## contract, and revoke the grants it issued.
  @[
    LcnApRule(
      kind: LcnApRuleKind.lcn_Ap_issue,
      arm_lcn_Ap_issue: LcnApIssue(
        subject: cliSubject(),
        targets: LcnApTarget(kind: LcnApTargetKind.Self),
        scopes: @[accessTo(root, actions)],
      ),
    ),
    LcnApRule(
      kind: LcnApRuleKind.lcn_Ap_revoke,
      arm_lcn_Ap_revoke: LcnApRevoke(
        subject: cliSubject(), targets: LcnApTarget(kind: LcnApTargetKind.Issued)
      ),
    ),
  ]

const
  Full = [
    LcnApActionKind.Discover, LcnApActionKind.Establish_route,
    LcnApActionKind.Renew_route, LcnApActionKind.Call,
  ]
  Streaming = @Full & @[LcnApActionKind.Subscribe_event]

type Shape = object ## What a case changes in the session.
  workers: uint8 = 4
  routeIdleMs: int ## 0: the default
  validityMs: int ## 0: the default
  bulkDiscover: bool = true ## `discover` on bulk, and nothing else
  bulkStream: bool ## bulk granted as the meter is, its event included
  meterGrant: bool
    ## the meter's `subscribe-event` is not in its rule: `lcn_call` issues it
    ## itself (L-11), with the authority's methods granted
  stopDeadlineMs: int = StopBoundMs ## `stop_deadline_ms`
  providers: seq[string]
    ## [IMPL] the providers started at boot, of `Providers`; empty: all. A
    ## Module Host's start and stop are most of a boot's cost under a
    ## sanitizer, so a case starts only those it uses.

func started(shape: Shape): seq[string] =
  if shape.providers.len == 0:
    Providers
  else:
    shape.providers.filterIt(it in Providers)

var
  sessions = 0
  startedIn: Table[string, seq[string]] ## a session directory's `started`

proc newSession(shape = Shape()): Session =
  inc sessions
  let base = makeShortBase(
    LivePrefix & $sessions, deepest = "/s/run/ep/12345678/logos_shapes_module.sock"
  )
  createDir(base / "o")
  let s = Session(dir: base / "s")
  var dc = defaultDaemonConfig("assigned-by-init")
  dc.runtime.module_host = Opt.some(hostExe)
  dc.runtime.module_host_env = Opt.some(@SanitizerEnv)
  dc.runtime.stop_deadline_ms = Opt.some(uint32(shape.stopDeadlineMs))
  dc.runtime.shutdown_grace_ms = Opt.some(uint32(StopBoundMs))
  dc.transport = Opt.some(LcnAppTransport(hello_timeout_ms: Opt.some(uint32(HelloMs))))
  dc.modules = Opt.some(
    @[
      hosted(MeterInstance, "meter_module", meterRoot, meterLib, MeterState),
      hosted(ShapesInstance, "shapes_module", shapesRoot, shapesLib),
      hosted(VaultInstance, "vault_module", vaultRoot, vaultLib, "vault-state"),
      hosted(BulkInstance, "bulk_module", bulkRoot, bulkLib),
    ]
  )
  var o = dc.orchestration.get(LcnDcOrchestration())
  o.start = Opt.some(shape.started)
  startedIn[s.dir] = shape.started
  dc.orchestration = Opt.some(o)
  var rules = @[
    grant(shapesRoot, Full),
    grant(vaultRoot, Full),
    publishes(MeterInstance, meterRoot),
    publishes(BulkInstance, bulkRoot),
  ]
  if shape.meterGrant:
    rules.add(grant(meterRoot, Full))
    rules.add(grant(caRoots().contract, Full))
    rules.add(selfIssue(meterRoot, [LcnApActionKind.Subscribe_event]))
  else:
    rules.add(grant(meterRoot, Streaming))
  if shape.bulkStream:
    rules.add(grant(bulkRoot, Streaming))
  elif shape.bulkDiscover:
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
  shared: bool ## `sharedLive`'s, which the teardown keeps (`share`)
  last: bool ## the last case to share it: the teardown ends it

var
  live: ptr Live ## what the teardown ends, if a case left it running
  sharedLive: Live ## the session consecutive cases share (`share`)
  sharedShape: Shape

# What a case costs [IMPL]: one line per case, so a CI log shows where the
# suite's time goes.

type Cost = object ## The main thread's; commands run from other threads too.
  began: MonoTime
  boots, shutdowns: int
  bootMs, shutdownMs: int64

var
  cost: Cost
  costCommands, costCommandMs: Atomic[int64] ## `run`'s, from any thread

proc costBegin() =
  cost = Cost(began: getMonoTime())
  costCommands.store(0)
  costCommandMs.store(0)

proc msSince(t: MonoTime): int64 =
  inMilliseconds(getMonoTime() - t)

proc costLine(name: string): string =
  let at = name.find("L-")
  let tag =
    if at >= 0:
      name[at ..< max(at, name.find(':', at))]
    else:
      name
  "lcn_call cost " & tag & ": " & $msSince(cost.began) & " ms; " & $cost.boots & " boot " &
    $cost.bootMs & " ms, " & $cost.shutdowns & " shutdown " & $cost.shutdownMs & " ms, " &
    $costCommands.load & " commands " & $costCommandMs.load & " ms"

proc rc[Req](l: Live, m: LcnCtlMethodKind, req: Req): LcnCtlReply =
  let fd = connectCtl(l.d.socketPath, Timeout).expect("a connection")
  result = roundTrip(fd, rcMessage(m, req.encode.expect("an encoding")), Timeout).expect(
      "a reply"
    )
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
    LogosNSRuntimeControlStopModuleRequest(module: module, instance: Opt.some(instance)),
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

proc finish(l: var Live)

proc boot(s: Session): Live =
  ## Assembles and starts, then waits for the logosctl socket and the
  ## providers the session starts (DAEMON.md §4); `lcn_call` is not started.
  ## A shared session still up is ended first: one logosd at a time, since
  ## `finish` checks that no Module Host is left.
  if sharedLive.up:
    finish(sharedLive)
  let began = getMonoTime()
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
  for p in startedIn.getOrDefault(s.dir, Providers):
    doAssert result.reaches(p, LogosNSRuntimeControlStateKind.Ready),
      p & " is not ready; the log:\n" & logText()
  inc cost.boots
  cost.bootMs += msSince(began)

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
  let began = getMonoTime()
  discard runtimeRequestShutdown(l.d.rt)
  let down = runtimeWaitForShutdown(l.d.rt)
  let tookMs = inMilliseconds(getMonoTime() - began)
  if int64(down.code) != 0:
    # What overran, in a log that has nothing else to say it.
    checkpoint(
      "the shutdown took " & $tookMs & " ms: " &
        (if down.message.isNil: "" else: $down.message)
    )
  check int64(down.code) == 0
  check destroyRuntime(l.d).isOk
  l.d.release()
  l.lock.release()
  check hostsGone()
  check not fileExists(l.cli)
  inc cost.shutdowns
  cost.shutdownMs += msSince(began)

proc healthy(l: Live, shape: Shape): bool =
  ## What a passing case leaves for the next: the providers ready, and
  ## `lcn_call` ready or not started.
  l.up and shape.started.allIt(l.state(it) == LogosNSRuntimeControlStateKind.Ready) and
    l.state(CliInstance) in
    [LogosNSRuntimeControlStateKind.Ready, LogosNSRuntimeControlStateKind.Unloaded]

proc share(shape = Shape(), last = false): Live =
  ## [IMPL] The session consecutive cases of one shape share, with its
  ## `lcn_call` and routes: booted by the first, kept while each case passes
  ## and leaves it healthy, ended by the `last` one or a failed case (the
  ## teardown) or another shape. A boot, a shutdown and `lcn_call`'s start
  ## are most of a case's cost under a sanitizer; none of these cases is
  ## about them.
  if sharedLive.up and (sharedShape != shape or not sharedLive.healthy(shape)):
    finish(sharedLive)
  if not sharedLive.up:
    sharedLive = boot(newSession(shape))
    sharedShape = shape
  result = sharedLive
  result.shared = true
  result.last = last

proc release(l: var Live, failed: bool) =
  ## The teardown's end of a case's session: a shared one is kept for the
  ## next case unless this was the last or failed.
  if not l.up:
    return
  if l.shared:
    if failed or l.last:
      finish(sharedLive)
    l.up = false
  else:
    finish(l)

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
    files: seq[cint] = @[],
    deadlineMs = 0,
): Ran =
  ## `files` are the `@FILE` descriptors, in the order `fileArg`'s `fd`
  ## indexes them (2 is the first); `run` closes them. `deadlineMs` > 0 is the
  ## message's `deadline_ms`.
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
  if deadlineMs > 0:
    msg.deadline_ms = Opt.some(uint32(deadlineMs))
  let began = getMonoTime()
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
      files: files,
    )
  )
  discard costCommands.fetchAdd(1)
  discard costCommandMs.fetchAdd(msSince(began))
  discard posix.close(ofd)
  discard posix.close(efd)
  for f in files:
    discard posix.close(f)
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
  "exit " & $r.exit & "; stdout: " & r.output & "; stderr: " & r.errors & "; launcher: " &
    r.failure

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

func fileArg(name: string, index: int): LcnCliArg =
  ## `name=@FILE` for the message's descriptor `index` (2: the first file).
  LcnCliArg(
    kind: LcnCliArgKind.lcn_Cli_file_arg,
    arm_lcn_Cli_file_arg: LcnCliFileArg(name: name, fd: uint8(index)),
  )

func callWith(module, meth: string, args: seq[LcnCliArg]): LcnCliCommand =
  LcnCliCommand(
    kind: LcnCliCommandKind.lcn_Cli_call_command,
    arm_lcn_Cli_call_command: LcnCliCallCommand(
      `method`: meth, provider: providerOf(module), args: Opt.some(args)
    ),
  )

proc inFile(l: Live, data: string): cint =
  ## A file holding `data`, open for reading.
  let p = l.outDir / ("i" & $outputs.fetchAdd(1))
  writeFile(p, data)
  let fd = posix.open(cstring(p), O_RDONLY or O_CLOEXEC)
  doAssert fd >= 0, p & ": " & $strerror(errno)
  fd

func describeOf(module: string): LcnCliCommand =
  LcnCliCommand(
    kind: LcnCliCommandKind.lcn_Cli_describe_command,
    arm_lcn_Cli_describe_command: LcnCliDescribeCommand(provider: providerOf(module)),
  )

func meterRead(channel: int): LcnCliCommand =
  callOf("meter_module", "read", [("channel", $channel)])

func subscribeOf(module, event: string, count = 0, forMs = 0): LcnCliCommand =
  var c = LcnCliSubscribeCommand(provider: providerOf(module), event: event)
  if count > 0:
    c.count = Opt.some(uint32(count))
  if forMs > 0:
    c.for_ms = Opt.some(uint32(forMs))
  LcnCliCommand(
    kind: LcnCliCommandKind.lcn_Cli_subscribe_command, arm_lcn_Cli_subscribe_command: c
  )

func eventsOf(names: openArray[string] = [], count = 0): LcnCliCommand =
  var c = LcnCliEventsCommand()
  if names.len > 0:
    c.names = Opt.some(@names)
  if count > 0:
    c.count = Opt.some(uint32(count))
  LcnCliCommand(
    kind: LcnCliCommandKind.lcn_Cli_events_command, arm_lcn_Cli_events_command: c
  )

proc restart(l: Live, module, instance: string) =
  l.stop(module, instance)
  discard l.reaches(instance, LogosNSRuntimeControlStateKind.Unloaded)
  l.start(module, instance)
  discard l.reaches(instance, LogosNSRuntimeControlStateKind.Ready)

proc sendBulk(l: Live, size: int) =
  ## bulk's `send` publishes `bulk.carried_event` with `size` bytes.
  discard l.run(callOf("bulk_module", "send", [("size", $size)]))

proc publish(l: Live) =
  ## Channel 15: the meter publishes `meter.changed_event` (value 150).
  let r = l.run(meterRead(15))
  checkpoint r.said
  check r.exit == 0

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

proc nowWallMs(): int64 =
  ## The wall clock in ms, as a route record's `expires_at` counts it.
  let t = getTime()
  t.toUnix * 1000 + int64(t.nanosecond div 1_000_000)

proc callsUntil(l: Live, until: int64, idleMs: int, cost: var int64) =
  ## [IMPL] Commands keep `l`'s meter route in use until the wall clock reaches
  ## `until` (ms), then return. Each gap is a third of `idleMs`; the last is
  ## cut so the next command can start at `until`, leaving room for `cost`, the
  ## longest command so far. So no gap reaches `idleMs` while a command costs
  ## less than two thirds of it, and one that costs no more than `cost` ends
  ## before `until`.
  while true:
    let left = until - nowWallMs()
    if left <= idleMs div 3 + cost:
      sleep(int(max(left, 0)))
      return
    sleep(idleMs div 3)
    let began = getMonoTime()
    let r = l.run(meterRead(7))
    checkpoint r.said
    check r.exit == 0
    cost = max(cost, msSince(began))

proc otherUid(fd: cint): Result[Peer, string] {.nimcall, gcsafe, raises: [].} =
  let p = ?peerOf(fd)
  ok(Peer(uid: p.uid + 1, pid: p.pid))

# A stream, from a thread of its own -----------------------------------------------------

type Watch = object ## One stream the launcher runs.
  thread: Thread[(ptr Live, ptr Watch)]
  msg: LcnCliMessage
  outPath, errPath: string ## `outPath` empty: stdout is `stalled`'s pipe
  outFd, errFd: cint ## the launcher's stdout and stderr
  stalled: cint ## the read end of a stdout pipe nothing reads; -1: none
  cancelR, cancelW: cint ## the launcher's cancel
  exit: Atomic[int] ## -1 while it runs

var
  watch: Watch
  watching: bool ## `watch.thread` runs and is not joined yet

proc streamed(arg: (ptr Live, ptr Watch)) {.thread.} =
  let (lp, w) = arg
  let r = launch(
    Launch(
      cliSocket: lp.cli,
      ctlSocket: lp.d.socketPath,
      message: w.msg,
      stdoutFd: w.outFd,
      stderrFd: w.errFd,
      timeoutMs: Timeout,
      cancelFd: w.cancelR,
    )
  )
  w.exit.store(if r.isOk: r.get else: r.error.exit)
  releasePerThread()

proc cloexecPipe(): (cint, cint) =
  var p: array[2, cint]
  doAssert posix.pipe(p) == 0, $strerror(errno)
  for fd in p:
    discard fcntl(fd, F_SETFD, FD_CLOEXEC)
  (p[0], p[1])

proc stream(l: var Live, cmd: LcnCliCommand, text = false, stalled = false) =
  ## Starts `cmd`; with `stalled` its stdout is a pipe nothing reads.
  watch.msg = LcnCliMessage(
    command: cmd,
    output:
      if text:
        LcnCliOutput(kind: LcnCliOutputKind.Text)
      else:
        LcnCliOutput(kind: LcnCliOutputKind.Json),
  )
  if stalled:
    (watch.stalled, watch.outFd) = cloexecPipe()
    watch.outPath = ""
  else:
    watch.stalled = -1
    (watch.outPath, watch.outFd) = outFile(l.outDir)
  (watch.errPath, watch.errFd) = outFile(l.outDir)
  (watch.cancelR, watch.cancelW) = cloexecPipe()
  watch.exit.store(-1)
  createThread(watch.thread, streamed, (addr l, addr watch))
  watching = true

proc streamEnded(): bool =
  watch.exit.load >= 0

proc interrupt() =
  ## What logosctl does at SIGINT: its cancel descriptor becomes readable.
  var b = [byte(1)]
  discard posix.write(watch.cancelW, addr b[0], 1)

proc streamOutput(): string =
  if watch.outPath.len > 0:
    try:
      return readFile(watch.outPath)
    except IOError:
      discard

proc streamErrors(): string =
  try:
    readFile(watch.errPath)
  except IOError:
    ""

proc streamLines(): seq[JsonNode] =
  ## Every JSON line on stdout so far (a line still being written is left).
  let o = streamOutput()
  let whole = o.rfind('\n')
  if whole < 0:
    return
  for line in o[0 ..< whole].splitLines:
    if line.len > 0:
      try:
        result.add(parseJson(line))
      except CatchableError as e:
        checkpoint("not JSON: " & line & ": " & e.msg)

func eventsIn(lines: seq[JsonNode]): seq[JsonNode] =
  lines.filterIt(it.hasKey("event"))

proc saidStream(): string =
  "exit " & $watch.exit.load & "; stdout: " & streamOutput() & "; stderr: " &
    streamErrors()

template within(cond: untyped, act: untyped): bool =
  ## Does `act` until `cond`, at most `Patience` seconds.
  let until = getMonoTime() + initDuration(seconds = Patience)
  var met = cond
  while not met and getMonoTime() < until:
    act
    sleep(20)
    met = cond
  met

proc endStream(): int =
  ## Waits for the stream's end, at most `Patience`; its exit status. A
  ## stream still running then fails the case and is cancelled as logosctl's
  ## SIGINT would; one that outlives its cancel too ends the suite, since a
  ## join that never returns would hold the run, and the validation queue
  ## it waits in, until someone kills it.
  if watching:
    if not within(streamEnded(), sleep(10)):
      checkpoint("the stream did not end: " & saidStream())
      fail()
      interrupt()
      if not within(streamEnded(), sleep(10)):
        try:
          stderr.writeLine(
            "test_lcn_call: a stream outlived its cancel; the suite stops: " &
              saidStream()
          )
        except IOError:
          discard
        quit(QuitFailure)
    joinThread(watch.thread)
    watching = false
    for fd in [watch.outFd, watch.errFd, watch.stalled, watch.cancelR, watch.cancelW]:
      if fd >= 0:
        discard posix.close(fd)
  watch.exit.load

proc addressOf(l: Live, instance: string): JsonNode =
  %*{
    "module_instance_id": instance,
    "runtime_instance_id": l.d.prepared.config.value.runtime.runtime_instance_id,
  }

func commitmentOf(root: seq[byte]): JsonNode =
  ## A `logos.schema_commitment`, as G89 writes it.
  %*{
    "commitment_model": "logos.commitment-model.2026-10",
    "schema_root": hexOf(root),
    "hash_profile": "logos.hash-profile.2026-08.choice-index",
    "hash_suite": "logos.hash-suite.blake3-256",
  }
