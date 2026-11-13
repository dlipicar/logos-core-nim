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

import std/[atomics, monotimes, os, sequtils, strutils, times, typedthreads]
import unittest2
import ../src/logos_core/runtime/engine
import ../src/logos_core/abi/[checks, types]
import ../src/logos_core/runtime/invoke
import ../src/logos_core/cbor
import ../src/logos_core/commitment
import ../src/logos_core/iface/[accept, outcome, provider, surface]
import ../src/logos_core/iface/common_types
import ../src/logos_core/loader/contract
import ../src/logos_core/pins
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

  test "[BCP-0023] [BCP-0024] [LDR-0097] [RUN-1071] [RUN-0814] each start is a realize with the accepted record, each stop a release of that realization, and every realization id is fresh":
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
    # Two realizations per engine, and a new engine's Loader issues new ids.
    check ids.len == 4 and ids.deduplicate.len == 4

  test "[LDR-0027] [LDR-0087] a start the policy denies sends nothing to the Loader":
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

# Shutdown -------------------------------------------------------------------------------

suite "run.loader: shutdown (RUNTIME §10.2 l.3847-3864)":
  teardown:
    leftover()

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
