## The Module Loader at engine level (Tier 4b step 4b-1; DECISIONS I89): the
## instance the engine establishes at open and binds (LOADER §1-§2; RUNTIME
## l.1635-1667; BOOTSTRAP l.287-290), every realization and release through
## its contract, as the Loader's request journal shows them (a test hook,
## `loaderJournalForTests`), the lifecycle answers on the Loader instance and
## routes to it ([IMPL-DECISION G246], [IMPL-DECISION G251]), the
## classifications and summaries of what it realizes (RUNTIME §9.3), and the
## shutdown order (RUNTIME §10.2).
##
## The modules are `routefixture`'s: a consumer that keeps its Runtime Control
## binding, a module whose initialization waits at a gate, and the meter kit
## module as provider. Module code runs on the engine's workers and inside the
## Loader's calls, so the test modules keep their state in atomics.

import std/[algorithm, atomics, monotimes, os, sequtils, strutils, times, typedthreads]
import unittest2
import ../src/logos_core/runtime/engine
import ../src/logos_core/abi/[checks, types]
import ../src/logos_core/cbor
import ../src/logos_core/commitment
import ../src/logos_core/iface/[accept, outcome, provider, surface]
import ../src/logos_core/iface/common_types
import ../src/logos_core/loader/contract
import ../src/logos_core/pins
from ../src/logos_core/runtime/artifact import ArtifactRecord
import ./support/[kitbuild, kitruntime, withoutloader]
import ./kit/meter_impl
import ./generated/meter_module_calls

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "loader_engine" / kitVariant
removeDir(work)
createDir(work)

include ./support/routefixture

let loaderRoot = toDigest(loaderRoots().contract).get

proc journal(e: Engine, meth: LoaderMethod): seq[JournalEntry] =
  ## The requests of one method the Loader served, in order.
  e.loaderJournalForTests().filterIt(it.meth == $meth)

proc address(e: Engine, instance: string): LogosNSRuntimeModuleInstanceAddress =
  LogosNSRuntimeModuleInstanceAddress(
    runtime_instance_id: e.runtimeInstanceId, module_instance_id: instance
  )

proc summaryOf(
    rc: ptr LogosRuntimeControlBinding, e: Engine, instance: string
): LogosNSRuntimeControlGetExecutionSummaryResponse =
  let r = rcCall(
    rc,
    "get_execution_summary",
    encode(LogosNSRuntimeControlGetExecutionSummaryRequest(target: e.address(instance))).tryGet,
  )
  check r.code == ecOk
  LogosNSRuntimeControlGetExecutionSummaryResponse.decode(r.response).tryGet

proc retireOf(
    rc: ptr LogosRuntimeControlBinding, e: Engine, instance: string
): RcResult =
  rcCall(
    rc,
    "retire_module",
    encode(
      LogosNSRuntimeControlRetireModuleRequest(
        target: e.address(instance),
        expected_execution_revision: e.view(instance).tryGet.execution.revision,
      )
    ).tryGet,
  )

proc loaderOf(e: Engine): InstanceView =
  e.view(LoaderInstanceId).tryGet

proc failureOf(v: InstanceView): string =
  if v.failure.isSome: v.failure.get.classification else: ""

const
  StaticKind =
    LogosNSRuntimeControlExecutionSelectionImplementationChoiceKind.Direct_static
  DynamicKind =
    LogosNSRuntimeControlExecutionSelectionImplementationChoiceKind.Direct_dynamic
  SpecificKind =
    LogosNSRuntimeControlExecutionSelectionImplementationChoiceKind.Implementation_specific

# The instance ---------------------------------------------------------------------------

suite "run.loader: the Loader instance (LOADER §1-§2; RUNTIME l.1635-1650) [IMPL-DECISION G246]":
  teardown:
    leftover()

  test "[LDR-0003] [LDR-0004] [LDR-0005] [LDR-0007] [RUN-0015] [RUN-0016] [RUN-0018] [BCP-0021] one Loader instance, established at open: a ready direct provider of the pinned contract with ordinary records":
    let e = fixtureEngine(config())
    let all = e.list()
    check all.len == 1 and all[0].instance == LoaderInstanceId
    let v = e.loaderOf
    check v.module == LoaderModuleName and v.state == msReady
    check v.execution.intent == inRequested and v.intentOrigin.host
    check not v.orchestration and v.stateAssignment.isNone
    check v.primaryContract == Opt.some(loaderRoot) and v.provider
    check v.providerId.len > 0
    # Its lifecycle record is an ordinary committed change.
    check e.changes().anyIt(
      it.view.instance == LoaderInstanceId and it.view.state == msReady
    )
    # Bound before the open returned: the binding's check is its one call so far.
    check e.loaderJournalForTests().mapIt(it.meth) == @[$lmListCapabilities]
    e.finish()

  test "[LDR-0006] the Loader's instance id, module name and static binding are the Runtime's own":
    let e = fixtureEngine(config())
    # The instance id: the existing duplicate-id answer.
    check e.create(meter(), LoaderInstanceId).error.code == ecInvalidParams
    # The module name or the binding, under any other id.
    var byModule = meter()
    byModule.module = LoaderModuleName
    check e.create(byModule, "x").error.code == ecInvalidParams
    var byBinding = meter()
    byBinding.binding = LoaderBindingId
    check e.create(byBinding, "y").error.code == ecInvalidParams
    check e.list().len == 1
    e.finish()
    # A static registration naming the Loader's binding or module: the open fails.
    var cfg = config()
    cfg.statics.add(checkStaticRegistration(LoaderBindingId, clientTable()).tryGet)
    let a = openEngine(cfg)
    check a.isErr and a.error.code == ecInvalidParams
    cfg = config()
    var copy = checkStaticRegistration("meter", meterModuleStaticSymbols()).tryGet
    copy.module = LoaderModuleName
    cfg.statics.add(copy)
    let b = openEngine(cfg)
    check b.isErr and b.error.code == ecInvalidParams

  test "[IMPL-DECISION G190] a Loader that cannot be established fails the open with MODULE_ERROR, leaving nothing running":
    # The startup deadline bounds the Loader's own start; one that passes at
    # once cannot be met.
    var cfg = config()
    cfg.startupDeadline = initDuration(nanoseconds = 1)
    let r = openEngine(cfg)
    check r.isErr and r.error.code == ecModule
    check r.error.message.startsWith("the Module Loader cannot start: startup-timeout")
    # The open released what it started: a new engine opens on the same
    # directories.
    cfg.startupDeadline = DefaultStartupDeadline
    let e = fixtureEngine(cfg)
    check e.loaderOf.state == msReady
    e.finish()

  test "[RUN-0639] [IMPL-DECISION G57] its summary is implementation-specific; what it realizes reports the strategy":
    let e = fixtureEngine(config())
    let (_, rc) = e.startClient("c")
    check rc.summaryOf(e, LoaderInstanceId).selection.get.implementation.kind ==
      SpecificKind
    check rc.summaryOf(e, "c").selection.get.implementation.kind == StaticKind
    e.finish()

# Bootstrap and realization --------------------------------------------------------------

suite "run.loader: realization through the bound Loader (RUNTIME l.1641; BOOTSTRAP l.287-290)":
  teardown:
    leftover()

  test "[RUN-0309] [RUN-0310] [BCP-0022] the Loader is bound first, then realizes the orchestration instance":
    let e = fixtureEngine(config())
    let v = e.bootstrap(
      @[
        BootstrapInstance(instance: "o", record: client()),
        BootstrapInstance(instance: "m", record: meter()),
      ],
      "o",
    ).tryGet
    check v.state == msReady and v.orchestration
    let j = e.loaderJournalForTests()
    check j.len == 2
    check j[0].meth == $lmListCapabilities
    check j[1].meth == $lmRealize and j[1].instance == "o"
    check j[1].module == "client_module" and j[1].strategy == "direct_static"
    check j[1].source == "client"
    check e.view("m").tryGet.state == msUnloaded
    e.finish()

  test "[BCP-0023] [BCP-0024] [LDR-0097] [LDR-0162] [RUN-1071] [RUN-0814] each start is a realize with the accepted record, each stop a release of that realization, and every realization id is fresh":
    var ids: seq[string]
    for round in 0 ..< 2:
      let e = fixtureEngine(config())
      for cycle in 0 ..< 2:
        if cycle == 0:
          discard e.started(meter(), "m")
        else:
          check e.start("m").tryGet.state == msReady
        check e.stop("m").tryGet.state == msUnloaded
      let realizes = e.journal(lmRealize)
      check realizes.len == 2
      for r in realizes:
        check r.instance == "m" and r.module == "meter_module"
        check r.strategy == "direct_static" and r.source == "meter"
      let releases = e.journal(lmRelease)
      check releases.len == 2
      for r in releases:
        check r.instance == "m" and r.realization.len > 0
        ids.add(r.realization)
      e.finish()
    # Two realizations per engine, and a new engine's Loader issues new ids:
    # no id of an earlier Loader reaches a later one (LDR-0162).
    check ids.len == 4 and ids.deduplicate.len == 4

  test "[LDR-0023] [LDR-0028] the realize request carries the accepted record's descriptor and nothing else":
    # What `realizeThroughLoader` sends: `realizeBytes` of the attempt's
    # request, whose descriptor is the accepted record's (`descriptor`).
    var digest: array[32, byte]
    for i in 0 ..< 32:
      digest[i] = byte(i + 1)
    let artifact = ArtifactRecord(
      id: "meter", localPath: work / "meter.so", hash: digest, hashSuite: HashSuiteId
    )
    let dynamic = ModuleRecord(
      module: "meter_module", strategy: stDirectDynamic, artifact: artifact
    )
    proc keys(v: CborValue): seq[string] =
      v.entries.mapIt(it.key.getText.get).sorted

    let q = decodeCbor(
      realizeBytes(
        RealizeRequest(
          moduleInstance: "d", descriptor: dynamic.descriptor, state: Opt.some("s1")
        )
      ).tryGet
    ).tryGet
    check q.keys == @["descriptor", "module_instance", "state"]
    let d = q.lookup("descriptor").get
    check d.keys == @["artifact", "module", "strategy"]
    let a = d.lookup("artifact").get
    check a.keys == @["hash", "hash_suite", "id", "local_path"]
    check a.lookup("id").get.getText.get == artifact.id
    check a.lookup("hash").get.getBytes.get == @(artifact.hash)
    check a.lookup("hash_suite").get.getText.get == artifact.hashSuite
    check a.lookup("local_path").get.getText.get == artifact.localPath
    check q.lookup("state").get.keys == @["assignment"]
    let direct =
      ModuleRecord(module: "meter_module", strategy: stDirectStatic, binding: "meter")
    let s = decodeCbor(
      realizeBytes(RealizeRequest(moduleInstance: "m", descriptor: direct.descriptor)).tryGet
    ).tryGet
    check s.keys == @["descriptor", "module_instance"]
    check s.lookup("descriptor").get.keys == @["module", "static_binding", "strategy"]

  test "[LDR-0027] [LDR-0087] [LDR-0143] a start the policy denies sends nothing to the Loader":
    let e =
      fixtureEngine(config(denying(deny(action = Opt.some(aaExecute), target = "m"))))
    discard e.create(meter(), "m").tryGet
    check e.start("m").error.code == ecNotAuthorised
    check e.journal(lmRealize).len == 0
    e.finish()

  test "[IMPL-DECISION G191] a store re-establishes the Loader at every open, with the host's intent":
    var cfg = config()
    cfg.storeDir = Opt.some(work / "store-reopen")
    removeDir(cfg.storeDir.get)
    var e = openEngine(cfg).tryGet
    live = e
    let first = e.loaderOf
    discard e.started(meter(), "m")
    e.finish()
    e = openEngine(cfg).tryGet
    live = e
    let again = e.loaderOf
    check again.state == msReady and again.intentOrigin.host
    check again.execution.revision > first.execution.revision
    check e.loaderJournalForTests().mapIt(it.meth) == @[$lmListCapabilities]
    e.finish()

# Classifications ------------------------------------------------------------------------

suite "run.loader: classifications of a Loader realization (RUNTIME §9.3 l.3750-3756)":
  teardown:
    leftover()

  test "[RUN-1053] [LDR-0133] a typed Loader error is loader-<code>, a start that is answered, never NOT_AUTHORISED":
    let e = fixtureEngine(config())
    let (_, rc) = e.startClient("c")
    discard e.create(
      ModuleRecord(module: "client_module", strategy: stDirectStatic, binding: "nope"),
      "u",
    ).tryGet
    let u = e.start("u").tryGet
    check u.state == msError and u.failure.get.classification == "loader-invalid-request"
    check u.failure.get.kind == fkLoader and u.failure.get.internal
    var missing = ModuleRecord(module: "meter_module", strategy: stDirectDynamic)
    missing.artifact = ArtifactRecord(
      id: "a", localPath: work / "missing" & LibraryExtension, hashSuite: HashSuiteId
    )
    discard e.create(missing, "d").tryGet
    let d = e.start("d").tryGet
    check d.failure.get.classification == "loader-artifact-unavailable"
    # Without a state root, a state assignment cannot be established (LOADER §5.1).
    var stateful = meter()
    stateful.stateAssignment = Opt.some("s1")
    discard e.create(stateful, "s").tryGet
    let s = e.start("s").tryGet
    check s.failure.get.classification == "loader-realization-failed"
    # Observation shows the classification, never the Loader's message.
    let summary = rc.summaryOf(e, "d")
    check summary.failure == Opt.some("loader-artifact-unavailable")
    check summary.selection.get.implementation.kind == DynamicKind
    # The Loader itself is unaffected.
    check e.loaderOf.state == msReady
    e.finish()

# The Loader instance's lifecycle and routes ------------------------------------------

suite "run.loader: lifecycle and routes of the Loader instance (RUNTIME l.3563-3572, l.1652-1667) [IMPL-DECISION G246] [IMPL-DECISION G251]":
  teardown:
    leftover()

  test "a stop of the Loader is NOT_READY while it owns a realization; owning none it stops, and every later start is NOT_READY":
    let e = fixtureEngine(config())
    discard e.started(meter(), "m")
    let before = e.loaderOf
    let refused = e.stop(LoaderInstanceId)
    check refused.isErr and refused.error.code == ecNotReady
    check e.loaderOf.execution == before.execution
    check e.stop("m").tryGet.state == msUnloaded
    check e.stop(LoaderInstanceId).tryGet.state == msUnloaded
    # [RUN-0702] Every operation that needs the Loader now fails.
    check e.start("m").error.code == ecNotReady
    check e.start(LoaderInstanceId).error.code == ecNotReady
    e.finish()

  test "[RUN-0703] recovery and retirement of the ready Loader are NOT_READY; a healthy realization stays ready":
    let e = fixtureEngine(config())
    let (_, rc) = e.startClient("c")
    discard e.started(meter(), "m")
    let v = e.loaderOf
    # A start of the ready Loader answers its state; a recovery is NOT_READY.
    check e.start(LoaderInstanceId).tryGet.execution == v.execution
    check e.recover(LoaderInstanceId, v.execution.revision).error.code == ecNotReady
    check rc.retireOf(e, LoaderInstanceId).code == ecNotReady
    check e.view("m").tryGet.state == msReady
    check e.loaderOf.execution == v.execution
    e.finish()

  test "[LDR-0006] a route to the Loader is NOT_AUTHORISED under allow-all, with no decision asked about it":
    let e = fixtureEngine(config())
    let (_, rc) = e.startClient("c")
    let asked = e.answers().len
    check rc.establish("k1", root = loaderRoot).code == ecNotAuthorised
    let id = e.loaderOf.providerId
    check rc.establish(
      "k2", root = loaderRoot, provider = Opt.some(providerAddress(id))
    ).code == ecNotAuthorised
    # Only the method's own check is asked (RUNTIME l.1626); nothing names
    # the Loader or a provider.
    let answers = e.answers()[asked ..^ 1]
    check answers.len == 2
    for a in answers:
      check a.request.action == aaRuntimeControl and
        a.request.operation == "establish_route"
      check a.request.provider.len == 0 and a.request.target.len == 0
    check e.journal(lmRealize).len == 1 # the client's own
    e.finish()

# Injected faults --------------------------------------------------------------------

var startReply: Atomic[int] ## the state `startOn` got, or -1; -2 while it waits

proc startOn(arg: (Engine, string)) {.thread.} =
  let r = arg[0].start(arg[1])
  startReply.store(
    if r.isOk:
      ord(r.get.state)
    else:
      -1
  )

proc faults(e: Engine, f: LoaderFaults) =
  check e.setLoaderFaultsForTests(f).isOk

proc unhooked() =
  ## A suite's `teardown` after injected faults: held calls reply, the
  ## protected mechanism confirms what nothing else can clean, then the
  ## engine closes.
  if live != nil:
    live.clearLoaderFaultsForTests()
    live.confirmTerminationForTests()
  leftover()

# Shutdown -------------------------------------------------------------------------------

suite "run.loader: shutdown (RUNTIME §10.2 l.3847-3864)":
  teardown:
    unhooked()

  test "[RUN-1075] every Loader-owned realization is released before the Loader":
    var cfg = config()
    cfg.ordering = @[("a", "b")]
    let e = fixtureEngine(cfg)
    discard e.started(meter(), "a")
    discard e.started(client(), "b")
    let before = e.changes()[^1].serial
    e.shutdown()
    let releases = e.journal(lmRelease)
    check releases.mapIt(it.instance) == @["b", "a"]
    var unloaded: seq[string]
    for c in e.changes():
      if c.serial > before and c.view.state == msUnloaded:
        unloaded.add(c.view.instance)
    check unloaded == @["b", "a", LoaderInstanceId]
    # Intent is kept, the Loader's too.
    for v in e.list():
      check v.state == msUnloaded and v.execution.intent == inRequested
    live = nil
    check e.close()

  test "[R3] a release held past the shutdown grace: shutdown completes with MODULE_ERROR and the Loader stays until the release returns":
    var cfg = config()
    cfg.shutdownGrace = initDuration(milliseconds = 200)
    let e = fixtureEngine(cfg)
    discard e.started(meter(), "m")
    check e.setLoaderFaultsForTests(LoaderFaults(stall: {lmRelease})).isOk
    e.shutdown()
    let r = e.awaitShutdown()
    check r.isErr and r.error.code == ecModule
    check ("failed: " & LoaderInstanceId & ", m") in r.error.message
    check e.stalledLoaderCallsForTests() == 1
    # [SPEC RUNTIME l.3863; IF l.1997, l.1999] The Loader stays ready and
    # bound while its call runs; the engine cannot close.
    check e.loaderOf.state == msReady
    check e.view("m").tryGet.failureOf == "cleanup-timeout"
    check e.tryClose().error.code == ecNotReady
    e.releaseLoaderStallForTests()
    # The late reply establishes absence; then the Loader is released.
    check waitUntil(
      proc(): bool =
        e.loaderOf.state == msUnloaded
    )
    check not e.cleanupPending("m")
    # The stored result does not change (RUN-0760).
    check e.awaitShutdown().error.message == r.error.message
    live = nil
    check e.close(initDuration(seconds = 10 * Slow))

  test "[RUN-1076] a release held at shutdown extends no authority: the consumer's route and binding end at once, and the Loader is asked only to release":
    var cfg = config()
    cfg.ordering = @[("m", "c")]
    let e = fixtureEngine(cfg)
    discard e.started(meter(), "m")
    let (_, rc) = e.startClient("c")
    let route = rc.routeId("k")
    var h = rc.handle(route)
    check h.read(5).isOk
    let journaled = e.loaderJournalForTests().len
    e.faults(LoaderFaults(stall: {lmRelease}))
    e.requestShutdown()
    check waitUntil(
      proc(): bool =
        e.stalledLoaderCallsForTests() == 1
    )
    # c's release is held; m waits for it (the ordering), the Loader for both.
    check e.view("c").tryGet.state == msStopping
    check e.view("m").tryGet.state == msReady
    check e.loaderOf.state == msReady
    # [SPEC RUNTIME l.3863] The held release delays no withdrawal and keeps
    # no authority: the route has ended, its handle and c's binding are
    # NOT_READY.
    let rec = e.routes().filterIt(it.route == route)
    check rec.len == 1 and
      rec[0].state.kind in {
        LogosNSRuntimeControlRouteStateKind.Closed,
        LogosNSRuntimeControlRouteStateKind.Failed,
      }
    check h.read(5).error.code == ecNotReady
    check rc.establish("k2").code == ecNotReady
    h.release()
    e.releaseLoaderStallForTests()
    check e.awaitShutdown().isOk
    # [plan §2.10] Only releases reached the Loader once shutdown began.
    check e.loaderJournalForTests()[journaled ..^ 1].mapIt(it.meth) ==
      @[$lmRelease, $lmRelease]
    check e.journal(lmRelease).mapIt(it.instance) == @["c", "m"]
    check e.loaderOf.state == msUnloaded
    live = nil
    check e.close()

# Lost answers ---------------------------------------------------------------------------

suite "run.loader: resolving a lost Loader answer (RUNTIME l.3793; plan §2.9) [IMPL-DECISION G252]":
  teardown:
    unhooked()

  test "[RUN-0689] a realize whose invocation failed and that made nothing fails that start alone; the Loader stays bound":
    let e = fixtureEngine(config())
    discard e.create(meter(), "m").tryGet
    e.faults(LoaderFaults(failInvocation: {lmRealize}))
    let v = e.start("m").tryGet
    check v.state == msError and v.failureOf == "other"
    check v.failure.get.reason == "the realize call failed"
    # Nothing reached the Loader's realize; get_status found nothing.
    check e.journal(lmRealize).len == 0
    check e.journal(lmGetStatus).mapIt(it.instance) == @["m"]
    check not e.cleanupPending("m") and e.loaderOf.state == msReady
    check e.start("m").tryGet.state == msReady
    e.finish()

  test "[RUN-0689] a realize whose reply was lost after it realized: get_status finds the realization and it is released":
    let e = fixtureEngine(config())
    discard e.create(meter(), "m").tryGet
    e.faults(LoaderFaults(loseReply: {lmRealize}))
    let v = e.start("m").tryGet
    check v.state == msError and v.failure.get.reason == "the realize call failed"
    check waitUntil(
      proc(): bool =
        not e.cleanupPending("m")
    )
    check e.journal(lmRealize).len == 1
    check e.journal(lmGetStatus).len == 1
    let released = e.journal(lmRelease)
    check released.len == 1 and released[0].instance == "m"
    check e.loaderOf.state == msReady
    check e.start("m").tryGet.state == msReady
    e.finish()

  test "[RUN-0689] a release whose reply was lost after it released: get_status finds nothing, and the stop completes":
    let e = fixtureEngine(config())
    discard e.started(meter(), "m")
    e.faults(LoaderFaults(loseReply: {lmRelease}))
    check e.stop("m").tryGet.state == msUnloaded
    let asked = e.journal(lmGetStatus)
    check asked.len == 1 and asked[0].instance == "m" and asked[0].realization.len > 0
    check not e.cleanupPending("m") and e.loaderOf.state == msReady
    e.finish()

  test "[RUN-0689] a release whose invocation failed before it released: get_status finds the realization, cleanup-failed":
    let e = fixtureEngine(config())
    discard e.started(meter(), "m")
    e.faults(LoaderFaults(failInvocation: {lmRelease}))
    let v = e.stop("m").tryGet
    check v.state == msError and v.failureOf == "cleanup-failed"
    check e.cleanupPending("m")
    check e.start("m").error.code == ecNotReady
    # Not a Loader failure: it stays bound and realizes others.
    check e.loaderOf.state == msReady
    discard e.started(meter(), "n")
    e.clearLoaderFaultsForTests()
    e.confirmTerminationForTests()
    e.finish()

  test "[RUN-1067] [IMPL-DECISION G252] a realize whose answer and status answer are both lost stays with its instance: error, unknown, a stop accepted; the Loader stays bound":
    let e = fixtureEngine(config())
    let (_, rc) = e.startClient("c")
    discard e.create(meter(), "m").tryGet
    e.faults(LoaderFaults(failInvocation: {lmRealize, lmGetStatus}))
    let v = e.start("m").tryGet
    check v.state == msError and v.failureOf == "other"
    check v.failure.get.reason ==
      "the Module Loader's answer was lost and could not be resolved"
    check v.execution.intent == inRequested
    let s = rc.summaryOf(e, "m")
    check s.realization.kind ==
      LogosNSRuntimeControlGetExecutionSummaryResponseRealizationChoiceKind.Unknown
    check s.failure == Opt.some("other")
    # [SPEC RUNTIME l.613] Start and recovery are NOT_READY, and so is retirement.
    check e.start("m").error.code == ecNotReady
    check e.recover("m", e.view("m").tryGet.execution.revision).error.code == ecNotReady
    check rc.retireOf(e, "m").code == ecNotReady
    # [R4] A stop is accepted: the intent is cancelled, nothing is released.
    let stopped = e.stop("m").tryGet
    check stopped.state == msError and stopped.execution.intent == inStopped
    check e.journal(lmRelease).len == 0
    # The Loader stays bound: it owns that realization, and realizes others.
    check e.loaderOf.state == msReady
    check e.stop(LoaderInstanceId).error.code == ecNotReady
    discard e.started(meter(), "n")
    e.confirmTerminationForTests()
    check not e.cleanupPending("m")
    e.finish()

# Loader loss ----------------------------------------------------------------------------

var
  terminations: Atomic[int] ## `onTerminationRequired` calls
  terminationNames: Atomic[int] ## how many instances the last one named

proc onTermination(
    data: pointer, unresolved: seq[string]
) {.nimcall, gcsafe, raises: [].} =
  discard terminations.fetchAdd(1)
  terminationNames.store(unresolved.len)

proc lossConfig(): EngineConfig =
  result = config()
  result.onTerminationRequired = onTermination
  terminations.store(0)
  terminationNames.store(0)

suite "run.loader: Loader loss (RUNTIME l.3813-3825; plan §2.11) [IMPL-DECISION G246] [IMPL-DECISION G249]":
  teardown:
    unhooked()

  test "[RUN-1067] [RUN-1068] [RUN-1069] [RUN-1070] [RUN-1072] [LDR-0161] [LDR-0162] [RUN-0690] [RUN-0701] the Loader reports its failure: what it realized is error, its routes fail, intent stays, nothing is released or started, and the host must end its process":
    let e = fixtureEngine(lossConfig())
    discard e.started(meter(), "m")
    let (_, rc) = e.startClient("c")
    let route = rc.routeId("k")
    discard e.create(meter(), "u").tryGet
    let realizes = e.journal(lmRealize).len
    e.faults(LoaderFaults(reportFailure: true))
    let l = e.loaderOf
    check l.state == msError and l.failureOf == "reported-by-module"
    for id in ["m", "c"]:
      let v = e.view(id).tryGet
      check v.state == msError and v.failureOf == "other"
      check v.failure.get.reason == "its Module Loader failed"
      check v.execution.intent == inRequested and v.intentOrigin.host
      check e.cleanupPending(id)
    check e.view("u").tryGet.state == msUnloaded
    let rec = e.routes().filterIt(it.route == route)
    check rec.len == 1 and
      rec[0].state.kind == LogosNSRuntimeControlRouteStateKind.Failed
    # [RUN-1070] No start reaches the Loader.
    for id in ["m", "c", "u"]:
      check e.start(id).error.code == ecNotReady
    check e.recover("m", e.view("m").tryGet.execution.revision).error.code == ecNotReady
    check e.journal(lmRealize).len == realizes
    # The Loader still owns them; nothing released them.
    check e.stop(LoaderInstanceId).error.code == ecNotReady
    check e.journal(lmRelease).len == 0
    # [IMPL-DECISION G249] Termination required, once, in the diagnostics too.
    check terminations.load == 1 and terminationNames.load == 2
    check e.diagnostics().anyIt("termination required" in it)
    e.requestShutdown()
    let r = e.awaitShutdown()
    check r.isErr and r.error.code == ecModule
    check ("failed: " & LoaderInstanceId & ", m, c;") in r.error.message
    check "the host process must end" in r.error.message
    let refused = e.tryClose()
    check refused.isErr and refused.error.code == ecNotReady
    check "the host process must end" in refused.error.message
    check terminations.load == 1
    # The protected mechanism confirms the end: absence, still `error`.
    e.confirmTerminationForTests()
    check e.journal(lmRelease).mapIt(it.instance).sorted == @["c", "m"]
    check e.view("m").tryGet.state == msError and not e.cleanupPending("m")
    live = nil
    check e.close(initDuration(seconds = 10 * Slow))

  test "[R4] a stop of an instance the lost Loader owned is accepted: intent cancelled, still error, nothing released":
    let e = fixtureEngine(lossConfig())
    discard e.started(meter(), "m")
    e.faults(LoaderFaults(reportFailure: true))
    let v = e.stop("m").tryGet
    check v.state == msError and v.execution.intent == inStopped
    check v.failure.get.reason == "its Module Loader failed"
    check e.journal(lmRelease).len == 0 and e.cleanupPending("m")
    e.confirmTerminationForTests()
    e.finish()

  test "[IMPL-DECISION G252] an invalid realize response fails the Loader; the realization it made is orphaned, never used":
    let e = fixtureEngine(lossConfig())
    discard e.create(meter(), "m").tryGet
    e.faults(LoaderFaults(garble: {lmRealize}))
    let v = e.start("m").tryGet
    check v.state == msError and v.failure.get.reason == "its Module Loader failed"
    let l = e.loaderOf
    check l.state == msError and l.failureOf == "other"
    check l.failure.get.reason == "the Module Loader gave an invalid response"
    check e.diagnostics().anyIt("invalid response" in it)
    check e.journal(lmRealize).len == 1 and e.journal(lmRelease).len == 0
    check terminations.load == 1
    e.confirmTerminationForTests()
    check e.journal(lmRelease).mapIt(it.instance) == @["m"]
    e.finish()

  test "[RUN-1068] a Loader that fails while a realize is held: the late realization is recorded unresolved, never used":
    let e = fixtureEngine(lossConfig())
    discard e.create(meter(), "m").tryGet
    e.faults(LoaderFaults(stall: {lmRealize}))
    startReply.store(-2)
    var t: Thread[(Engine, string)]
    createThread(t, startOn, (e, "m"))
    check waitUntil(
      proc(): bool =
        e.stalledLoaderCallsForTests() == 1
    )
    e.faults(LoaderFaults(reportFailure: true))
    joinThread(t)
    check startReply.load == ord(msError)
    check e.view("m").tryGet.failure.get.reason == "its Module Loader failed"
    e.releaseLoaderStallForTests()
    check waitUntil(
      proc(): bool =
        e.stalledLoaderCallsForTests() == 0
    )
    check e.view("m").tryGet.state == msError and e.cleanupPending("m")
    check e.journal(lmRelease).len == 0
    # Its id was recorded: the confirmation releases it.
    e.confirmTerminationForTests()
    check e.journal(lmRelease).mapIt(it.instance) == @["m"]
    e.finish()

  test "[RUN-0702] [IMPL-DECISION G246] a Loader that fails owning nothing is released; every later start is NOT_READY":
    let e = fixtureEngine(lossConfig())
    discard e.create(meter(), "m").tryGet
    e.faults(LoaderFaults(reportFailure: true))
    check waitUntil(
      proc(): bool =
        not e.cleanupPending(LoaderInstanceId)
    )
    check e.loaderOf.state == msError
    let refused = e.start("m")
    check refused.error.code == ecNotReady and "has failed" in refused.error.message
    check e.journal(lmRealize).len == 0
    check terminations.load == 0
    e.requestShutdown()
    check e.awaitShutdown().isOk
    live = nil
    check e.close(initDuration(seconds = 10 * Slow))
