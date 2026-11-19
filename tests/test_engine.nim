## The Runtime engine's registry and lifecycle for direct realization
## (`runtime/engine.nim`): resolved records (RUNTIME §8), module states and
## the startup deadline (§3.4), contract checks (§3.3, §3.6), lifecycle
## ordering (§3.7), concurrent lifecycle requests (§9.1), start_module,
## stop_module and report_failure (§9.3), failure classifications, the
## authorizer at its check points [G52, G168], and shutdown (§10.2).
##
## The modules are the meter kit module and a hand-written consumer whose
## `_MODULE_init` and `_MODULE_destroy` can be held at a gate, so a test can
## order a stop, a report or a deadline against module code that is still
## running. Module code runs on the engine's worker threads, so the test
## module keeps its state in atomics.

import std/[atomics, monotimes, os, strutils, times, typedthreads]
import unittest2
import ../src/logos_core/runtime/engine
import ../src/logos_core/loader/contract
import logos_sdk/abi/types
import logos_sdk/iface/[accept, names, outcome]
import logos_sdk/crypto/blake3
import ../src/logos_core/package/manifest
import logos_sdk/pins
import logos_sdk/testing/[kitbuild, kitruntime], ./support/[slowdown, withoutloader]
import logos_sdk/testing/fixtures/meter_impl

let work = currentSourcePath().parentDir.parentDir / "build" / "engine" / kitVariant
removeDir(work)
createDir(work)

# The gated consumer -------------------------------------------------------------

type GateMode = enum
  gmOk ## LOGOS_OK and a context
  gmOkNull ## LOGOS_OK without a context
  gmFail ## MODULE_ERROR with no context
  gmFailContext ## MODULE_ERROR, and `failedContext` written out (INTERFACE l.1631)

var
  mode: Atomic[int]
  initGate, destroyGate: Atomic[bool] ## true while closed
  inits, destroys, live: Atomic[int]
  failedContext: int ## its address is the context a failing init writes out

proc gatedName(): cstring {.cdecl.} =
  "gated_consumer"

proc gatedInit(
    input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
): LogosResult {.cdecl.} =
  inits.atomicInc
  while initGate.load:
    sleep(1)
  case GateMode(mode.load)
  of gmOk:
    outContext[] = cast[ptr LogosModuleContext](allocShared0(16))
    live.atomicInc
  of gmOkNull:
    discard
  of gmFail:
    result.code = CErrorCode(ord(ecModule))
    result.message = "cannot start"
  of gmFailContext:
    outContext[] = cast[ptr LogosModuleContext](addr failedContext)
    result.code = CErrorCode(ord(ecModule))
    result.message = "cannot start"

proc gatedDestroy(module: ptr LogosModuleContext) {.cdecl.} =
  if module == cast[ptr LogosModuleContext](addr failedContext):
    inc failedContext # never freed: the module owns it
    destroys.atomicInc
    return
  while destroyGate.load:
    sleep(1)
  deallocShared(module)
  live.atomicDec
  destroys.atomicInc

proc gatedTable(): seq[(string, pointer)] =
  @[
    ("logos_gated_consumer_MODULE_name", cast[pointer](gatedName)),
    ("logos_gated_consumer_MODULE_init", cast[pointer](gatedInit)),
    ("logos_gated_consumer_MODULE_destroy", cast[pointer](gatedDestroy)),
  ]

proc reset() =
  mode.store(ord(gmOk))
  initGate.store(false)
  destroyGate.store(false)
  inits.store(0)
  destroys.store(0)
  live.store(0)

# Engine set-up ----------------------------------------------------------------------

var engines = 0

proc config(policy = allowAll()): EngineConfig =
  inc engines
  result = defaultConfig(work / ("e" & $engines))
  result.stateRoot = Opt.some(work / ("e" & $engines) / "state")
  result.policy = policy
  result.statics = @[
    checkStaticRegistration("gated", gatedTable()).tryGet,
    checkStaticRegistration("meter", meterModuleStaticSymbols()).tryGet,
  ]

proc meterRoot(): Digest =
  let reg = checkStaticRegistration("meter", meterModuleStaticSymbols()).tryGet
  let b = bindNative(ModuleCode(kind: codeStatic, table: reg.symbols), "meter_module")
  b.tryGet.contracts.primary.get.root

func gated(state = Opt.none(string)): ModuleRecord =
  ModuleRecord(
    module: "gated_consumer",
    strategy: stDirectStatic,
    binding: "gated",
    stateAssignment: state,
  )

func meter(primary = Opt.none(Digest), implements: seq[Digest] = @[]): ModuleRecord =
  ModuleRecord(
    module: "meter_module",
    strategy: stDirectStatic,
    binding: "meter",
    primaryContract: primary,
    implements: implements,
  )

proc finish(e: Engine) =
  initGate.store(false)
  destroyGate.store(false)
  e.shutdown()
  check e.close()

proc waitUntil(cond: proc(): bool {.closure.}, seconds = 10): bool =
  let until = getMonoTime() + initDuration(seconds = seconds)
  while getMonoTime() < until:
    if cond():
      return true
    sleep(2)
  cond()

proc failureOf(v: InstanceView): string =
  if v.failure.isSome: v.failure.get.classification else: ""

func failureRuleHolds(v: InstanceView): bool =
  ## [SPEC RUNTIME l.3611, l.3613; P5a §0.2 item 4] `error` has a failure;
  ## `loaded` and `ready` have none; `stopping` has none, the classification
  ## it kept from `error`, or `cleanup-timeout`; `unloaded` has none or the
  ## cause that prevents its intent (an enforcement outcome).
  case v.state
  of msError:
    v.failure.isSome
  of msLoaded, msReady:
    v.failure.isNone
  of msStopping:
    true
  of msUnloaded:
    v.failure.isNone or
      v.failure.get.kind in {
        fkAuthorityDenied, fkAuthorityEvaluationFailed, fkAuthorityExpired,
        fkAuthorityRevoked, fkPermissionEnforcementFailed,
      }

proc statesSince(e: Engine, instance: string, serial: uint64): seq[ModuleState] =
  ## The states `instance` committed after the change `serial`, in order.
  for c in e.changes():
    if c.serial > serial and c.view.instance == instance:
      result.add(c.view.state)

# Calls on other threads -------------------------------------------------------------

var
  started: Atomic[int] ## the resulting state's ordinal, or -1 for an error
  stopped: Atomic[int] ## the same, for `stopOn`

proc startOn(arg: (Engine, string)) {.thread.} =
  let r = arg[0].start(arg[1])
  started.store(
    if r.isOk:
      ord(r.get.state)
    else:
      -1
  )

proc stopOn(arg: (Engine, string)) {.thread.} =
  let r = arg[0].stop(arg[1])
  stopped.store(
    if r.isOk:
      ord(r.get.state)
    else:
      -1
  )

suite "run.engine: records (RUNTIME §8, §9.3 create)":
  setup:
    reset()

  test "[RUN-0128] [RUN-0261] [RUN-0262] [RUN-0267] [RUN-0268] [RUN-0281] [RUN-0287] [RUN-0289] [RUN-0845] a malformed record creates nothing":
    let e = newEngine(config())
    let d = default(Digest)
    var bad = @[
      ModuleRecord(module: "Bad Name", strategy: stDirectStatic, binding: "gated"),
      ModuleRecord(module: "gated_consumer", strategy: stDirectStatic, binding: ""),
      ModuleRecord(module: "gated_consumer", strategy: stHostedDynamic),
    ]
    var twice = gated()
    twice.implements = @[d, d]
    bad.add(twice)
    var dynamicRecord =
      ModuleRecord(module: "gated_consumer", strategy: stDirectDynamic)
    dynamicRecord.artifact =
      ArtifactRecord(id: "a", localPath: "/x.so", hashSuite: "unknown-suite")
    bad.add(dynamicRecord)
    var perms = gated()
    perms.requestedPermissions = @[
      RequestedPermission(permission: "p", constraints: @[0xF6'u8]),
      RequestedPermission(permission: "p", constraints: @[0xF6'u8]),
    ]
    bad.add(perms)
    var cbor = gated()
    cbor.requestedPermissions =
      @[RequestedPermission(permission: "p", constraints: @[0x18'u8, 0x01])]
    bad.add(cbor)
    var configured = gated()
    # [RUN-0259] A binding no accepted declaration came with.
    configured.configuration = Opt.some(default(Digest))
    bad.add(configured)
    for r in bad:
      let x = e.create(r)
      check x.isErr and x.error.code == ecInvalidParams
    check e.list().withoutLoader.len == 0
    e.finish()

  test "[RUN-0010] [RUN-0659] [RUN-0270] [RUN-0272] [RUN-0487] a new instance is unloaded, with intent uninitialized and its own state assignment":
    let e = newEngine(config())
    let v = e.create(gated(Opt.some("s1")), "g1").tryGet
    check v.instance == "g1" and v.module == "gated_consumer"
    check v.state == msUnloaded and v.failure.isNone
    check v.execution.intent == inUninitialized and v.execution.intentRevision.isNone
    check v.execution.revision >= 1
    check e.create(gated(Opt.some("s1")), "g2").error.code == ecInvalidParams
    check e.create(gated(), "g1").error.code == ecInvalidParams
    let fresh = e.create(gated()).tryGet
    check fresh.instance.len > 0 and fresh.instance != "g1"
    check e.list().withoutLoader.len == 2
    e.finish()

suite "run.engine: start and stop (RUNTIME §3.4, §9.1, §9.3)":
  setup:
    reset()

  test "[RUN-0667] [RUN-0629] [RUN-1183] [RUN-0355] [RUN-0669] [TXT-0279] start makes the instance ready; a repeated start changes nothing":
    let e = newEngine(config())
    let c = e.create(gated(), "g").tryGet
    let v = e.start("g").tryGet
    check v.state == msReady and v.failure.isNone and not v.provider
    check v.execution.intent == inRequested and v.intentOrigin.host
    check v.execution.intentRevision.isSome
    check v.execution.revision > c.execution.revision
    check inits.load == 1 and live.load == 1
    let again = e.start("g").tryGet
    check again.state == msReady and again.execution == v.execution
    check inits.load == 1
    e.finish()
    check live.load == 0

  test "[RUN-0357] [RUN-0356] [RUN-1030] [TXT-0282] [TXT-0284] stop destroys the context once and cancels intent; a later start makes a new context":
    let e = newEngine(config())
    discard e.create(gated(), "g").tryGet
    discard e.start("g").tryGet
    let s = e.stop("g").tryGet
    check s.state == msUnloaded and s.failure.isNone
    check s.execution.intent == inStopped and s.execution.intentRevision.isNone
    check destroys.load == 1 and live.load == 0
    let again = e.stop("g").tryGet
    check again.state == msUnloaded and destroys.load == 1
    let r = e.start("g").tryGet
    check r.state == msReady and inits.load == 2 and live.load == 1
    e.finish()

  test "[RUN-0354] concurrent starts make one realization":
    let e = newEngine(config())
    discard e.create(gated(), "g").tryGet
    initGate.store(true)
    var threads: array[6, Thread[(Engine, string)]]
    for t in threads.mitems:
      createThread(t, startOn, (e, "g"))
    check waitUntil(
      proc(): bool =
        inits.load == 1
    )
    sleep(20)
    initGate.store(false)
    joinThreads(threads)
    check inits.load == 1 and live.load == 1
    check e.view("g").tryGet.state == msReady
    e.finish()

  test "[RUN-0358] [RUN-0796] [TXT-0281] [RUN-1092] [TXT-0290] a stop ordered after an incomplete start keeps it from becoming ready":
    var cfg = config()
    cfg.stopDeadline = initDuration(milliseconds = 100)
    let e = newEngine(cfg)
    discard e.create(gated(), "g").tryGet
    initGate.store(true)
    var t: Thread[(Engine, string)]
    started.store(-2)
    createThread(t, startOn, (e, "g"))
    check waitUntil(
      proc(): bool =
        inits.load == 1
    )
    # [SPEC RUNTIME l.575] `_MODULE_init` outlives the stop deadline: still
    # `stopping`, `cleanup-timeout` reported, nothing interrupted.
    let s = e.stop("g").tryGet
    check s.state == msStopping and s.failureOf == "cleanup-timeout"
    check s.execution.intent == inStopped
    joinThread(t)
    check started.load == ord(msStopping)
    initGate.store(false)
    # [SPEC RUNTIME l.576] The pending cleanup completes the stop.
    check waitUntil(
      proc(): bool =
        destroys.load == 1 and live.load == 0 and e.view("g").tryGet.state == msUnloaded
    )
    check e.view("g").tryGet.failure.isNone
    e.finish()

  test "[RUN-0359] a start ordered while the instance is stopping fails":
    var cfg = config()
    cfg.stopDeadline = initDuration(seconds = 30) # the stop never waits this long
    let e = newEngine(cfg)
    discard e.create(gated(), "g").tryGet
    discard e.start("g").tryGet
    destroyGate.store(true)
    var t: Thread[(Engine, string)]
    stopped.store(-2)
    createThread(t, stopOn, (e, "g"))
    check waitUntil(
      proc(): bool =
        e.view("g").tryGet.state == msStopping
    )
    let r = e.start("g")
    check r.isErr and r.error.code == ecNotReady
    destroyGate.store(false)
    joinThread(t)
    check stopped.load == ord(msUnloaded)
    check inits.load == 1
    e.finish()

  test "[RUN-0791] [RUN-0792] [RUN-0793] [RUN-1056] [RUN-1072] [RUN-1073] [RUN-1092] [TXT-0290] a stop past its deadline stays stopping with cleanup-timeout, releases nothing, and completes when its cleanup does [IMPL-DECISION G180] [IMPL-DECISION G227]":
    var cfg = config()
    cfg.stopDeadline = initDuration(milliseconds = 100)
    let e = newEngine(cfg)
    discard e.create(gated(), "g").tryGet
    discard e.start("g").tryGet
    let before = e.changes()[^1].serial
    destroyGate.store(true)
    # [SPEC RUNTIME l.575] The stop answers at its deadline: `stopping`, with
    # `cleanup-timeout` reported.
    let s = e.stop("g").tryGet
    check s.state == msStopping and s.failureOf == "cleanup-timeout"
    check s.execution.intent == inStopped
    check live.load == 1 # destroy is still running; nothing was forced
    # While the cleanup is unresolved a start is NOT_READY and keeps the
    # stopped intent.
    let r = e.start("g")
    check r.isErr and r.error.code == ecNotReady
    check e.view("g").tryGet.execution.intent == inStopped
    destroyGate.store(false)
    # [SPEC RUNTIME l.576] When the pending cleanup completes, the stop
    # completes: `unloaded`, failure cleared. The Runtime thread commits it
    # after `_MODULE_destroy` returned and the release was answered.
    check waitUntil(
      proc(): bool =
        e.view("g").tryGet.state == msUnloaded
    )
    check destroys.load == 1 and live.load == 0
    # The stop's accept (intent `stopped`, state kept) comes first.
    check e.statesSince("g", before) == @[msReady, msStopping, msStopping, msUnloaded]
    check e.view("g").tryGet.failure.isNone
    # And a start is accepted again.
    check e.start("g").tryGet.state == msReady
    e.finish()

  test "[RUN-0791] [RUN-0793] [RUN-1092] [IMPL-DECISION G180] a stop ordered while stopping past its deadline joins it: no second destruction, and its end completes the stop":
    var cfg = config()
    cfg.stopDeadline = initDuration(milliseconds = 100)
    let e = newEngine(cfg)
    discard e.create(gated(), "g").tryGet
    discard e.start("g").tryGet
    destroyGate.store(true)
    check e.stop("g").tryGet.failureOf == "cleanup-timeout"
    # A new explicit stop is accepted while the instance is `stopping`: it
    # starts no second destruction and reports the stop in progress.
    let again = e.stop("g").tryGet
    check again.state == msStopping and again.failureOf == "cleanup-timeout"
    destroyGate.store(false)
    check waitUntil(
      proc(): bool =
        e.view("g").tryGet.state == msUnloaded
    )
    check destroys.load == 1
    check e.view("g").tryGet.failure.isNone
    e.finish()

  test "[RUN-0352] [RUN-0353] an expected execution revision is compared with acceptance: a stale one is `stale-revision` with the current revision":
    let e = newEngine(config())
    let c = e.create(gated(), "g").tryGet
    let stale = e.start("g", expectedRevision = Opt.some(c.execution.revision + 7))
    check stale.isErr and stale.error.isTyped
    check stale.error.typed.get ==
      TypedError(
        code: recStaleRevision, currentRevision: Opt.some(c.execution.revision)
      )
    check e.view("g").tryGet.execution == c.execution and inits.load == 0
    check e.start("g", expectedRevision = Opt.some(c.execution.revision)).tryGet.state ==
      msReady
    e.finish()

suite "run.engine: readiness and failures (RUNTIME §3.3, §3.4, §3.6, §9.3, §10)":
  setup:
    reset()

  test "[RUN-0104] [RUN-0105] [RUN-0106] [RUN-0114] [RUN-0134] [RUN-0265] [RUN-0266] [RUN-0288] [RUN-0795] [PKG-0288] the call surface is compared with the expected contracts":
    let e = newEngine(config())
    let root = meterRoot()
    var wrong = root
    wrong[0] = wrong[0] xor 1
    discard e.create(meter(Opt.some(root)), "ok").tryGet
    let ok = e.start("ok").tryGet
    check ok.state == msReady and ok.provider
    discard e.create(meter(), "plain").tryGet
    let plain = e.start("plain").tryGet
    check plain.state == msReady and not plain.provider # §8: no declared contract
    discard e.create(meter(Opt.some(wrong)), "wrong").tryGet
    let w = e.start("wrong").tryGet
    check w.state == msError and w.failureOf == "initialization-failed"
    check not w.provider
    discard e.create(meter(implements = @[root]), "iface").tryGet
    check e.start("iface").tryGet.failureOf == "initialization-failed"
    # A consumer-only module cannot satisfy an expected contract; its context
    # is destroyed before the instance is reported as failed.
    var g = gated()
    g.primaryContract = Opt.some(root)
    discard e.create(g, "consumer").tryGet
    check e.start("consumer").tryGet.state == msError
    check waitUntil(
      proc(): bool =
        destroys.load == 1
    )
    check live.load == 0
    e.finish()

  test "[RUN-0296] [RUN-0708] [RUN-0709] [RUN-1052] [RUN-1057] [RUN-0681] [RUN-0682] [RUN-0885] [TXT-0280] a failed start is classified (a Loader error is `loader-<code>`), cleaned, and leaves other instances running":
    let e = newEngine(config())
    discard e.create(meter(), "m").tryGet
    check e.start("m").tryGet.state == msReady
    mode.store(ord(gmFail))
    discard e.create(gated(), "fail").tryGet
    let f = e.start("fail").tryGet
    check f.state == msError and f.failureOf == "initialization-failed"
    check f.execution.intent == inRequested # RUN-0668
    mode.store(ord(gmOkNull))
    discard e.create(gated(), "null").tryGet
    check e.start("null").tryGet.failureOf == "initialization-failed"
    discard e.create(
      ModuleRecord(module: "gated_consumer", strategy: stDirectStatic, binding: "nope"),
      "unbound",
    ).tryGet
    let u = e.start("unbound").tryGet
    check u.failureOf == "loader-invalid-request"
    var missing = ModuleRecord(module: "gated_consumer", strategy: stDirectDynamic)
    missing.artifact = ArtifactRecord(
      id: "a", localPath: work / "missing" & LibraryExtension, hashSuite: HashSuiteId
    )
    discard e.create(missing, "missing").tryGet
    let m = e.start("missing").tryGet
    check m.failureOf == "loader-artifact-unavailable"
    check e.view("m").tryGet.state == msReady
    check live.load == 0
    # A failed instance starts again once its cleanup is complete.
    mode.store(ord(gmOk))
    check e.start("fail").tryGet.state == msReady
    e.finish()

  test "[RUN-0295] [RUN-0297] an init that fails and still writes a context is initialization-failed, never ready, and that context is never destroyed (DECISIONS I88, deviation 2)":
    # [SPEC INTERFACE l.1631-1635, l.1662] A failure has a null context and
    # the module released its partial state; `_MODULE_destroy` is defined for
    # a successfully initialized instance only.
    let e = newEngine(config())
    failedContext = 0
    mode.store(ord(gmFailContext))
    discard e.create(gated(), "ctx").tryGet
    let v = e.start("ctx").tryGet
    check v.state == msError and v.failureOf == "initialization-failed"
    check e.view("ctx").tryGet.state == msError
    check destroys.load == 0 and failedContext == 0
    mode.store(ord(gmOk))
    check e.start("ctx").tryGet.state == msReady
    check destroys.load == 0 and failedContext == 0
    e.finish()
    check failedContext == 0

  test "[RUN-0796] [RUN-0797] [RUN-0792] [RUN-0793] [RUN-0791] the startup deadline: error, then the late context is destroyed":
    var cfg = config()
    # [IMPL-DECISION G61, amended 2026-11-14] This deadline bounds the module's
    # attempts only: the Module Loader's start at open has its own. The gated
    # init passes it whatever its length; `Slow` gives the last start, which is
    # not gated, time to become ready.
    cfg.startupDeadline = initDuration(milliseconds = 150 * Slow)
    let e = newEngine(cfg)
    discard e.create(gated(), "g").tryGet
    initGate.store(true)
    let t = e.start("g").tryGet
    check t.state == msError and t.failureOf == "startup-timeout"
    check t.execution.intent == inRequested
    # Initialization is still running: no destroy, and no new attempt.
    check destroys.load == 0
    let busy = e.start("g")
    check busy.isErr and busy.error.code == ecNotReady
    check e.view("g").tryGet.execution == t.execution
    initGate.store(false)
    check waitUntil(
      proc(): bool =
        destroys.load == 1
    )
    check live.load == 0
    let after = e.view("g").tryGet
    check after.state == msError and after.failureOf == "startup-timeout"
    # A new attempt can make it ready now. Its deadline is the same short one, which
    # a loaded machine can let pass (TSan in CI), so the test starts it again
    # until one attempt is ready.
    check waitUntil(
      proc(): bool =
        let r = e.start("g")
        r.isOk and r.get.state == msReady and r.get.failure.isNone
    )
    e.finish()

  test "[RUN-0302] [RUN-0648] [RUN-0649] [RUN-0650] [RUN-0651] [RUN-0652] [RUN-0653] [RUN-0655] [RUN-0657] report_failure is bound to the current realization":
    let e = newEngine(config())
    discard e.create(gated(), "g").tryGet
    let v = e.start("g").tryGet
    check e.reportFailure("g", "a-forged").error.code == ecNotAuthorised
    check e.reportFailure("other", v.attempt).error.code == ecNotAuthorised
    check e.reportFailure("g", v.attempt, "disk gone").isOk
    let f = e.view("g").tryGet
    check f.state == msError and f.failureOf == "reported-by-module"
    check f.failure.get.reason == "disk gone"
    check f.execution.intent == inRequested
    check e.reportFailure("g", v.attempt).error.code == ecNotReady
    # [I89] The release's reply comes back through the Module Loader after
    # `_MODULE_destroy` returned; until then the cleanup is pending.
    check waitUntil(
      proc(): bool =
        destroys.load == 1 and not e.cleanupPending("g")
    )
    let r = e.start("g").tryGet
    check r.state == msReady and r.attempt != v.attempt
    check e.reportFailure("g", v.attempt).error.code == ecNotReady
    e.finish()

  test "[RUN-0654] a report during initialization keeps that realization from becoming ready":
    let e = newEngine(config())
    discard e.create(gated(), "g").tryGet
    initGate.store(true)
    var t: Thread[(Engine, string)]
    started.store(-2)
    createThread(t, startOn, (e, "g"))
    check waitUntil(
      proc(): bool =
        inits.load == 1
    )
    let v = e.view("g").tryGet
    check v.state == msLoaded
    check e.reportFailure("g", v.attempt, "early").isOk
    joinThread(t)
    check started.load == ord(msError)
    initGate.store(false)
    check waitUntil(
      proc(): bool =
        destroys.load == 1
    )
    check e.view("g").tryGet.failureOf == "reported-by-module"
    e.finish()

suite "run.engine: authorization (RUNTIME §3.6, §9) [G52] [G168]":
  setup:
    reset()

  test "[RUN-0130] [RUN-0326] [RUN-0668] execution denied: NOT_AUTHORISED, no module code runs, intent kept":
    let e = newEngine(
      config(
        denying(AuthzRule(action: Opt.some(aaExecute), target: "g", outcome: azDeny))
      )
    )
    discard e.create(gated(), "g").tryGet
    let r = e.start("g")
    check r.isErr and r.error.code == ecNotAuthorised
    let v = e.view("g").tryGet
    check v.state == msUnloaded and v.failureOf == "authority-denied"
    check v.execution.intent == inRequested
    check inits.load == 0
    let a = e.answers()
    check a.len >= 1 and a[^1].outcome == azDeny and a[^1].request.action == aaExecute
    check a[^1].decisionId.len > 0
    e.finish()

  test "[RUN-0326] an evaluation failure fails closed and is recorded apart from a deny":
    let e = newEngine(
      config(
        denying(
          AuthzRule(
            action: Opt.some(aaExecute), target: "g", outcome: azEvaluationFailed
          )
        )
      )
    )
    discard e.create(gated(), "g").tryGet
    check e.start("g").error.code == ecNotAuthorised
    check e.view("g").tryGet.failureOf == "authority-evaluation-failed"
    check e.answers()[^1].outcome == azEvaluationFailed
    e.finish()

  test "[RUN-1034] [RUN-1035] [RUN-0666] a module consumer's lifecycle request is authorized; unknown targets do not disclose":
    let e = newEngine(config(denying(deny(consumer = "intruder"))))
    let c = e.create(gated(), "g").tryGet
    let denied = e.start("g", moduleOrigin("intruder"))
    check denied.isErr and denied.error.code == ecNotAuthorised
    check e.view("g").tryGet.execution == c.execution
    check e.start("nobody", moduleOrigin("friend")).error.code == ecNotAuthorised
    check e.start("nobody").error.code == ecInvalidParams
    let v = e.start("g", moduleOrigin("friend")).tryGet
    check v.state == msReady and v.intentOrigin.instance == "friend"
    check e.stop("g", moduleOrigin("intruder")).error.code == ecNotAuthorised
    check e.view("g").tryGet.state == msReady
    e.finish()

suite "run.engine: ordering, shutdown and observation (RUNTIME §3.7, §9.1, §10.2)":
  setup:
    reset()

  test "[RUN-0140] [RUN-0141] [RUN-0683] [RUN-1193] [TXT-0580] a dependent starts only after its prerequisite is ready; meanwhile it is `unloaded` with `prerequisite-unavailable`":
    var cfg = config()
    cfg.ordering = @[("a", "b")]
    let e = newEngine(cfg)
    discard e.create(gated(), "a").tryGet
    discard e.create(gated(), "b").tryGet
    let early = e.start("b")
    check early.isErr and early.error.code == ecNotReady
    var v = e.view("b").tryGet
    check v.execution.intent == inRequested
    check v.state == msUnloaded and v.failureOf == "prerequisite-unavailable"
    check inits.load == 0
    check e.start("a").tryGet.state == msReady
    # [IMPL-DECISION G359] It clears at the next accepted attempt (l.3611).
    check e.view("b").tryGet.failureOf == "prerequisite-unavailable"
    v = e.start("b").tryGet
    check v.state == msReady and v.failure.isNone
    e.finish()

  test "[RUN-1193] [TXT-0580] a prerequisite in an accepted attempt makes a dependent wait without a failure (P5 reading C3)":
    var cfg = config()
    cfg.ordering = @[("a", "b")]
    let e = newEngine(cfg)
    discard e.create(gated(), "a").tryGet
    discard e.create(gated(), "b").tryGet
    initGate.store(true)
    var t: Thread[(Engine, string)]
    started.store(-2)
    createThread(t, startOn, (e, "a"))
    check waitUntil(
      proc(): bool =
        inits.load == 1
    )
    check e.view("a").tryGet.state == msLoaded
    let early = e.start("b")
    check early.isErr and early.error.code == ecNotReady
    let v = e.view("b").tryGet
    check v.state == msUnloaded and v.failure.isNone
    check v.execution.intent == inRequested
    initGate.store(false)
    joinThread(t)
    check started.load == ord(msReady)
    check e.start("b").tryGet.state == msReady
    e.finish()

  test "[RUN-1193] [TXT-0580] a prerequisite whose attempt fails marks the dependent waiting on it, though nobody asks (P5 Q2, the proactive pass)":
    var cfg = config()
    cfg.ordering = @[("a", "b")]
    cfg.startupDeadline = initDuration(milliseconds = 150 * Slow)
    let e = newEngine(cfg)
    discard e.create(gated(), "a").tryGet
    discard e.create(gated(), "b").tryGet
    initGate.store(true)
    var t: Thread[(Engine, string)]
    started.store(-2)
    createThread(t, startOn, (e, "a"))
    check waitUntil(
      proc(): bool =
        inits.load == 1
    )
    check e.start("b").error.code == ecNotReady
    check e.view("b").tryGet.failure.isNone # a is in its attempt
    joinThread(t)
    check started.load == ord(msError) # the startup deadline
    let v = e.view("b").tryGet
    check v.state == msUnloaded and v.execution.intent == inRequested
    check v.failureOf == "prerequisite-unavailable"
    initGate.store(false)
    check waitUntil(
      proc(): bool =
        destroys.load == 1
    )
    e.finish()

  test "[RUN-1193] [TXT-0580] the proactive mark fills and never replaces another cause; a refusal reports the first cause in one order, prerequisites first (P5 §0.3 item 1)":
    var cfg = config(
      denying(AuthzRule(action: Opt.some(aaExecute), target: "c", outcome: azDeny))
    )
    cfg.ordering = @[("a", "c")]
    let e = newEngine(cfg)
    discard e.create(gated(), "a").tryGet
    discard e.create(gated(), "c").tryGet
    check e.start("a").tryGet.state == msReady
    check e.start("c").error.code == ecNotAuthorised
    check e.view("c").tryGet.failureOf == "authority-denied"
    # a leaves `ready`: c keeps the denial the pass may not replace.
    check e.stop("a").tryGet.state == msUnloaded
    var v = e.view("c").tryGet
    check v.state == msUnloaded and v.failureOf == "authority-denied"
    # A recovery now meets the prerequisite first, the current cause (l.3611).
    check e.recover("c", v.execution.revision).error.code == ecNotReady
    v = e.view("c").tryGet
    check v.failureOf == "prerequisite-unavailable"
    # With a ready again, the denial is the cause once more.
    check e.start("a").tryGet.state == msReady
    check e.recover("c", v.execution.revision).error.code == ecNotAuthorised
    check e.view("c").tryGet.failureOf == "authority-denied"
    e.finish()

  test "[RUN-0705] [RUN-0706] [RUN-0142] [RUN-1074] shutdown releases dependents first, keeps intent and closes admission":
    var cfg = config()
    cfg.ordering = @[("a", "b")]
    let e = newEngine(cfg)
    discard e.create(gated(), "a").tryGet
    discard e.create(gated(), "b").tryGet
    discard e.start("a").tryGet
    discard e.start("b").tryGet
    let before = e.changes()[^1].serial
    e.shutdown()
    check destroys.load == 2 and live.load == 0
    for v in e.list():
      check v.state == msUnloaded and v.execution.intent == inRequested
      # [P5 §0.3 item 1, rule 3] No `prerequisite-unavailable` once shutdown
      # is accepted: b stopped first, then a.
      check v.failure.isNone
    check e.start("a").error.code == ecNotReady
    check e.create(gated(), "c").error.code == ecNotReady
    var unloadedAt: seq[(string, uint64)]
    for c in e.changes():
      if c.serial > before and c.view.state == msUnloaded:
        unloadedAt.add((c.view.instance, c.serial))
    # [I89] The Module Loader is released last.
    check unloadedAt.len == 3 and unloadedAt[0][0] == "b" and unloadedAt[1][0] == "a"
    check unloadedAt[2][0] == LoaderInstanceId
    check e.close()

  test "[RUN-1072] [RUN-1073] [TXT-0312] a destroy that outlives the shutdown grace is recorded, not forced; it completes the stop when it returns":
    var cfg = config()
    cfg.shutdownGrace = initDuration(milliseconds = 150)
    let e = newEngine(cfg)
    discard e.create(gated(), "g").tryGet
    discard e.start("g").tryGet
    destroyGate.store(true)
    e.shutdown()
    # [SPEC RUNTIME l.3702] Still `stopping`, `cleanup-timeout` reported.
    let v = e.view("g").tryGet
    check v.state == msStopping and v.failureOf == "cleanup-timeout"
    check live.load == 1 # the context was not touched
    let r = e.awaitShutdown()
    check r.isErr and r.error.code == ecModule
    # [Q-r D4] Its forced cleanup is the host's: it shares this process.
    check "forced cleanup of g is requested: the host process must end" in
      r.error.message
    destroyGate.store(false)
    check waitUntil(
      proc(): bool =
        destroys.load == 1 and e.view("g").tryGet.state == msUnloaded
    )
    check e.close()

  test "[RUN-0348] [RUN-0350] [RUN-0361] [RUN-0362] [RUN-0363] committed changes are ordered, and each is one snapshot":
    let e = newEngine(config())
    discard e.create(gated(), "g").tryGet
    discard e.start("g").tryGet
    discard e.stop("g").tryGet
    discard e.start("g").tryGet
    let cs = e.changes().withoutLoader
    check cs.len >= 6
    for i in 1 ..< cs.len:
      check cs[i].serial > cs[i - 1].serial
      check cs[i].view.execution.revision > cs[i - 1].view.execution.revision
    for c in cs:
      check (c.view.execution.intent == inRequested) ==
        c.view.execution.intentRevision.isSome
      check c.view.failureRuleHolds
    e.finish()

suite "run.engine: the lifecycle table (RUNTIME §3.4 l.515-528, §9.1 l.1730-1734)":
  setup:
    reset()

  test "[RUN-1110] [TXT-0304] [TXT-0579] [TXT-0288] a stop of an error instance goes through stopping: with nothing to clean, in two state changes; with a release in flight, no second one, and the stop completes when that one does":
    let e = newEngine(config())
    # Nothing to clean: after the stop's accept (intent `stopped`, state kept),
    # `stopping`, then `unloaded`.
    mode.store(ord(gmFail))
    discard e.create(gated(), "f").tryGet
    check e.start("f").tryGet.state == msError
    check waitUntil(
      proc(): bool =
        not e.cleanupPending("f")
    )
    var before = e.changes()[^1].serial
    let s = e.stop("f").tryGet
    check s.state == msUnloaded and s.failure.isNone
    check e.statesSince("f", before) == @[msError, msStopping, msUnloaded]
    # A release in flight: a failure report, its destroy held.
    mode.store(ord(gmOk))
    discard e.create(gated(), "g").tryGet
    let v = e.start("g").tryGet
    destroyGate.store(true)
    check e.reportFailure("g", v.attempt, "gone").isOk
    check waitUntil(
      proc(): bool =
        e.view("g").tryGet.state == msError
    )
    before = e.changes()[^1].serial
    var t: Thread[(Engine, string)]
    stopped.store(-2)
    createThread(t, stopOn, (e, "g"))
    check waitUntil(
      proc(): bool =
        e.view("g").tryGet.state == msStopping
    )
    # [SPEC RUNTIME l.3611] Its failure stays until the stop completes.
    check e.view("g").tryGet.failureOf == "reported-by-module"
    destroyGate.store(false)
    joinThread(t)
    check stopped.load == ord(msUnloaded)
    check destroys.load == 1 # no second destruction
    check e.statesSince("g", before) == @[msError, msStopping, msUnloaded]
    check e.view("g").tryGet.failure.isNone
    e.finish()

  test "[RUN-1091] [TXT-0277] [TXT-0278] [TXT-0279] [TXT-0280] [TXT-0281] [TXT-0282] [TXT-0283] [TXT-0284] [TXT-0285] [TXT-0286] [TXT-0288] the lifecycle table: each of its ten transitions, and no other":
    let e = newEngine(config())
    discard e.create(gated(), "g").tryGet
    let before = e.changes()[^1].serial
    var t, u: Thread[(Engine, string)]
    # unloaded -> loaded -> ready.
    initGate.store(true)
    started.store(-2)
    createThread(t, startOn, (e, "g"))
    check waitUntil(
      proc(): bool =
        inits.load == 1
    )
    initGate.store(false)
    joinThread(t)
    check started.load == ord(msReady)
    # ready -> stopping -> unloaded.
    destroyGate.store(true)
    stopped.store(-2)
    createThread(u, stopOn, (e, "g"))
    check waitUntil(
      proc(): bool =
        e.view("g").tryGet.state == msStopping
    )
    destroyGate.store(false)
    joinThread(u)
    check stopped.load == ord(msUnloaded)
    # unloaded -> loaded -> stopping -> unloaded: a stop before readiness.
    initGate.store(true)
    started.store(-2)
    createThread(t, startOn, (e, "g"))
    check waitUntil(
      proc(): bool =
        inits.load == 2
    )
    stopped.store(-2)
    createThread(u, stopOn, (e, "g"))
    check waitUntil(
      proc(): bool =
        e.view("g").tryGet.state == msStopping
    )
    initGate.store(false)
    joinThread(t)
    joinThread(u)
    check stopped.load == ord(msUnloaded)
    # unloaded -> loaded -> error: initialization fails.
    mode.store(ord(gmFail))
    check e.start("g").tryGet.state == msError
    check waitUntil(
      proc(): bool =
        not e.cleanupPending("g")
    )
    # error -> loaded -> ready: a new accepted attempt.
    mode.store(ord(gmOk))
    let v = e.start("g").tryGet
    check v.state == msReady
    # ready -> error: an accepted failure report.
    check e.reportFailure("g", v.attempt).isOk
    check waitUntil(
      proc(): bool =
        e.view("g").tryGet.state == msError and not e.cleanupPending("g")
    )
    # error -> stopping -> unloaded.
    check e.stop("g").tryGet.state == msUnloaded
    # unloaded -> loaded -> ready -> stopping -> error: the cleanup fails.
    check e.start("g").tryGet.state == msReady
    check e.setLoaderFaultsForTests(LoaderFaults(failInvocation: {lmRelease})).isOk
    let f = e.stop("g").tryGet
    check f.state == msError and f.failureOf == "cleanup-failed"
    var states = @[msUnloaded]
    for s in e.statesSince("g", before):
      if s != states[^1]:
        states.add(s)
    check states ==
      @[
        msUnloaded, msLoaded, msReady, msStopping, msUnloaded, msLoaded, msStopping,
        msUnloaded, msLoaded, msError, msLoaded, msReady, msError, msStopping,
        msUnloaded, msLoaded, msReady, msStopping, msError,
      ]
    # [RUN-1091] Every commit of every instance in this process so far was a
    # row of the table (the test-hook check in `commit` and `accept`).
    check lifecycleOffTableForTests() == 0
    e.clearLoaderFaultsForTests()
    e.confirmTerminationForTests()
    e.finish()

# The host's bootstrap and shutdown -------------------------------------------------

var
  bootstrapCode: Atomic[int] ## the bootstrap's error code, 0 for OK, -1 while it runs
  awaitCode: Atomic[int] ## the same for an await

proc bootstrapOn(arg: (Engine, seq[BootstrapInstance])) {.thread.} =
  let r = arg[0].bootstrap(arg[1], "o")
  bootstrapCode.store(
    if r.isOk:
      0
    else:
      ord(r.error.code)
  )

proc awaitOn(e: Engine) {.thread.} =
  let r = e.awaitShutdown()
  awaitCode.store(
    if r.isOk:
      0
    else:
      ord(r.error.code)
  )

func deployment(): seq[BootstrapInstance] =
  @[
    BootstrapInstance(instance: "o", record: gated()),
    BootstrapInstance(instance: "m", record: meter()),
  ]

suite "run.engine: the host's bootstrap and shutdown (RUNTIME l.1640, §13.2) [G190] [G60]":
  setup:
    reset()

  test "[RUN-0309] [RUN-0023] [RUN-0784] [IMPL-DECISION G191] bootstrap creates every instance in order and realizes only the orchestration instance":
    let e = newEngine(config())
    let v = e.bootstrap(deployment(), "o").tryGet
    check v.instance == "o" and v.state == msReady and v.orchestration
    let all = e.list().withoutLoader
    check all.len == 2 and all[0].instance == "o" and all[1].instance == "m"
    check all[1].state == msUnloaded and all[1].execution.intent == inUninitialized
    check not all[1].orchestration
    # G191 interim: `requested`, with its revision and the host's origin.
    check all[0].execution.intent == inRequested
    check all[0].execution.intentRevision.isSome and all[0].intentOrigin.host
    check e.bootstrap(deployment(), "o").error.code == ecNotReady
    e.finish()

  test "[IMPL-DECISION G190] a failed bootstrap: NOT_AUTHORISED for a denial, MODULE_ERROR for an init failure or the startup deadline; nothing is stopped":
    var e = newEngine(
      config(
        denying(AuthzRule(action: Opt.some(aaExecute), target: "o", outcome: azDeny))
      )
    )
    var r = e.bootstrap(deployment(), "o")
    check r.error.code == ecNotAuthorised
    e.finish()
    mode.store(ord(gmFail))
    e = newEngine(config())
    r = e.bootstrap(deployment(), "o")
    check r.error.code == ecModule and "initialization-failed" in r.error.message
    check e.view("o").tryGet.state == msError
    # [RUN-0737] The engine keeps running: other instances can still start.
    check e.start("m").tryGet.state == msReady
    e.finish()
    reset()
    var cfg = config()
    # [IMPL-DECISION G61, amended 2026-11-14] The short deadline bounds the
    # modules' attempts only; the Module Loader's start keeps its own, at its
    # default. The gated init passes the short one whatever its length.
    cfg.startupDeadline = initDuration(milliseconds = 250 * Slow)
    cfg.loaderStartupDeadline = DefaultLoaderStartupDeadline
    e = newEngine(cfg)
    initGate.store(true)
    r = e.bootstrap(deployment(), "o")
    check r.error.code == ecModule and "startup-timeout" in r.error.message
    # [RUN-0737] Here too the engine takes a start. Every start of this engine has
    # the short deadline, which a loaded machine can let pass (TSan in CI), so
    # the test does not ask for `ready`: only that the start ran.
    let m = e.start("m")
    check m.isOk and (m.get.state == msReady or m.get.failureOf == "startup-timeout")
    e.finish()

  test "[RUN-0759] [IMPL-DECISION G190] a shutdown accepted before ready gives CANCELLED, and it stays CANCELLED":
    let e = newEngine(config())
    initGate.store(true)
    bootstrapCode.store(-1)
    var t: Thread[(Engine, seq[BootstrapInstance])]
    createThread(t, bootstrapOn, (e, deployment()))
    check waitUntil(
      proc(): bool =
        inits.load == 1
    )
    e.requestShutdown()
    check waitUntil(
      proc(): bool =
        bootstrapCode.load != -1
    )
    check bootstrapCode.load == ord(ecCancelled)
    initGate.store(false) # init now succeeds; the answer was given
    joinThread(t)
    check e.awaitShutdown().isOk
    check e.close()

  test "[RUN-0726] [RUN-0727] [RUN-0728] [RUN-0760] a request accepts at once, a wait never initiates, every wait gets the one result":
    let e = newEngine(config())
    discard e.bootstrap(deployment(), "o").tryGet
    awaitCode.store(-1)
    var t: Thread[Engine]
    createThread(t, awaitOn, e)
    sleep(50)
    check awaitCode.load == -1 # waiting alone starts nothing
    check e.view("o").tryGet.state == msReady
    e.requestShutdown()
    e.requestShutdown()
    joinThread(t)
    check awaitCode.load == 0
    check e.awaitShutdown().isOk and e.awaitShutdown().isOk
    check e.view("o").tryGet.execution.intent == inRequested # kept (§10.2)
    check e.close()

  test "[IMPL-DECISION G60] cleanup left unresolved is MODULE_ERROR for every waiter; close refuses while module code runs and can be retried":
    var cfg = config()
    cfg.shutdownGrace = initDuration(milliseconds = 100)
    let e = newEngine(cfg)
    discard e.bootstrap(deployment(), "o").tryGet
    check e.tryClose().error.code == ecNotReady # not shut down
    destroyGate.store(true)
    e.requestShutdown()
    let r = e.awaitShutdown()
    check r.error.code == ecModule and "o" in r.error.message
    check e.awaitShutdown().error.code == ecModule
    let refused = e.tryClose()
    check refused.error.code == ecNotReady and "still running" in refused.error.message
    check e.view("o").isOk # still open
    destroyGate.store(false)
    check e.close()

suite "run.engine: persistent state (I82)":
  test "[RUN-1030] [IMPL] after a restart a direct_dynamic instance is copied and verified again from its stored record":
    let lib = buildKitLibrary("sensor_impl.nim", "engsensor")
    let src = work / ("sensor-src" & LibraryExtension)
    copyFile(lib, src)
    proc digest(path: string): array[32, byte] =
      var h: Blake3Hasher
      h.init()
      let bytes = readFile(path)
      h.update(bytes.toOpenArrayByte(0, bytes.high))
      h.finish()

    let rec = ModuleRecord(
      module: "sensor_module",
      strategy: stDirectDynamic,
      artifact: ArtifactRecord(
        id: "sensor", localPath: src, hash: digest(src), hashSuite: HashSuiteId
      ),
    )
    proc opened(): (Engine, string) =
      var c = config()
      c.runtimeInstanceId = ""
      c.storeDir = Opt.some(work / "dyn-store")
      (openEngine(c).tryGet, c.workDir)

    var (e, _) = opened()
    discard e.create(rec, "s1").tryGet
    check e.start("s1").tryGet.state == msReady
    e.finish()
    # A new work directory: the artifact is copied there again and verified.
    var (e2, dir) = opened()
    check e2.start("s1").tryGet.state == msReady
    var copies = 0
    for f in walkDirRec(dir):
      if f.endsWith(LibraryExtension):
        inc copies
    check copies == 1
    e2.finish()
    # The file changed since the record was accepted: it does not start.
    let f = open(src, fmAppend)
    f.write("x")
    f.close()
    var (e3, _) = opened()
    let s1 = e3.start("s1").tryGet
    check s1.failureOf == "loader-artifact-integrity-failed"
    e3.finish()
