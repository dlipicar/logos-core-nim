## The Runtime side of authority (step 8b; DECISIONS I85): the Capability
## Authority binding (RUNTIME §9 l.1652-1680; CA §1, §8), evaluation off the
## Runtime thread with parked operations (CA §5, §7; RUNTIME l.1737-1748),
## the decision cache and its invalidation (CA §8), the bootstrap and
## recovery rules (RUNTIME l.1635-1650, l.1674-1680), execution
## authorization before realization (RUNTIME §3.6), and route validity
## (RUNTIME l.3157-3190; TL-03 interim).
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
import ./support/[fakeca, kitbuild, kitruntime]
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

let clk = newTestClock()
useClock(clk)

proc caConfig(recovery = false, deadlineMs = 0): EngineConfig =
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

proc ready(): (Engine, ptr LogosRuntimeControlBinding) =
  ## Bootstrapped, the authority bound, the meter ready (started by the host).
  fresh()
  let e = newEngine(caConfig())
  let orch = e.boot()
  e.startCa(orch)
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

proc parkedCode(slot = 0): ErrorCode =
  check waitUntil(
    proc(): bool =
      parkDone[slot].load
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
  test "[RUN-0313] [RUN-0314] [RUN-0315] [RUN-0316] [RUN-0317] [RUN-0319] [CAP-0003] [CAP-0005] [CAP-0006] [CAP-0008] the configured authority is bound once ready, before its start is answered, under a fresh generation":
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

  test "[IMPL] [RUN-0701] the orchestration instance cannot be the authority (C8)":
    fresh()
    let e = newEngine(caConfig())
    let v = e.bootstrap(@[BootstrapInstance(instance: Ca, record: fakeCaRecord())], Ca)
    check v.isErr and v.error.code == ecInvalidParams
    e.finish()

suite "run.authority: bootstrap and recovery rules (RUNTIME l.1635-1650, l.1674-1680)":
  test "[RUN-0305] [RUN-0306] [RUN-0311] [RUN-0312] [RUN-0050] [RUN-0051] [RUN-0859] [CAP-0062] before the binding, orchestration starts the authority without an evaluation; everything else fails closed as an evaluation failure":
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
  test "[CAP-0011] [CAP-0012] [CAP-0013] [CAP-0014] [CAP-0428] [RUN-0322] [RUN-0324] [RUN-0858] [RUN-0823] evaluate runs off the Runtime thread with a system-service caller; the consumer is the module, never the engine":
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

  test "[CAP-0025] [CAP-0098] [CAP-0108] [CAP-0109] [CAP-0110] [CAP-0111] [CAP-0112] [CAP-0113] [CAP-0114] [CAP-0118] [CAP-0153] [CAP-0260] [CAP-0261] [CAP-0084] [CAP-0068] [RUN-0325] [RUN-0327] [RUN-0329] a malformed decision, an error arm or a failed dispatch is an evaluation failure, never a deny":
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

  test "[RUN-0326] [RUN-0328] [RUN-0330] [RUN-0331] [CAP-0153] a deny is NOT_AUTHORISED; the retained answer keeps its consumer, operation, target, decision id and denial code":
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

  test "[CAP-0115] [CAP-0116] [CAP-0117] [CAP-0051] [RUN-0567] a narrowed route allow gives the route its access; an allow that excludes the operation is refused and marked narrowed":
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
  test "[CAP-0119] [CAP-0120] [RUN-0867] [RUN-0571] [RUN-0572] an allow with a validity is reused until it ends; one without is asked each time":
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

  test "[CAP-0353] [CAP-0354] [CAP-0355] [CAP-0177] [CAP-0183] a notice that does not read is notification-path loss: a new generation, nothing carried over":
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
  test "[CAP-0344] [CAP-0345] [CAP-0346] [CAP-0347] [CAP-0348] [CAP-0172] [RUN-0854] a lost authority answers parked evaluations and closes admission; neither its late results nor its cache reach the next binding, whatever revision it reports":
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
    check h.read(1).error.code == ecNotAuthorised
    check e.lastFor(aaCall).outcome == azEvaluationFailed
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
    # Recovered under the derived rules: a new generation.
    check orch.rcCall("recover_module", recover).code == ecOk
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

suite "run.authority: parked operations (CA §8; I75)":
  test "[CAP-0260] a hanging evaluate leaves the Runtime thread serving; the deadline fails closed and marks the invocation cancelled":
    fresh()
    let e = newEngine(caConfig(deadlineMs = 300))
    let orch = e.boot()
    e.startCa(orch)
    check e.start(Meter).isOk
    hold()
    setScript(rule(vHang, "rc:get_readiness"))
    park(orch, "get_readiness", observeReq("meter_module", Meter))
    check waitHanging()
    # The Runtime thread is free.
    check e.list().len == 3
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
