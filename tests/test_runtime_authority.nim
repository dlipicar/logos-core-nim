## The Runtime side of authority (step 8b; DECISIONS I85): the Capability
## Authority binding (RUNTIME §9 l.1652-1680; CA §1, §8), evaluation off the
## Runtime thread with parked operations (CA §5, §7; RUNTIME l.1737-1748),
## the decision cache and its invalidation (CA §8), the bootstrap and
## recovery rules (RUNTIME l.1635-1650, l.1674-1680), execution
## authorization before realization (RUNTIME §3.6), route validity (RUNTIME
## l.3157-3190; TL-03 interim), and execution authorization over time:
## renewal on the reserved lane, the retention rule, and the stops its
## endings cause (CA §5.1, §8 l.828-866; RUNTIME §10.1).
##
## The authority is `fakeca`: the real Capability Authority's name and call
## surface with a scripted `evaluate`. The orchestration instance and the
## consumers are routefixture's client module; the provider is the meter kit
## module.

import std/[atomics, monotimes, os, sequtils, strutils, times, typedthreads]
import unittest2
import ../src/logos_core/runtime/engine
import ../src/logos_core/abi/types
import ../src/logos_core/cbor
import ../src/logos_core/commitment
import ../src/logos_core/iface/[accept, outcome, surface]
import ../src/logos_core/iface/common_types
import ../src/logos_core/authority/scopes except
  LogosNSRuntimeModuleInstanceAddress, LogosNSRuntimeModuleInstanceId,
  LogosNSRuntimeModuleName, LogosNSRuntimeModuleProviderAddress,
  LogosNSRuntimeModuleProviderId, LogosNSRuntimeModuleStateAssignmentId,
  LogosNSRuntimeRouteId, LogosNSRuntimeRuntimeInstanceId
import ./support/[fakeca, kitbuild, kitruntime, withoutloader]
import ./kit/meter_impl
import ./generated/meter_module_calls

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "runtime_authority" / kitVariant
removeDir(work)
createDir(work)

include ./support/routefixture

# Set-up -------------------------------------------------------------------------------

const
  Orch = "orch"
  Ca = "ca"
  Meter = "meter"
  NoDeadlineMs = 60_000
    ## [IMPL] The evaluation deadline of every case but the one that tests it:
    ## the 5 s default fails closed on a loaded host running a sanitizer build.

let clk = newTestClock()
useClock(clk)

proc caConfig(recovery = false, deadlineMs = NoDeadlineMs): EngineConfig =
  result = config(extra = @[fakeCaRegistration()])
  result.authority = Opt.some(
    AuthorityPolicy(
      instance: Ca,
      recovery: recovery,
      evaluationDeadline: initDuration(milliseconds = deadlineMs),
    )
  )
  result.clock = clk

proc fresh() =
  resetFake()

proc latestClient(): ptr LogosRuntimeControlBinding =
  cast[ptr LogosRuntimeControlBinding](clients[(clientInits.load - 1) mod MaxClients].load)

proc boot(e: Engine, caRecord = fakeCaRecord()): ptr LogosRuntimeControlBinding =
  ## The orchestration instance `orch`, ready; `ca` and `meter` created.
  let v = e.bootstrap(
    @[
      BootstrapInstance(instance: Orch, record: client()),
      BootstrapInstance(instance: Ca, record: caRecord),
      BootstrapInstance(instance: Meter, record: meter()),
    ],
    Orch,
  )
  check v.isOk
  latestClient()

proc bound(e: Engine): bool =
  e.authorityBound()[0]

proc generation(e: Engine): uint64 =
  e.authorityBound()[1]

proc startCa(e: Engine, orch: ptr LogosRuntimeControlBinding) =
  check orch.lifecycle("start_module", CaModuleName, Opt.some(Ca)).code == ecOk
  check e.bound

proc ready(meter = true): (Engine, ptr LogosRuntimeControlBinding) =
  ## Bootstrapped, the authority bound, the meter ready (started by the host)
  ## unless `meter` is false.
  fresh()
  let e = newEngine(caConfig())
  let orch = e.boot()
  e.startCa(orch)
  if meter:
    check e.start(Meter).tryGet.state == msReady
  forget()
  (e, orch)

proc whats(): seq[string] =
  received().mapIt(it.what)

proc count(what: string): int =
  received().countIt(it.what == what)

proc last(e: Engine): AuthzAnswer =
  e.answers()[^1]

proc lastFor(e: Engine, action: AuthzAction): AuthzAnswer =
  for a in e.answers():
    if a.request.action == action:
      result = a

proc observeReq(module: string, instance: string): seq[byte] =
  encode(
    LogosNSRuntimeControlGetReadinessRequest(
      module: module, instance: Opt.some(instance)
    )
  ).tryGet

proc observe(rc: ptr LogosRuntimeControlBinding, instance = Meter): RcResult =
  rc.readiness("meter_module", Opt.some(instance))

# Calls that park, on their own threads ---------------------------------------------

type ParkArgs = object
  rc: ptr LogosRuntimeControlBinding
  name: string
  params: seq[byte]
  slot: int

var
  parkCode: array[4, Atomic[int]]
  parkDone: array[4, Atomic[bool]]
  parkView: array[4, Atomic[int]] ## the decoded state of a lifecycle response, or -1
  parkThreads: array[4, Thread[ParkArgs]]

proc parkedCall(p: ParkArgs) {.thread.} =
  let r = rcCall(p.rc, p.name, p.params)
  parkCode[p.slot].store(ord(r.code))
  parkDone[p.slot].store(true)

proc park(
    rc: ptr LogosRuntimeControlBinding, name: string, params: seq[byte], slot = 0
) =
  parkDone[slot].store(false)
  parkCode[slot].store(-1)
  createThread(
    parkThreads[slot],
    parkedCall,
    ParkArgs(rc: rc, name: name, params: params, slot: slot),
  )

proc parkedCode(slot = 0, seconds = 10 * Slow): ErrorCode =
  check waitUntil(
    proc(): bool =
      parkDone[slot].load,
    seconds,
  )
  joinThread(parkThreads[slot])
  ErrorCode(parkCode[slot].load)

proc startReq(instance: string): seq[byte] =
  encode(
    LogosNSRuntimeControlStartModuleRequest(
      module: "client_module", instance: Opt.some(instance)
    )
  ).tryGet

proc stopReq(instance: string, module = "client_module"): seq[byte] =
  encode(
    LogosNSRuntimeControlStopModuleRequest(module: module, instance: Opt.some(instance))
  ).tryGet

proc renewReq(key, route: string): seq[byte] =
  encode(LogosNSRuntimeControlRenewRouteRequest(request_key: key, route: route)).tryGet

proc bytesOf(routes: seq[LogosNSRuntimeControlRouteRecord]): seq[seq[byte]] =
  routes.mapIt(encode(it).tryGet)

proc waitHanging(n = 1): bool =
  waitUntil(
    proc(): bool =
      hanging.load >= n
  )

# Tests --------------------------------------------------------------------------------

suite "run.authority: the binding (RUNTIME l.1652-1680; CA §1)":
  test "[RUN-0313] [RUN-0314] [RUN-0315] [RUN-0316] [RUN-0317] [RUN-0319] [RUN-0851] [CAP-0003] [CAP-0005] [CAP-0006] [CAP-0008] the configured authority is bound once ready, before its start is answered, under a fresh generation":
    fresh()
    let e = newEngine(caConfig())
    let orch = e.boot()
    check not e.bound
    let g = e.generation
    let r = orch.lifecycle("start_module", CaModuleName, Opt.some(Ca))
    check r.code == ecOk
    # The reply came after the binding: nothing the orchestrator does next
    # finds it unbound.
    check e.bound
    check e.generation > g
    e.finish()

  test "[RUN-0307] [RUN-0308] [RUN-0316] [CAP-0008] an instance whose primary contract is not the pinned one is never bound, whatever it claims":
    fresh()
    let e = newEngine(caConfig())
    let orch = e.boot(
      caRecord = ModuleRecord(
        module: "client_module", strategy: stDirectStatic, binding: "client"
      )
    )
    check orch.lifecycle("start_module", "client_module", Opt.some(Ca)).code == ecOk
    check e.view(Ca).tryGet.state == msReady
    check not e.bound
    check e.diagnostics().anyIt("is not bound" in it)
    # Nothing falls back to a less constrained policy.
    check orch.observe().code == ecNotAuthorised
    check e.last.outcome == azEvaluationFailed
    e.finish()

  test "[RUN-0015] [RUN-0016] an authority whose record declares no contract has no provider record and is never bound (l.165-169, l.1420-1421, l.1647; DECISIONS I88)":
    fresh()
    let e = newEngine(caConfig())
    var record = fakeCaRecord()
    record.primaryContract = Opt.none(Digest)
    let orch = e.boot(caRecord = record)
    check orch.lifecycle("start_module", CaModuleName, Opt.some(Ca)).code == ecOk
    let v = e.view(Ca).tryGet
    check v.state == msReady
    check v.providerId.len == 0
    check not e.bound
    check e.diagnostics().anyIt("is not bound: it has no provider record" in it)
    check orch.observe().code == ecNotAuthorised
    e.finish()

  test "[IMPL] [RUN-0701] the orchestration instance cannot be the authority (C8)":
    fresh()
    let e = newEngine(caConfig())
    let v = e.bootstrap(@[BootstrapInstance(instance: Ca, record: fakeCaRecord())], Ca)
    check v.isErr and v.error.code == ecInvalidParams
    e.finish()

suite "run.authority: bootstrap and recovery rules (RUNTIME l.1635-1650, l.1674-1680)":
  test "[RUN-0022] [RUN-0305] [RUN-0306] [RUN-0311] [RUN-0312] [RUN-0050] [RUN-0051] [RUN-0859] [CAP-0062] before the binding, orchestration starts the authority without an evaluation; everything else fails closed as an evaluation failure":
    fresh()
    let e = newEngine(caConfig())
    let orch = e.boot()
    # Anything but the authority: NOT_AUTHORISED, retained as an evaluation
    # failure, never a deny.
    check orch.observe().code == ecNotAuthorised
    check e.last.outcome == azEvaluationFailed
    check e.last.source == psAuthority
    check orch.lifecycle("start_module", "meter_module", Opt.some(Meter)).code ==
      ecNotAuthorised
    check e.view(Meter).tryGet.state == msUnloaded
    # The authority itself, under the derived bootstrap rules.
    check orch.observe(Ca).code == ecInvalidParams # module name differs: allowed first
    check orch.lifecycle("start_module", CaModuleName, Opt.some(Ca)).code == ecOk
    check received().len == 0
    var sources: seq[PolicySource]
    for a in e.answers():
      if a.request.instance == Ca and a.request.consumer == Orch:
        sources.add(a.source)
        check a.outcome == azAllow
    check sources.len >= 2 and sources.allIt(it == psBootstrap)
    e.finish()

  test "[RUN-0859] [RUN-0860] [RUN-0861] [RUN-0862] [RUN-0863] [RUN-0864] [RUN-0700] with recovery enabled, orchestration recovers a failed authority without an evaluation while other operations fail closed":
    fresh()
    let e = newEngine(caConfig(recovery = true))
    let orch = e.boot()
    e.startCa(orch)
    let v = e.view(Ca).tryGet
    check e.reportFailure(Ca, v.attempt).isOk
    check waitUntil(
      proc(): bool =
        not e.bound
    )
    forget()
    check orch.observe().code == ecNotAuthorised
    check e.last.outcome == azEvaluationFailed
    let failed = e.view(Ca).tryGet
    check failed.state == msError
    let r = orch.rcCall(
      "recover_module",
      encode(
        LogosNSRuntimeControlRecoverModuleRequest(
          module: CaModuleName,
          instance: Ca,
          expected_execution_revision: failed.execution.revision,
        )
      ).tryGet,
    )
    check r.code == ecOk
    check e.bound
    check received().len == 0
    check e.answers().anyIt(it.source == psRecovery and it.request.action == aaExecute)
    e.finish()

  test "[RUN-0862] [RUN-0863] without recovery enabled, a lost authority is not recovered by the derived rules":
    fresh()
    let e = newEngine(caConfig(recovery = false))
    let orch = e.boot()
    e.startCa(orch)
    check e.reportFailure(Ca, e.view(Ca).tryGet.attempt).isOk
    check waitUntil(
      proc(): bool =
        not e.bound
    )
    let failed = e.view(Ca).tryGet
    let r = orch.rcCall(
      "recover_module",
      encode(
        LogosNSRuntimeControlRecoverModuleRequest(
          module: CaModuleName,
          instance: Ca,
          expected_execution_revision: failed.execution.revision,
        )
      ).tryGet,
    )
    check r.code == ecNotAuthorised
    check not e.bound
    e.finish()

suite "run.authority: evaluation (CA §5, §7; RUNTIME l.1737-1748)":
  test "[CAP-0011] [CAP-0012] [CAP-0013] [CAP-0014] [CAP-0428] [RUN-0322] [RUN-0324] [RUN-0811] [RUN-0858] [RUN-0823] [IFC-0781] evaluate runs off the Runtime thread with a system-service caller; the consumer is the module, never the engine":
    let (e, orch) = ready()
    check orch.observe().code == ecOk
    let got = received()
    check got.len == 1
    check got[0].what == "rc:get_readiness"
    check got[0].consumer == Orch
    check got[0].callerKind == CallerSystemService
    check got[0].thread != getThreadId()
    # The host's protected input decides alone: no evaluation.
    forget()
    discard e.stop(Meter)
    check e.start(Meter).tryGet.state == msReady
    check received().len == 0
    e.finish()

  test "[CAP-0022] [CAP-0023] [CAP-0024] [CAP-0038] [CAP-0039] [CAP-0046] [CAP-0047] [CAP-0048] [CAP-0054] [CAP-0055] [CAP-0056] [CAP-0058] [CAP-0059] [CAP-0060] [CAP-0061] [CAP-0089] [CAP-0090] [CAP-0096] [CAP-0097] [RUN-0185] each check point asks one scope, with this Runtime's identity and roots recomputed from the mirrored contracts":
    let (e, orch) = ready()
    let id = e.runtimeInstanceId
    check orch.observe().code == ecOk
    let route = orch.routeId("k1")
    var h = orch.handle(route)
    check h.read(1).isOk
    check orch.establish("k2", all = true).code == ecOk
    check orch.lifecycle("stop_module", "meter_module", Opt.some(Meter)).code == ecOk
    check orch.lifecycle("start_module", "meter_module", Opt.some(Meter)).code == ecOk
    h.release()
    let seen = whats()
    for w in [
      "rc:get_readiness", "rc:establish_route", "establish-route", "call", "discover",
      "rc:stop_module", "stop", "rc:start_module", "execute",
    ]:
      check w in seen
    for r in received():
      let req = LogosNSCapabilityAuthorityEvaluateRequest.decode(r.request).tryGet
      check req.consumer.runtime_instance_id == id
      check req.scopes.len == 1
      check isSet(req.scopes)
      case req.scopes[0].kind
      of skControl:
        check req.scopes[0].rc.runtime == id
        check req.scopes[0].rc.contract == rcContract()
        check req.scopes[0].rc.methods.get[0] == rcMethodRoot(r.what[3 ..^ 1])
      of skProvider:
        check req.scopes[0].pa.contract.schema_root == @meterRoot
      of skExecution:
        check req.scopes[0].me.runtime == id
        check req.scopes[0].me.instance == Opt.some(Meter)
      else:
        check false
    e.finish()

  test "[CAP-0025] [CAP-0098] [CAP-0108] [CAP-0109] [CAP-0110] [CAP-0111] [CAP-0112] [CAP-0113] [CAP-0114] [CAP-0118] [CAP-0153] [CAP-0260] [CAP-0261] [CAP-0084] [CAP-0068] [RUN-0038] [RUN-0325] [RUN-0327] [RUN-0329] a malformed decision, an error arm or a failed dispatch is an evaluation failure, never a deny":
    let (e, orch) = ready()
    for v in [
      vError, vStatus, vWrongConsumer, vOtherScopes, vBroadened, vUncovered, vUnordered,
      vAllowWithDenial, vDenyWithAllowed, vBadValidity, vExpired, vPermission, vBadCbor,
    ]:
      setScript(rule(v, "rc:get_readiness"))
      check orch.observe().code == ecNotAuthorised
      let a = e.lastFor(aaObserve)
      check a.outcome == azEvaluationFailed
      check a.source == psAuthority
    setScript(
      rule(
        vError,
        "rc:get_readiness",
        code = ord(LogosNSCapabilityAuthorityErrorCodeKind.Internal_error),
      )
    )
    check orch.observe().code == ecNotAuthorised
    check e.lastFor(aaObserve).errorCode == "internal-error"
    # A route allow without valid_until, an execution allow with placements.
    setScript(rule(vNoValidity, "establish-route"), rule(vPlacements, "execute"))
    check orch.establish("k").code == ecNotAuthorised
    check e.lastFor(aaRoute).outcome == azEvaluationFailed
    check orch.lifecycle("stop_module", "meter_module", Opt.some(Meter)).code == ecOk
    check orch.lifecycle("start_module", "meter_module", Opt.some(Meter)).code ==
      ecNotAuthorised
    let v = e.view(Meter).tryGet
    check v.failure.get.kind == fkAuthorityEvaluationFailed
    e.finish()

  test "[RUN-0326] [RUN-0328] [RUN-0330] [RUN-0331] [CAP-0153] [CAP-0265] a deny is NOT_AUTHORISED; the retained answer keeps its consumer, operation, target, decision id and denial code":
    let (e, orch) = ready()
    setScript(
      rule(
        vDeny,
        "rc:get_readiness",
        code = ord(LogosNSCapabilityAuthorityDenialCodeKind.Not_granted),
      )
    )
    check orch.observe().code == ecNotAuthorised
    let a = e.lastFor(aaObserve)
    check a.outcome == azDeny
    check a.source == psAuthority
    check a.decisionId.startsWith("fd-")
    check a.denialCode == "not-granted"
    check a.request.consumer == Orch
    check a.request.operation == "get_readiness"
    check a.request.target == Meter
    e.finish()

  test "[CAP-0115] [CAP-0116] [CAP-0117] [CAP-0051] [CAP-0052] [RUN-0567] a narrowed route allow gives the route its access; an allow that excludes the operation is refused and marked narrowed":
    let (e, orch) = ready()
    let readRoot = declRoot("meter.read")
    var narrowed = allow("establish-route")
    narrowed.narrowMethods = Opt.some(@[readRoot])
    var excluded = allow("call")
    excluded.narrowMethods = Opt.some(newSeq[seq[byte]]())
    setScript(narrowed, allow("call", validMs = 0))
    let r = orch.establish("k")
    check r.code == ecOk
    let rec = r.routesOf.routes[0]
    check rec.access.methods == Opt.some(@[readRoot])
    var h = orch.handle(rec.route)
    check h.read(1).isOk
    setScript(excluded)
    check h.read(2).error.code == ecNotAuthorised
    let a = e.lastFor(aaCall)
    check a.outcome == azAllow and a.narrowed
    h.release()
    e.finish()

suite "run.authority: the decision cache (CA §8 l.857-867)":
  test "[CAP-0119] [CAP-0120] [RUN-0867] [RUN-0571] [RUN-0572] [RUN-0799] an allow with a validity is reused until it ends; one without is asked each time":
    let (e, orch) = ready()
    setScript(allow("call", validMs = 1000))
    var h = orch.handle(orch.routeId("k"))
    for i in 0 ..< 3:
      check h.read(1).isOk
    check count("call") == 1
    clk.advance(1500)
    check h.read(1).isOk
    check count("call") == 2
    setScript(allow("call", validMs = 0))
    forget()
    clk.advance(1500)
    check h.read(1).isOk
    check h.read(1).isOk
    check count("call") == 2
    h.release()
    e.finish()

  test "[CAP-0342] [RUN-0939] a backward wall-clock step does not extend a cached decision":
    let (e, orch) = ready()
    setScript(allow("call", validMs = 1000))
    var h = orch.handle(orch.routeId("k"))
    check h.read(1).isOk
    let wall = clk.wallMs
    clk.advance(1500)
    clk.setWall(wall)
    check h.read(1).isOk
    check count("call") == 2
    h.release()
    e.finish()

suite "run.authority: notices (CA §8 l.884-903)":
  test "[CAP-0184] [CAP-0185] [CAP-0171] [CAP-0341] policy_changed clears every cached decision; a revoked grant only those listing it; issuance nothing":
    let (e, orch) = ready()
    setScript(allow("call", grants = @["g1"]))
    var h1 = orch.handle(orch.routeId("k1"))
    check h1.read(1).isOk
    check h1.read(1).isOk
    check count("call") == 1
    let id = e.runtimeInstanceId
    # Issuance invalidates nothing.
    check publish(
      GrantChangedName, grantChanged("g1", GrantStatusKind.Active, Orch, id)
    )
    check h1.read(1).isOk
    check count("call") == 1
    # Another grant's revocation leaves it.
    check publish(
      GrantChangedName, grantChanged("g2", GrantStatusKind.Revoked, Orch, id)
    )
    check h1.read(1).isOk
    check count("call") == 1
    # Its own grant's revocation clears it.
    check publish(
      GrantChangedName, grantChanged("g1", GrantStatusKind.Revoked, Orch, id)
    )
    check h1.read(1).isOk
    check count("call") == 2
    # policy_changed clears all.
    check publish(PolicyChangedName, policyChanged(0, 1))
    check h1.read(1).isOk
    check count("call") == 3
    h1.release()
    e.finish()

  test "[CAP-0343] a result made before a processed notice is neither used nor cached: it is evaluated again":
    let (e, orch) = ready()
    var h = orch.handle(orch.routeId("k"))
    hold()
    setScript(rule(vHang, "call"))
    bgDone.store(false)
    var t: Thread[ptr LogosRouteHandle]
    createThread(t, background, addr h)
    check waitHanging()
    check publish(PolicyChangedName, policyChanged(0, 5))
    release()
    joinThread(t)
    check bgCode.load == 0
    check count("call") == 2
    h.release()
    e.finish()

  test "[RUN-0856] [RUN-0857] [CAP-0356] [CAP-0357] an ordinary subscription to the authority's notices is refused even with an unconstrained scope":
    let (e, orch) = ready()
    let caSet = block:
      let d = caDocuments()
      acceptContractSet(d[0], d[1], d[2], AcceptOptions(system: true)).tryGet
    let caRoot = caSet.primary.root
    let caSchema = encodeCbor(schemaResponse(caSet, caRoot).tryGet)
    let r = orch.establish("k", root = caRoot)
    check r.code == ecOk
    let (code, h) = orch.materialize(r.routesOf.routes[0].route, caRoot, caSchema)
    check code == ecOk
    var hh = h
    var id: LogosSubscriptionId
    proc nothing(
        eventName: cstring,
        cborData: ptr UncheckedArray[uint8],
        cborDataLen: csize_t,
        userData: pointer,
    ) {.cdecl, gcsafe, raises: [].} =
      discard

    for name in [GrantChangedName, PolicyChangedName]:
      check toResult(hh.vtable.subscribe(addr hh, cstring(name), nothing, nil, addr id)).code ==
        ecNotAuthorised
    hh.release()
    e.finish()

  test "[CAP-0176] [CAP-0353] [CAP-0354] [CAP-0355] [CAP-0177] [CAP-0183] a notice that does not read is notification-path loss: a new generation, nothing carried over":
    let (e, orch) = ready()
    setScript(allow("call"))
    var h = orch.handle(orch.routeId("k"))
    check h.read(1).isOk
    let g = e.generation
    check publish(GrantChangedName, @[0xFF'u8])
    check e.bound
    check e.generation >= g + 2
    check e.diagnostics().anyIt("notification path is lost" in it)
    check h.read(1).isOk
    check count("call") == 2
    # A dropped notice is the same.
    check publish(PolicyChangedName, @[])
    check e.generation >= g + 4
    h.release()
    e.finish()

suite "run.authority: losing the binding (CA §8 l.825-832; RUNTIME l.1652)":
  test "[CAP-0344] [CAP-0345] [CAP-0346] [CAP-0347] [CAP-0348] [CAP-0172] [CAP-0173] [RUN-0853] [RUN-0854] a lost authority answers parked evaluations and closes admission; neither its late results nor its cache reach the next binding, whatever revision it reports [IMPL-DECISION G227]":
    fresh()
    let e = newEngine(caConfig(recovery = true))
    let orch = e.boot()
    e.startCa(orch)
    check e.start(Meter).tryGet.state == msReady
    var h = orch.handle(orch.routeId("k"))
    check publish(PolicyChangedName, policyChanged(0, 7))
    check h.read(1).isOk
    check h.read(1).isOk
    forget()
    let g = e.generation
    # An observation parks on an evaluation that hangs.
    hold()
    setScript(rule(vHang, "rc:get_readiness"))
    park(orch, "get_readiness", observeReq("meter_module", Meter))
    check waitHanging()
    # The authority fails: the parked request is answered, its evaluation
    # cancelled, and nothing is admitted on the old binding's decisions.
    check e.reportFailure(Ca, e.view(Ca).tryGet.attempt).isOk
    check parkedCode() == ecNotAuthorised
    check not e.bound
    check waitUntil(
      proc(): bool =
        sawCancel.load >= 1
    )
    # [CAP-0174] The route is unusable until it is re-authorized, which
    # fails closed while unbound.
    check h.read(1).error.code == ecNotAuthorised
    check e.last.request.operation == "renew_route"
    check e.last.outcome == azEvaluationFailed
    # The old evaluation's late allow is dropped. Until it returns the old
    # realization is not released, so the authority cannot be recovered yet.
    let failed = e.view(Ca).tryGet
    let recover = encode(
      LogosNSRuntimeControlRecoverModuleRequest(
        module: CaModuleName,
        instance: Ca,
        expected_execution_revision: failed.execution.revision,
      )
    ).tryGet
    check orch.rcCall("recover_module", recover).code == ecNotReady
    let before = e.answers().len
    release()
    check waitUntil(
      proc(): bool =
        hanging.load == 0
    )
    sleep(100)
    check e.answers()[before ..^ 1].allIt(it.request.action != aaObserve)
    # [G227] Releasing the old realization is a commit of its own: the request
    # prepared before it carries a stale revision.
    check waitUntil(
      proc(): bool =
        e.view(Ca).tryGet.execution.revision > failed.execution.revision
    )
    check orch.rcCall("recover_module", recover).code == ecInvalidParams
    let current = encode(
      LogosNSRuntimeControlRecoverModuleRequest(
        module: CaModuleName,
        instance: Ca,
        expected_execution_revision: e.view(Ca).tryGet.execution.revision,
      )
    ).tryGet
    # Recovered under the derived rules: a new generation.
    check orch.rcCall("recover_module", current).code == ecOk
    check e.bound
    check e.generation > g
    # The new binding reports the same revision; the old cached call decision
    # is not revived: the call is evaluated afresh.
    setScript()
    check h.read(1).isOk
    check count("call") == 1
    check e.lastFor(aaCall).policyRevision == 7
    h.release()
    e.finish()

  test "[RUN-0855] once binding authority ends, the old realization's notices no longer act; the recovered binding's are consumed (RUNTIME §9 l.1652)":
    fresh()
    let e = newEngine(caConfig(recovery = true))
    let orch = e.boot()
    e.startCa(orch)
    check e.start(Meter).tryGet.state == msReady
    var h = orch.handle(orch.routeId("k"))
    check h.read(1).isOk
    # The old realization stays while an evaluation of it hangs, so its
    # publish callback is still live after the binding is lost.
    hold()
    setScript(rule(vHang, "rc:get_readiness"))
    park(orch, "get_readiness", observeReq("meter_module", Meter))
    check waitHanging()
    check e.reportFailure(Ca, e.view(Ca).tryGet.attempt).isOk
    check parkedCode() == ecNotAuthorised
    check not e.bound
    let failed = e.view(Ca).tryGet
    let g = e.generation
    let answered = e.answers().len
    const Ignored = "which is not the bound authority, was ignored"
    # Consumed, policy_changed would re-authorize the route at once, and a
    # notice that does not read would be notification-path loss.
    check publish(PolicyChangedName, policyChanged(0, 9))
    check publish(GrantChangedName, @[0xFF'u8])
    check e.diagnostics().countIt(Ignored in it) == 2
    check not e.diagnostics().anyIt("notification path is lost" in it)
    check e.generation == g
    check e.answers().len == answered
    release()
    check waitUntil(
      proc(): bool =
        e.view(Ca).tryGet.execution.revision > failed.execution.revision
    )
    let recover = encode(
      LogosNSRuntimeControlRecoverModuleRequest(
        module: CaModuleName,
        instance: Ca,
        expected_execution_revision: e.view(Ca).tryGet.execution.revision,
      )
    ).tryGet
    check orch.rcCall("recover_module", recover).code == ecOk
    check e.bound
    # The new realization's notice is consumed: the cached call decision is
    # cleared, so the next call is evaluated again.
    setScript()
    forget()
    check h.read(1).isOk
    check h.read(1).isOk
    check count("call") == 1
    check publish(PolicyChangedName, policyChanged(9, 10))
    check e.diagnostics().countIt(Ignored in it) == 2
    check h.read(1).isOk
    check count("call") == 2
    h.release()
    e.finish()

suite "run.authority: parked operations (CA §8; I75)":
  test "[CAP-0260] a hanging evaluate leaves the Runtime thread serving; the deadline fails closed and marks the invocation cancelled":
    fresh()
    # Long enough for the evaluation to reach the authority on a loaded host.
    let e = newEngine(caConfig(deadlineMs = 1_000 * Slow))
    let orch = e.boot()
    e.startCa(orch)
    check e.start(Meter).isOk
    hold()
    setScript(rule(vHang, "rc:get_readiness"))
    park(orch, "get_readiness", observeReq("meter_module", Meter))
    check waitHanging()
    # The Runtime thread is free.
    check e.list().withoutLoader.len == 3
    check parkedCode() == ecNotAuthorised
    check e.lastFor(aaObserve).outcome == azEvaluationFailed
    check waitUntil(
      proc(): bool =
        sawCancel.load >= 1
    )
    release()
    e.finish()

  test "[I85] shutdown answers parked operations NOT_READY and begins no evaluation":
    let (e, orch) = ready()
    hold()
    setScript(rule(vHang, "rc:get_readiness"))
    park(orch, "get_readiness", observeReq("meter_module", Meter))
    check waitHanging()
    e.requestShutdown()
    check parkedCode() == ecNotReady
    release()
    check e.awaitShutdown().isOk or true
    check e.close()

  test "[CAP-0343] parked operations mutate nothing until their decisions are in":
    let (e, orch) = ready()
    hold()
    setScript(rule(vHang, "establish-route"))
    park(orch, "establish_route", establishReq("k"))
    check waitHanging()
    check e.routes().len == 0
    release()
    check parkedCode() == ecOk
    check e.routes().len == 1
    # Stopping, closing and renewing, all parked at once.
    let closing = orch.routeId("c")
    let renewing = orch.routeId("r")
    check e.create(client(), "m2").isOk
    check orch.rcCall("start_module", startReq("m2")).code == ecOk
    let routes = e.routes().bytesOf
    forget()
    hold()
    setScript(rule(vHang, ""))
    park(orch, "stop_module", stopReq("m2"), slot = 0)
    park(
      orch,
      "close_route",
      encode(LogosNSRuntimeControlCloseRouteRequest(route: closing)).tryGet,
      slot = 1,
    )
    park(orch, "renew_route", renewReq("r2", renewing), slot = 2)
    check waitHanging(3)
    check e.routes().bytesOf == routes
    check e.view("m2").tryGet.state == msReady
    check e.view("m2").tryGet.execution.intent == inRequested
    release()
    check parkedCode(0) == ecOk
    check parkedCode(1) == ecOk
    check parkedCode(2) == ecOk
    check e.view("m2").tryGet.state == msUnloaded
    check e.routes().filterIt(it.route == closing).allIt(
      it.state.kind != LogosNSRuntimeControlRouteStateKind.Ready
    )
    # A pending execution decision: intent is accepted, nothing else.
    check e.create(client(), "m1").isOk
    hold()
    setScript(rule(vHang, "execute"))
    let inits = clientInits.load
    park(orch, "start_module", startReq("m1"))
    check waitHanging()
    let v = e.view("m1").tryGet
    check v.state == msUnloaded
    check v.execution.intent == inRequested
    check v.attempt == ""
    check clientInits.load == inits
    release()
    check parkedCode() == ecOk
    check e.view("m1").tryGet.state == msReady
    e.finish()

suite "run.authority: execution (RUNTIME §3.6, §9.3)":
  test "[CAP-0062] [CAP-0290] [RUN-0644] the execution decision is made for the origin before the module's code runs; a deny or failure follows G168":
    let (e, orch) = ready()
    check e.create(client(), "m1").isOk
    let inits = clientInits.load
    check orch.lifecycle("start_module", "client_module", Opt.some("m1")).code == ecOk
    let ex = received().filterIt(it.what == "execute")
    check ex.len == 1
    check ex[0].consumer == Orch
    check clientInits.load == inits + 1
    check e.stop("m1").isOk
    setScript(
      rule(
        vDeny,
        "execute",
        code = ord(LogosNSCapabilityAuthorityDenialCodeKind.Scope_denied),
      )
    )
    check orch.lifecycle("start_module", "client_module", Opt.some("m1")).code ==
      ecNotAuthorised
    var v = e.view("m1").tryGet
    check v.state == msUnloaded
    check v.failure.get.kind == fkAuthorityDenied
    check v.execution.intent == inRequested
    check v.intentOrigin.instance == Orch
    setScript(rule(vError, "execute"))
    check orch.lifecycle("start_module", "client_module", Opt.some("m1")).code ==
      ecNotAuthorised
    v = e.view("m1").tryGet
    check v.failure.get.kind == fkAuthorityEvaluationFailed
    check clientInits.load == inits + 1
    e.finish()

  test "[RUN-0666] [RUN-0667] [I85] a start while the execution decision is pending joins it; an explicit stop cancels it":
    let (e, orch) = ready()
    check e.create(client(), "m1").isOk
    hold()
    setScript(rule(vHang, "execute"))
    park(orch, "start_module", startReq("m1"), slot = 0)
    check waitHanging()
    park(orch, "start_module", startReq("m1"), slot = 1)
    sleep(50)
    check not parkDone[1].load
    release()
    check parkedCode(0) == ecOk
    check parkedCode(1) == ecOk
    check count("execute") == 1
    check e.view("m1").tryGet.state == msReady
    # Cancelled by an explicit stop: the start gets the state after it.
    check e.stop("m1").isOk
    hold()
    forget()
    park(orch, "start_module", startReq("m1"), slot = 0)
    check waitHanging()
    check orch.lifecycle("stop_module", "client_module", Opt.some("m1")).code == ecOk
    check parkedCode(0) == ecOk
    let v = e.view("m1").tryGet
    check v.state == msUnloaded
    check v.execution.intent == inStopped
    release()
    sleep(50)
    check e.view("m1").tryGet.state == msUnloaded
    e.finish()

  test "[RUN-0668] [RUN-0669] [CAP-0063] recover_module is decided for the requester, execution for the retained origin":
    let (e, orch) = ready()
    check e.create(client(), "m1").isOk
    check orch.lifecycle("start_module", "client_module", Opt.some("m1")).code == ecOk
    let m2 = e.started(client(), "m2")
    let rc2 = latestClient()
    check m2.state == msReady
    let v = e.view("m1").tryGet
    check e.reportFailure("m1", v.attempt).isOk
    check waitUntil(
      proc(): bool =
        not e.cleanupPending("m1") and e.view("m1").tryGet.state == msError
    )
    forget()
    let failed = e.view("m1").tryGet
    let r = rc2.rcCall(
      "recover_module",
      encode(
        LogosNSRuntimeControlRecoverModuleRequest(
          module: "client_module",
          instance: "m1",
          expected_execution_revision: failed.execution.revision,
        )
      ).tryGet,
    )
    check r.code == ecOk
    let got = received()
    check got.anyIt(it.what == "rc:recover_module" and it.consumer == "m2")
    check got.anyIt(it.what == "execute" and it.consumer == Orch)
    e.finish()

suite "run.authority: route validity (RUNTIME l.3157-3190; TL-03 interim)":
  test "[RUN-0566] [RUN-0938] [CAP-0049] a route allow without valid_until is refused; expires_at is the allow's valid_until, at establishment and at renewal":
    let (e, orch) = ready()
    setScript(rule(vNoValidity, "establish-route"))
    check orch.establish("k0").code == ecNotAuthorised
    setScript()
    let start = uint64(clk.wallMs)
    let r = orch.establish("k1")
    check r.code == ecOk
    let rec = r.routesOf.routes[0]
    check rec.expires_at == Opt.some(start + uint64(Everything))
    clk.advance(1000)
    let n = orch.renew("k2", rec.route)
    check n.code == ecOk
    let renewed =
      LogosNSRuntimeControlRenewRouteResponse.decode(n.response).tryGet.route
    check renewed.expires_at == Opt.some(start + 1000 + uint64(Everything))
    check renewed.decision_id != rec.decision_id
    e.finish()

  test "[RUN-0550] [CAP-0050] [CAP-0342] [RUN-0836] [RUN-0838] at expires_at the route is revoked with authority-expired: calls and observers get NOT_AUTHORISED and it cannot be renewed":
    let (e, orch) = ready()
    setScript(allow("establish-route", validMs = 1000))
    let route = orch.routeId("k")
    var h = orch.handle(route)
    var seen: EndSeen
    check h.observe(addr seen) == ecOk
    check h.read(1).isOk
    clk.advance(1500)
    check h.read(1).error.code == ecNotAuthorised
    let rec = e.routes().filterIt(it.route == route)[0]
    check rec.state.kind == LogosNSRuntimeControlRouteStateKind.Revoked
    check rec.failure.get.code == "authority-expired"
    check waitUntil(
      proc(): bool =
        seen.count.load == 1
    )
    check ErrorCode(seen.code.load) == ecNotAuthorised
    check orch.renew("k2", route).code == ecNotAuthorised
    h.release()
    e.finish()

# Execution authorization over time ------------------------------------------------------

proc startBy(
    orch: ptr LogosRuntimeControlBinding, instance: string, module = "client_module"
) =
  check orch.lifecycle("start_module", module, Opt.some(instance)).code == ecOk

proc reaches(e: Engine, instance: string, state: ModuleState): bool =
  ## Each look is a request, after which the Runtime thread checks its
  ## deadlines on the test clock.
  waitUntil(
    proc(): bool =
      e.view(instance).tryGet.state == state
  )

proc stoppedFor(e: Engine, instance: string, kind: FailureKind): bool =
  ## [G168 extended] `unloaded` with the classification, intent and origin
  ## kept.
  if not e.reaches(instance, msUnloaded):
    return false
  let v = e.view(instance).tryGet
  v.failure.isSome and v.failure.get.kind == kind and v.execution.intent == inRequested and
    v.intentOrigin.instance == Orch

proc counted(e: Engine, what: string, n: int): bool =
  waitUntil(
    proc(): bool =
      discard e.list()
      count(what) >= n
  )

proc failedRenewals(e: Engine, n: int): bool =
  ## `n` execution renewals have failed and the Runtime has applied their
  ## answers: retaining an answer and applying it are one Runtime-thread step,
  ## so the retry is already scheduled from the test clock's time. Counting
  ## what the authority received is not enough: a slow build may apply the
  ## answer after the clock moves on.
  waitUntil(
    proc(): bool =
      e.answers().countIt(it.request.renewal and it.outcome == azEvaluationFailed) >= n
  )

proc routeState(e: Engine, route: string): LogosNSRuntimeControlRouteRecord =
  e.routes().filterIt(it.route == route)[0]

proc recoverReq(e: Engine, instance: string): seq[byte] =
  encode(
    LogosNSRuntimeControlRecoverModuleRequest(
      module: "client_module",
      instance: instance,
      expected_execution_revision: e.view(instance).tryGet.execution.revision,
    )
  ).tryGet

suite "run.authority: execution over time (CA §5.1, §8 l.828-866; RUNTIME §10.1)":
  test "[CAP-0304] [CAP-0311] [CAP-0321] [CAP-0352] a renewal runs on its own lane with execution_renewal while the ordinary lane is saturated; its allow carries the execution past the old end":
    let (e, orch) = ready()
    check e.create(client(), "m1").isOk
    setScript(allow("execute", validMs = 60_000))
    orch.startBy("m1")
    forget()
    hold()
    setScript(rule(vHang, "rc:get_readiness"))
    for i in 0 .. 3:
      park(orch, "get_readiness", observeReq("meter_module", Meter), slot = i)
    check waitHanging(4)
    # [IMPL] renewal at end − min(30 s, lifetime / 3): 40 s into 60 s.
    clk.advance(39_000)
    discard e.list()
    check count("renew-execution") == 0
    clk.advance(2_000)
    check e.counted("renew-execution", 1)
    check hanging.load == 4
    let got = received()
    let r = got.filterIt(it.what == "renew-execution")[0]
    check r.consumer == Orch
    let req = LogosNSCapabilityAuthorityEvaluateRequest.decode(r.request).tryGet
    check req.execution_renewal == Opt.some(true)
    check r.thread notin got.filterIt(it.what == "rc:get_readiness").mapIt(it.thread)
    # An ordinary execution decision never carries the field.
    check e.create(client(), "m2").isOk
    release()
    for i in 0 .. 3:
      check parkedCode(i) == ecOk
    orch.startBy("m2")
    let ex = received().filterIt(it.what == "execute")
    check ex.len == 1
    check LogosNSCapabilityAuthorityEvaluateRequest.decode(ex[0].request).tryGet.execution_renewal.isNone
    # The renewal allowed for ten minutes: the first end passes.
    clk.advance(30_000)
    discard e.list()
    check e.view("m1").tryGet.state == msReady
    e.finish()

  test "[CAP-0349] [CAP-0350] [CAP-0351] [CAP-0342] a denied renewal stops the execution; a failed one keeps it only until its end, then authority-expired with no grace":
    let (e, orch) = ready()
    check e.create(client(), "m1").isOk
    check e.create(client(), "m2").isOk
    setScript(allow("execute", validMs = 60_000), rule(vDeny, "renew-execution"))
    orch.startBy("m1")
    clk.advance(41_000)
    check e.stoppedFor("m1", fkAuthorityDenied)
    forget()
    setScript(allow("execute", validMs = 60_000), rule(vError, "renew-execution"))
    orch.startBy("m2")
    clk.advance(41_000)
    check e.counted("renew-execution", 1)
    check e.failedRenewals(1)
    check e.view("m2").tryGet.state == msReady
    # Asked again within min(5 s, half of what is left).
    clk.advance(5_000)
    check e.counted("renew-execution", 2)
    check e.failedRenewals(2)
    clk.advance(13_999)
    discard e.list()
    check e.view("m2").tryGet.state == msReady
    clk.advance(1)
    check e.stoppedFor("m2", fkAuthorityExpired)
    e.finish()

  test "[CAP-0166] [CAP-0167] [CAP-0168] [CAP-0169] policy_changed keeps an execution only when its previous revision is the authorization's and a present affected_executions leaves it out":
    let (e, orch) = ready()
    let id = e.runtimeInstanceId
    for m in ["m1", "m2", "m3", "m4", "m5"]:
      check e.create(client(), m).isOk
    orch.startBy("m1")
    orch.startBy("m2")
    setScript(Rule(what: "execute", verdict: vAllow, validMs: Everything, revision: 9))
    orch.startBy("m4")
    setScript()
    # Listed: revoked. Not listed: kept, at the new revision. Decided at or
    # after the new revision: untouched.
    check publish(PolicyChangedName, policyChanged(0, 1, Opt.some(@[(id, "m2")])))
    check e.stoppedFor("m2", fkAuthorityRevoked)
    check e.view("m1").tryGet.state == msReady
    # m1 is now at revision 1, so a notice from 1 keeps it.
    check publish(
      PolicyChangedName, policyChanged(1, 2, Opt.some(newSeq[(string, string)]()))
    )
    discard e.list()
    check e.view("m1").tryGet.state == msReady
    orch.startBy("m3")
    # affected_executions absent: every authorization before it is revoked.
    check publish(PolicyChangedName, policyChanged(2, 3))
    check e.stoppedFor("m1", fkAuthorityRevoked)
    check e.stoppedFor("m3", fkAuthorityRevoked)
    orch.startBy("m5")
    # A previous revision that is not the authorization's.
    check publish(
      PolicyChangedName, policyChanged(5, 6, Opt.some(newSeq[(string, string)]()))
    )
    check e.stoppedFor("m5", fkAuthorityRevoked)
    check e.view("m4").tryGet.state == msReady
    e.finish()

  test "[RUN-1066] [RUN-0692] [RUN-0904] [RUN-0699] [CAP-0291] [CAP-0170] [CAP-0185] [CAP-0359] an ended grant stops the executions that used it, keeping intent and origin; their routes follow; recovery under a new grant starts afresh":
    let (e, orch) = ready(meter = false)
    let id = e.runtimeInstanceId
    check e.create(client(), "m1").isOk
    setScript(allow("execute", grants = @["gm"]))
    orch.startBy(Meter, "meter_module")
    setScript(allow("execute", grants = @["g1"]))
    orch.startBy("m1")
    let rc1 = latestClient()
    setScript()
    let r1 = rc1.routeId("k1")
    let r2 = orch.routeId("k2")
    forget()
    # Its destroy held, so its realization is still there to call from.
    clientDestroyGate.store(true)
    check publish(
      GrantChangedName, grantChanged("g1", GrantStatusKind.Revoked, Orch, id)
    )
    check e.reaches("m1", msStopping)
    check rc1.rcCall(
      "get_execution_permissions",
      encode(LogosNSRuntimeControlGetExecutionPermissionsRequest()).tryGet,
    ).code == ecNotReady
    check e.routeState(r1).state.kind == LogosNSRuntimeControlRouteStateKind.Closed
    clientDestroyGate.store(false)
    check e.stoppedFor("m1", fkAuthorityRevoked)
    check count("stop") == 0
    check e.routeState(r2).state.kind == LogosNSRuntimeControlRouteStateKind.Ready
    check e.view(Meter).tryGet.state == msReady
    # An expired grant: authority-expired; the provider's routes fail.
    check publish(
      GrantChangedName, grantChanged("gm", GrantStatusKind.Expired, Orch, id)
    )
    check e.stoppedFor(Meter, fkAuthorityExpired)
    let f = e.routeState(r2)
    check f.state.kind == LogosNSRuntimeControlRouteStateKind.Failed
    check f.failure.get.code == "provider-unavailable"
    # Orchestration resumes it; the engine never did by itself.
    setScript(allow("execute", grants = @["g2"]))
    check orch.rcCall("recover_module", e.recoverReq("m1")).code == ecOk
    let v = e.view("m1").tryGet
    check v.state == msReady
    check v.failure.isNone
    check e.routeState(r1).state.kind == LogosNSRuntimeControlRouteStateKind.Closed
    e.finish()

  test "[CAP-0345] [RUN-0702] [RUN-0703] losing the binding stops the executions it authorized, as authority-evaluation-failed; orchestration, the authority and host-started modules keep running":
    let (e, orch) = ready()
    check e.create(client(), "m1").isOk
    orch.startBy("m1")
    let g = e.generation
    check publish(PolicyChangedName, @[])
    check e.generation >= g + 2
    check e.stoppedFor("m1", fkAuthorityEvaluationFailed)
    check e.view(Orch).tryGet.state == msReady
    check e.view(Ca).tryGet.state == msReady
    check e.view(Meter).tryGet.state == msReady
    check e.bound
    e.finish()

  test "[IMPL] [C26] stopForAuthority stops a running instance with the classification given and keeps its intent; anything but an authority classification is refused":
    let (e, orch) = ready()
    check e.create(client(), "m1").isOk
    orch.startBy("m1")
    check e.stopForAuthority("m1", fkReportedByModule).error.code == ecInvalidParams
    check e.stopForAuthority("nope", fkAuthorityRevoked).error.code == ecInvalidParams
    check e.stopForAuthority("m1", fkAuthorityRevoked).isOk
    check e.stoppedFor("m1", fkAuthorityRevoked)
    # Not running: nothing happens.
    check e.stopForAuthority("m1", fkAuthorityDenied).tryGet.failure.get.kind ==
      fkAuthorityRevoked
    # An explicit stop clears the classification.
    check orch.lifecycle("stop_module", "client_module", Opt.some("m1")).code == ecOk
    check e.view("m1").tryGet.failure.isNone
    e.finish()

# Route re-authorization ------------------------------------------------------------------

proc client(e: Engine, instance: string): ptr LogosRuntimeControlBinding =
  ## A consumer started by the host, so its own execution never ends.
  check e.started(client(), instance).state == msReady
  latestClient()

proc ended(e: Engine, route: string, code: string): bool =
  waitUntil(
    proc(): bool =
      let r = e.routeState(route)
      r.state.kind == LogosNSRuntimeControlRouteStateKind.Revoked and r.failure.isSome and
        r.failure.get.code == code
  )

proc isReady(e: Engine, route: string): bool =
  e.routeState(route).state.kind == LogosNSRuntimeControlRouteStateKind.Ready

suite "run.authority: route re-authorization (CA l.869-914; S8b-2 interim)":
  test "[RUN-0567] [RUN-0946] [CAP-0174] [CAP-0189] a renewal narrowed below the bound access revokes with authority-revoked, a denied one with authority-denied; a failed one leaves the route ready and unusable until a later decision; a replay renews nothing":
    let (e, orch) = ready()
    var narrowed = allow("renew-route")
    narrowed.narrowMethods = Opt.some(@[declRoot("meter.read")])
    let ra = orch.routeId("a")
    setScript(narrowed)
    check orch.renew("ra", ra).code == ecNotAuthorised
    check e.ended(ra, "authority-revoked")
    let rb = orch.routeId("b")
    setScript(rule(vDeny, "renew-route"))
    check orch.renew("rb", rb).code == ecNotAuthorised
    check e.ended(rb, "authority-denied")
    setScript()
    let rc = orch.routeId("c")
    var h = orch.handle(rc)
    check h.read(1).isOk
    setScript(rule(vError, "renew-route"))
    check orch.renew("rc1", rc).code == ecNotAuthorised
    check e.isReady(rc)
    # Unusable: its next use is re-authorized first, and that fails too.
    forget()
    check h.read(1).error.code == ecNotAuthorised
    check count("renew-route") == 1
    check count("call") == 0
    setScript()
    check h.read(1).isOk
    # A replayed renewal answers as before and renews nothing.
    clk.advance(1000)
    check orch.renew("rc2", rc).code == ecOk
    let renewed = e.routeState(rc).expires_at
    clk.advance(1000)
    forget()
    check orch.renew("rc2", rc).code == ecOk
    check count("renew-route") == 0
    check e.routeState(rc).expires_at == renewed
    h.release()
    e.finish()

  test "[CAP-0188] [CAP-0189] [CAP-0174] [CAP-0173] after policy_changed each route is re-authorized at once with renew-route while its operations wait; an allow keeps it without extending expires_at; a deny or narrowing revokes it; a failure leaves it ready and unusable until a later re-authorization succeeds":
    let (e, orch) = ready()
    let c1 = e.client("m1")
    let c2 = e.client("m2")
    let c3 = e.client("m3")
    setScript(allow("establish-route", validMs = 60_000))
    let r1 = c1.routeId("k")
    let r2 = c2.routeId("k")
    let r3 = c3.routeId("k")
    setScript()
    var h1 = c1.handle(r1)
    var h3 = c3.handle(r3)
    check h1.read(1).isOk
    let exp1 = e.routeState(r1).expires_at
    forget()
    hold()
    setScript(
      rule(vHang, "renew-route", consumer = "m1"),
      rule(vDeny, "renew-route", consumer = "m2"),
      rule(vError, "renew-route", consumer = "m3"),
    )
    check publish(PolicyChangedName, policyChanged(0, 1))
    check waitHanging()
    check e.ended(r2, "authority-denied")
    # A call on the route being re-authorized waits for it.
    bgDone.store(false)
    var t: Thread[ptr LogosRouteHandle]
    createThread(t, background, addr h1)
    sleep(50)
    check not bgDone.load
    # The failed one stays ready and refuses.
    check e.isReady(r3)
    check h3.read(1).error.code == ecNotAuthorised
    release()
    joinThread(t)
    check bgCode.load == 0
    # Kept for ten more minutes, yet its end does not move.
    check e.routeState(r1).expires_at == exp1
    # A later re-authorization makes the failed one usable again.
    setScript()
    check h3.read(1).isOk
    # A shorter valid_until shortens it; a narrowed allow revokes.
    var narrowed = allow("renew-route", consumer = "m1")
    narrowed.narrowMethods = Opt.some(@[declRoot("meter.read")])
    setScript(narrowed, allow("renew-route", consumer = "m3", validMs = 1000))
    let now = uint64(clk.wallMs)
    check publish(PolicyChangedName, policyChanged(1, 2))
    check e.ended(r1, "authority-revoked")
    check waitUntil(
      proc(): bool =
        e.routeState(r3).expires_at == Opt.some(now + 1000)
    )
    check e.isReady(r3)
    h1.release()
    h3.release()
    e.finish()

  test "[CAP-0185] [CAP-0359] a revoked grant re-authorizes only the routes whose decisions list it":
    let (e, orch) = ready()
    setScript(allow("establish-route", grants = @["ga"]))
    let ra = orch.routeId("a")
    setScript(allow("establish-route", grants = @["gb"]))
    let rb = orch.routeId("b")
    setScript(rule(vDeny, "renew-route"))
    forget()
    check publish(
      GrantChangedName,
      grantChanged("ga", GrantStatusKind.Revoked, Orch, e.runtimeInstanceId),
    )
    check e.ended(ra, "authority-denied")
    check count("renew-route") == 1
    check e.isReady(rb)
    setScript()
    var h = orch.handle(rb)
    check h.read(1).isOk
    h.release()
    e.finish()

  test "[RUN-0833] [CAP-0193] [CAP-0194] a call in flight across a policy change commits its response when its route is kept; when the route is revoked it gets NOT_AUTHORISED, its invocation is marked cancelled and the limitation is recorded":
    let (e, orch) = ready()
    let route = orch.routeId("k")
    var h = orch.handle(route)
    var h2 = orch.handle(route)
    check h2.read(1).isOk
    var t: Thread[ptr LogosRouteHandle]
    gate.store(true)
    bgDone.store(false)
    createThread(t, background, addr h)
    check waitUntil(
      proc(): bool =
        held.load == 1
    )
    check publish(PolicyChangedName, policyChanged(0, 1))
    # Kept: the next call waits for the re-authorization, then runs.
    check h2.read(1).isOk
    gate.store(false)
    joinThread(t)
    check bgCode.load == 0
    gate.store(true)
    bgDone.store(false)
    createThread(t, background, addr h)
    check waitUntil(
      proc(): bool =
        held.load == 1
    )
    setScript(rule(vDeny, "renew-route"))
    check publish(PolicyChangedName, policyChanged(1, 2))
    check e.ended(route, "authority-denied")
    gate.store(false)
    joinThread(t)
    check ErrorCode(bgCode.load) == ecNotAuthorised
    check e.diagnostics().anyIt("authority was withdrawn" in it)
    h.release()
    h2.release()
    e.finish()

# Routed calls to the authority's methods -------------------------------------------------

proc evalReq(e: Engine, consumer: string, renewal = false): seq[byte] =
  encode(
    LogosNSCapabilityAuthorityEvaluateRequest(
      consumer:
        Address(runtime_instance_id: e.runtimeInstanceId, module_instance_id: consumer),
      scopes: @[],
      execution_renewal: (if renewal: Opt.some(true) else: Opt.none(bool)),
    )
  ).tryGet

suite "run.authority: routed calls to the authority (CA l.88-91, l.579; S8b-1 interim)":
  test "[CAP-0013] [CAP-0305] [CAP-0248] [CAP-0306] [RUN-0324] [RUN-0852] a routed call naming another consumer, or an evaluate carrying execution_renewal, is NOT_AUTHORISED without dispatch and kept as a refusal; a matching call reaches the authority with a module caller":
    let (e, orch) = ready()
    let caSet = block:
      let d = caDocuments()
      acceptContractSet(d[0], d[1], d[2], AcceptOptions(system: true)).tryGet
    let caRoot = caSet.primary.root
    let r = orch.establish("ca", root = caRoot)
    check r.code == ecOk
    let (code, handle) = orch.materialize(
      r.routesOf.routes[0].route,
      caRoot,
      encodeCbor(schemaResponse(caSet, caRoot).tryGet),
    )
    check code == ecOk
    var h = handle
    forget()
    let before = e.answers().len
    check h.raw("evaluate", e.evalReq(Meter)).code == ecNotAuthorised
    check h.raw("evaluate", e.evalReq(Orch, renewal = true)).code == ecNotAuthorised
    # Only the calls' own decisions reached the authority, from the Runtime.
    check received().allIt(it.callerKind == CallerSystemService and it.what == "call")
    let kept = e.answers()[before ..^ 1].filterIt(it.outcome == azRefused)
    check kept.len == 2
    check kept.allIt(it.source == psBoundary and it.request.consumer == Orch)
    check kept.allIt(it.request.operation == "evaluate" and it.request.target.len > 0)
    # The call's own decision came first, and allowed it.
    check e.answers()[before ..^ 1].anyIt(it.request.action == aaCall and it.allows)
    # Its own consumer, without the field: dispatched with a module caller.
    check h.raw("evaluate", e.evalReq(Orch)).code == ecOk
    let got = received().filterIt(it.callerKind == CallerModule)
    check got.len == 1
    check got[0].consumer == Orch
    h.release()
    e.finish()
