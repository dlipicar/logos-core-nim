## Call audit (step 8b-3; DECISIONS I85, plan cases C1-C7): the request and
## response commitments the invocation boundary computes, the capture at
## admission, and the `call` audit records written after each outcome, under
## a scripted Capability Authority (`support/fakeca`) whose allows carry
## `retain-root`. The orchestration instance is routefixture's client module;
## the providers are the meter kit module, its deferred adapter and a small
## hand-written module whose contract marks payloads `_sensitive`.

import std/[atomics, monotimes, os, sequtils, sets, strutils, times, typedthreads]
import unittest2
import ../src/logos_core/runtime/engine
import ../src/logos_core/abi/types
import ../src/logos_core/cbor
import ../src/logos_core/commitment
import ../src/logos_core/hash
import ../src/logos_core/iface/[accept, cmap, outcome, provider, surface]
import ../src/logos_core/codegen/nimrt
import ../src/logos_core/iface/common_types
import ../src/logos_core/authority/scopes except
  LogosNSRuntimeModuleInstanceAddress, LogosNSRuntimeModuleInstanceId,
  LogosNSRuntimeModuleName, LogosNSRuntimeModuleProviderAddress,
  LogosNSRuntimeModuleProviderId, LogosNSRuntimeModuleStateAssignmentId,
  LogosNSRuntimeRouteId, LogosNSRuntimeRuntimeInstanceId
from ../src/logos_core/runtime/rc_types import rcSchema
import ./support/[fakeca, kitbuild, kitruntime]
import ./kit/[deferred_adapter, meter_impl]
import ./generated/meter_module_calls

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "audit" / kitVariant
removeDir(work)
createDir(work)

include ./support/routefixture

# A module with `_sensitive` payloads ---------------------------------------------------

const VaultDoc =
  "_module = \"vault_module\"\n" &
  "_sensitive = [\"vault.get_response\", \"vault.store_request\"]\n\n" &
  "vault.store_request = {\n  secret: bstr,\n}\n\n" &
  "vault.store_response = {\n  ok: bool,\n}\n\n" &
  "vault.get_request = {\n  slot: uint32,\n}\n\n" &
  "vault.get_response = {\n  secret: bstr,\n}\n"

let
  vaultBinding = acceptBinding("vault_module", Opt.some(VaultDoc)).tryGet
  vaultRoot = vaultBinding.primary.get.root
  vaultSet = acceptContractSet(VaultDoc).tryGet
  vaultSchema = encodeCbor(schemaResponse(vaultSet, vaultRoot).tryGet)

var vaultSurface: ptr UncheckedArray[uint8]
var vaultSurfaceLen: int

block:
  let d = callSurfaceDescriptor(vaultBinding).tryGet
  vaultSurface = cast[ptr UncheckedArray[uint8]](allocShared0(d.len))
  for i, b in d:
    vaultSurface[i] = b
  vaultSurfaceLen = d.len

proc vaultName(): cstring {.cdecl, gcsafe, raises: [].} =
  "vault_module"

proc vaultCallSurface(outLen: ptr csize_t): ptr uint8 {.cdecl, gcsafe, raises: [].} =
  outLen[] = csize_t(vaultSurfaceLen)
  cast[ptr uint8](vaultSurface)

proc vaultInit(
    input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
): LogosResult {.cdecl, gcsafe, raises: [].} =
  outContext[] = cast[ptr LogosModuleContext](allocShared0(8))

proc vaultDestroy(module: ptr LogosModuleContext) {.cdecl, gcsafe, raises: [].} =
  deallocShared(module)

proc vaultFree(
    module: ptr LogosModuleContext, p: pointer
) {.cdecl, gcsafe, raises: [].} =
  if p != nil:
    deallocShared(p)

proc vaultDispatch(
    module: ptr LogosModuleContext,
    methodName: cstring,
    params: ptr UncheckedArray[uint8],
    paramsLen: csize_t,
    outResp: ptr ptr UncheckedArray[uint8],
    outLen: ptr csize_t,
): LogosResult {.cdecl, gcsafe, raises: [].} =
  # `store` answers `{ok: true}`, `get` `{secret: h'00'}`.
  let bytes =
    if $methodName == "store":
      @[0xA1'u8, 0x62, 0x6F, 0x6B, 0xF5]
    else:
      @[0xA1'u8, 0x66, 0x73, 0x65, 0x63, 0x72, 0x65, 0x74, 0x41, 0x00]
  let p = cast[ptr UncheckedArray[uint8]](allocShared0(bytes.len))
  for i, b in bytes:
    p[i] = b
  outResp[] = p
  outLen[] = csize_t(bytes.len)
  LogosResult()

proc vaultTable(): seq[(string, pointer)] =
  result = @[
    ("logos_vault_module_MODULE_name", cast[pointer](vaultName)),
    ("logos_vault_module_MODULE_call_surface", cast[pointer](vaultCallSurface)),
    ("logos_vault_module_MODULE_init", cast[pointer](vaultInit)),
    ("logos_vault_module_MODULE_destroy", cast[pointer](vaultDestroy)),
    ("logos_vault_module_MODULE_dispatch", cast[pointer](vaultDispatch)),
    ("logos_vault_module_MODULE_free", cast[pointer](vaultFree)),
  ]
  # The typed per-method symbols the call surface requires; the Runtime calls
  # through `dispatch`, never these.
  for c in cLayout(cSchemaSet(vaultBinding)).tryGet.calls:
    result.add((c.symbol, cast[pointer](vaultDispatch)))

# The meter kit module behind a `_MODULE_dispatch` that records how the
# Runtime left the response outputs on entry (INTERFACE §2.6 l.1754).

var recordedEntries, recordedDirty: Atomic[int]

let meterKitDispatch = block:
  var f: ModuleDispatchFn
  for (name, p) in meterModuleStaticSymbols():
    if name == "logos_meter_module_MODULE_dispatch":
      f = cast[ModuleDispatchFn](p)
  f

proc recordingDispatch(
    module: ptr LogosModuleContext,
    methodName: cstring,
    params: ptr UncheckedArray[uint8],
    paramsLen: csize_t,
    outResp: ptr ptr UncheckedArray[uint8],
    outLen: ptr csize_t,
): LogosResult {.cdecl, gcsafe, raises: [].} =
  recordedEntries += 1
  if outResp == nil or outLen == nil or outResp[] != nil or outLen[] != 0:
    recordedDirty += 1
  meterKitDispatch(module, methodName, params, paramsLen, outResp, outLen)

proc recordingTable(): seq[(string, pointer)] =
  for (name, p) in meterModuleStaticSymbols():
    if name == "logos_meter_module_MODULE_dispatch":
      result.add((name, cast[pointer](recordingDispatch)))
    else:
      result.add((name, p))

let
  vaultStatic = checkStaticRegistration("vault", vaultTable()).tryGet
  dmeterStatic = checkStaticRegistration("dmeter", deferredMeterSymbols()).tryGet
  rmeterStatic = checkStaticRegistration("rmeter", recordingTable()).tryGet

proc vault(): ModuleRecord =
  ModuleRecord(
    module: "vault_module",
    strategy: stDirectStatic,
    binding: "vault",
    primaryContract: Opt.some(vaultRoot),
  )

proc dmeter(): ModuleRecord =
  ModuleRecord(
    module: "meter_module",
    strategy: stDirectStatic,
    binding: "dmeter",
    primaryContract: Opt.some(meterRoot),
  )

proc rmeter(): ModuleRecord =
  ModuleRecord(
    module: "meter_module",
    strategy: stDirectStatic,
    binding: "rmeter",
    primaryContract: Opt.some(meterRoot),
  )

# Set-up -----------------------------------------------------------------------------------

const
  Orch = "orch"
  Ca = "ca"
  Meter = "meter"
  Deferred = "dmeter"
  Vault = "vault"
  Recorder = "rmeter"

let clk = newTestClock()
useClock(clk)

proc auditConfig(records: int): EngineConfig =
  result =
    config(extra = @[fakeCaRegistration(), vaultStatic, dmeterStatic, rmeterStatic])
  result.authority = Opt.some(
    AuthorityPolicy(instance: Ca, evaluationDeadline: initDuration(seconds = 60))
  )
  result.clock = clk
  result.callRecords = records

proc latestClient(): ptr LogosRuntimeControlBinding =
  cast[ptr LogosRuntimeControlBinding](clients[(clientInits.load - 1) mod MaxClients].load)

proc ready(records = 0): (Engine, ptr LogosRuntimeControlBinding) =
  ## Bootstrapped, the authority bound and every provider ready.
  resetFake()
  resetDeferred()
  let e = newEngine(auditConfig(records))
  check e.bootstrap(
    @[
      BootstrapInstance(instance: Orch, record: client()),
      BootstrapInstance(instance: Ca, record: fakeCaRecord()),
      BootstrapInstance(instance: Meter, record: meter()),
      BootstrapInstance(instance: Deferred, record: dmeter()),
      BootstrapInstance(instance: Vault, record: vault()),
    ],
    Orch,
  ).isOk
  let orch = latestClient()
  check orch.lifecycle("start_module", CaModuleName, Opt.some(Ca)).code == ecOk
  check e.authorityBound()[0]
  for x in [Meter, Deferred, Vault]:
    check e.start(x).tryGet.state == msReady
  forget()
  (e, orch)

proc routeTo(
    orch: ptr LogosRuntimeControlBinding,
    e: Engine,
    instance, key: string,
    root = meterRoot,
): string =
  let r = orch.establish(
    key,
    root = root,
    provider = Opt.some(providerAddress(e.view(instance).tryGet.providerId)),
  )
  check r.code == ecOk
  r.routesOf.routes[0].route

proc retaining(what: string, request = true, response = true, validMs = 0'i64): Rule =
  ## An allow whose `commitment` retains the sides asked; single-use unless
  ## `validMs` is given.
  result = allow(what, validMs = validMs)
  result.retainRequest = request
  result.retainResponse = response

proc readReq(channel: int): seq[byte] =
  encodeCbor(parseDiag("{\"channel\": " & $channel & "}").get)

proc kept(e: Engine): seq[AuditRecord] =
  for r in e.audit.records:
    result.add(AuditRecord.decode(r.bytes).tryGet)

type ValueCommitment = LogosNSCapabilityAuthorityAuditValueCommitment

type CallView = object
  success: bool
  decision: string
  consumer: Address
  timestamp: uint64
  scope: Scope
  commitments: bool
  request, response: Opt[ValueCommitment]

proc view(r: AuditRecord): CallView =
  var c: Opt[LogosNSCapabilityAuthorityCallCommitments]
  case r.kind
  of AuditKind.Call_success:
    let x = r.arm_Call_success
    result = CallView(
      success: true,
      decision: x.decision_id,
      consumer: x.consumer,
      timestamp: x.timestamp,
      scope: x.scopes[0],
    )
    c = Opt.some(x.commitments)
  of AuditKind.Call_failure:
    let x = r.arm_Call_failure
    result = CallView(
      decision: x.decision_id,
      consumer: x.consumer,
      timestamp: x.timestamp,
      scope: x.scopes[0],
    )
    c = x.commitments
  else:
    doAssert false, "not a call record"
  if c.isSome:
    result.commitments = true
    case c.get.kind
    of LogosNSCapabilityAuthorityCallCommitmentsKind.Map_request:
      result.request = Opt.some(c.get.arm_Map_request.request)
      result.response = c.get.arm_Map_request.response
    of LogosNSCapabilityAuthorityCallCommitmentsKind.Map_response:
      result.response = Opt.some(c.get.arm_Map_response.response)

proc rootsOf(set: SchemaSet, declaration: string, bytes: seq[byte]): ValueCommitment =
  ## The commitment recomputed from the schema-typed value (RUN-0335).
  let n = set.normalize(0, declaration, decodeCbor(bytes).tryGet).tryGet
  ValueCommitment(
    schema_subtree_root: @(n.subtreeRoot), value_root: @(valueRoot(n).tryGet)
  )

proc meterRoots(declaration: string, bytes: seq[byte]): ValueCommitment =
  meterSet.schemaSet.rootsOf(declaration, bytes)

proc keptReach(e: Engine, n: int): bool =
  ## Whether `n` records are kept, waiting: an asynchronous call's record
  ## follows the outcome its completion delivers.
  waitUntil(
    proc(): bool =
      e.audit.records.len >= n
  )

proc lastCall(e: Engine): AuthzAnswer =
  for a in e.answers():
    if a.request.action == aaCall:
      result = a

# Asynchronous calls -------------------------------------------------------------------------

type Done = object
  count: Atomic[int]
  code: Atomic[int]

var done: Done

proc onComplete(
    userData: pointer,
    r: LogosResult,
    response: ptr UncheckedArray[uint8],
    len: csize_t,
    owner: LogosResponseOwner,
) {.cdecl, gcsafe, raises: [].} =
  let d = cast[ptr Done](userData)
  if not owner.release.isNil:
    owner.release(owner.state)
  d.code.store(int(r.code))
  d.count += 1

proc callAsync(h: var LogosRouteHandle, params: seq[byte]): ErrorCode =
  ## One asynchronous `read`, submitted and waited for.
  done.count.store(0)
  var o = LogosAsyncOptions(
    abiVersion: AsyncCallAbiVersion, structSize: csize_t(sizeof(LogosAsyncOptions))
  )
  var cb = LogosAsyncCallbacks(
    abiVersion: AsyncCallAbiVersion,
    structSize: csize_t(sizeof(LogosAsyncCallbacks)),
    complete: onComplete,
    userData: addr done,
  )
  var c = LogosAsyncCall()
  check toResult(
    h.vtable.prepareCall(
      addr h,
      "read",
      cast[ptr UncheckedArray[uint8]](unsafeAddr params[0]),
      csize_t(params.len),
      addr o,
      addr cb,
      addr c,
    )
  ).code == ecOk
  c.vtable.submit(addr c)
  check waitUntil(
    proc(): bool =
      done.count.load == 1
  )
  c.vtable.release(addr c)
  errorCode(int64(done.code.load)).get

# C1-C4: route calls ---------------------------------------------------------------------

suite "run.audit: route call records (CA §4, §9 l.1172-1215; RUNTIME l.1762-1772)":
  test "[RUN-0332] [RUN-0333] [CAP-0210] [CAP-0393] [IFC-0209] every call commits its request and successful response at the boundary, retained or not; a record holds the sides its decision retains, beside the call scope that binds them":
    let (e, orch) = ready()
    let route = orch.routeTo(e, Meter, "k")
    var h = orch.handle(route)
    # No retention: the call commits and runs, and nothing is recorded.
    setScript(allow("call", validMs = 0))
    check h.read(5).isOk
    check e.kept.len == 0
    # The request side only.
    setScript(retaining("call", response = false))
    let response = h.raw("read", readReq(5))
    check response.code == ecOk
    var v = e.kept[^1].view
    check v.success
    check v.request == Opt.some(meterRoots("meter.read_request", readReq(5)))
    check v.response.isNone
    # The response side only.
    setScript(retaining("call", request = false))
    check h.raw("read", readReq(5)).response == response.response
    v = e.kept[^1].view
    check v.success and v.request.isNone
    check v.response == Opt.some(meterRoots("meter.read_response", response.response))
    # [RUN-0333] The scope beside them names the route, the provider, the
    # contract and the method.
    check v.scope.kind == skProvider
    let p = v.scope.pa
    check p.contract.schema_root == @meterRoot
    check p.actions.mapIt(it.kind) == @[PaActionKind.Call]
    check p.routes == Opt.some(@[route])
    check p.providers.get.len == 1
    check p.providers.get[0].provider == e.view(Meter).tryGet.providerId
    check p.providers.get[0].runtime_instance_id == Opt.some(e.runtimeInstanceId)
    check p.access.get.methods == Opt.some(@[declRoot("meter.read")])
    h.release()
    e.finish()

  test "[RUN-0334] [RUN-0335] [RUN-0592] [CAP-0205] [CAP-0207] [CAP-0212] [CAP-0388] [CAP-0389] [CAP-0390] with both sides retained, a synchronous, an asynchronous and a deferred call each leave a success record naming the applied decision, its consumer and the enforced scope, with commitments recomputed from the typed values":
    let (e, orch) = ready()
    setScript(retaining("call"))
    var h = orch.handle(orch.routeTo(e, Meter, "k"))
    let r = h.raw("read", readReq(7))
    check r.code == ecOk
    check e.kept.len == 1
    let v = e.kept[0].view
    check v.success
    check v.decision == e.lastCall.decisionId
    check v.consumer ==
      Address(runtime_instance_id: e.runtimeInstanceId, module_instance_id: Orch)
    check v.timestamp == uint64(clk.wallMs)
    check v.request == Opt.some(meterRoots("meter.read_request", readReq(7)))
    check v.response == Opt.some(meterRoots("meter.read_response", r.response))
    # [CAP-0390] The enforced scope is covered by the decision's allowed one.
    let allowed = e.lastCall.allowed.mapIt(Scope.decode(it).tryGet)
    check allowed.anyIt(covers(it, v.scope, e.runtimeInstanceId))
    # Asynchronous, over the synchronous provider ABI.
    check h.callAsync(readReq(7)) == ecOk
    check e.keptReach(2)
    check e.kept[1].view.success
    check e.kept[1].view.response == v.response
    check e.kept[1].view.decision == e.lastCall.decisionId
    h.release()
    # Deferred: recorded at its completion.
    var d = orch.handle(orch.routeTo(e, Deferred, "d"))
    check d.callAsync(readReq(7)) == ecOk
    check e.keptReach(3)
    let w = e.kept[2].view
    check w.success
    check w.request == v.request
    check w.response.isSome
    check w.scope.pa.providers.get[0].provider == e.view(Deferred).tryGet.providerId
    d.release()
    e.finish()

  test "[CAP-0211] [CAP-0213] [CAP-0214] a failed call is a failure record holding only the sides that were committed, and none when nothing required was":
    let (e, orch) = ready()
    var h = orch.handle(orch.routeTo(e, Meter, "k"))
    setScript(retaining("call"))
    # The provider fails: the request was committed, no response was.
    check h.raw("read", readReq(13)).code == ecModule
    var v = e.kept[^1].view
    check not v.success
    check v.request == Opt.some(meterRoots("meter.read_request", readReq(13)))
    check v.response.isNone
    # A request that does not validate is never committed.
    check h.raw("read", encodeCbor(parseDiag("{\"x\": 1}").get)).code == ecInvalidParams
    v = e.kept[^1].view
    check not v.success and not v.commitments
    # Only the response was required, and none came.
    setScript(retaining("call", request = false))
    check h.raw("read", readReq(13)).code == ecModule
    v = e.kept[^1].view
    check not v.success and not v.commitments
    check e.kept.len == 3
    h.release()
    e.finish()

  test "[CAP-0391] [CAP-0392] a cached call decision is named as itself; renewing or revoking the route while a call runs does not change what it captured at admission":
    let (e, orch) = ready()
    let route = orch.routeTo(e, Meter, "k")
    var h = orch.handle(route)
    setScript(retaining("call", validMs = Everything))
    check h.read(1).isOk
    check h.read(2).isOk
    check received().countIt(it.what == "call") == 1
    check e.kept.len == 2
    check e.kept[0].view.decision == e.kept[1].view.decision
    # Single-use call decisions from here, the cache cleared: each call is
    # decided afresh.
    setScript(retaining("call"))
    check publish(PolicyChangedName, policyChanged(0, 1))
    var t: Thread[ptr LogosRouteHandle]
    gate.store(true)
    bgDone.store(false)
    createThread(t, background, addr h)
    check waitUntil(
      proc(): bool =
        held.load == 1
    )
    let applied = e.lastCall.decisionId
    # The route renewed while the call runs.
    check orch.renew("r1", route).code == ecOk
    check e.answers()[^1].decisionId != applied
    gate.store(false)
    joinThread(t)
    check bgCode.load == 0
    var v = e.kept[^1].view
    check v.success and v.decision == applied
    # Revoked while the call runs: it ends NOT_AUTHORISED, recorded as a
    # failure under what it captured.
    gate.store(true)
    bgDone.store(false)
    createThread(t, background, addr h)
    check waitUntil(
      proc(): bool =
        held.load == 1
    )
    let second = e.lastCall.decisionId
    setScript(rule(vDeny, "renew-route"))
    check publish(PolicyChangedName, policyChanged(1, 2))
    check waitUntil(
      proc(): bool =
        e.routes().anyIt(
          it.route == route and
            it.state.kind == LogosNSRuntimeControlRouteStateKind.Revoked
        )
    )
    gate.store(false)
    joinThread(t)
    check ErrorCode(bgCode.load) == ecNotAuthorised
    v = e.kept[^1].view
    check not v.success
    check v.decision == second
    check v.request.isSome and v.response.isSome
    check second != applied
    h.release()
    e.finish()

# C5-C7 ---------------------------------------------------------------------------------------

suite "run.audit: Runtime Control, logos.schema, sensitive payloads, retention (CA §9; INTERFACE l.395-397)":
  test "[CAP-0209] [RUN-0678] a Runtime Control call record has a runtime_control_scope with its one method, the selectors the operation determines and no events; a malformed request is a failure without commitments":
    let (e, orch) = ready()
    setScript(retaining("rc:get_readiness"))
    let params = encode(
      LogosNSRuntimeControlGetReadinessRequest(
        module: "meter_module", instance: Opt.some(Meter)
      )
    ).tryGet
    let r = rcCall(orch, "get_readiness", params)
    check r.code == ecOk
    check e.kept.len == 1
    let v = e.kept[0].view
    check v.success
    check v.scope.kind == skControl
    let s = v.scope.rc
    check s.runtime == e.runtimeInstanceId
    check s.contract == rcContract()
    check s.methods == Opt.some(@[rcMethodRoot("get_readiness")])
    check s.events.isNone
    check s.modules == Opt.some(@["meter_module"])
    check s.instances == Opt.some(@[Meter])
    let declaration = "logos.runtime_control.get_readiness_request"
    let (subtree, root) =
      rcSchema().commitment(declaration, decodeCbor(params).tryGet).tryGet
    check v.request ==
      Opt.some(ValueCommitment(schema_subtree_root: @subtree, value_root: @root))
    check v.response.isSome
    # [G171 interim] establish_route's authority comes before its payload's
    # validation, so its decision applies to a call that then fails.
    setScript(retaining("rc:establish_route"))
    check rcCall(orch, "establish_route", @[0xA0'u8]).code == ecInvalidParams
    let w = e.kept[^1].view
    check not w.success and not w.commitments
    check w.scope.rc.methods == Opt.some(@[rcMethodRoot("establish_route")])
    e.finish()

  test "[CAP-0207] [IFC-0578] [IFC-0579] logos.schema is recorded under the common schema with the selected contract in its scope; no route is made to a contract that marks a payload (DECISIONS I88, D-c)":
    let (e, orch) = ready()
    setScript(retaining("call"))
    var h = orch.handle(orch.routeTo(e, Meter, "k"))
    let r = h.raw("schema", [0xA0'u8])
    check r.code == ecOk
    let v = e.kept[^1].view
    check v.success
    check v.scope.pa.contract.schema_root == @meterRoot
    let common = meterSet.context.commonModel
    check v.request.get.schema_subtree_root ==
      @(declarationRoot(common, common.find("logos.schema_request").get))
    check v.request.get == schemaSet(common).rootsOf("logos.schema_request", @[0xA0'u8])
    check v.response.get ==
      schemaSet(common).rootsOf("logos.schema_response", r.response)
    h.release()
    # The vault marks `store`'s request and `get`'s response. Erasure is not
    # built (deferred:tier-4b), so the route is refused after its authority
    # and contract checks, whatever the policy retains, and nothing is
    # downgraded to ordinary handling (INTERFACE l.386-388).
    for rule in [
      retaining("call"), retaining("call", request = false, response = false)
    ]:
      setScript(rule)
      let refused = orch.establish(
        "v",
        root = vaultRoot,
        provider = Opt.some(providerAddress(e.view(Vault).tryGet.providerId)),
      )
      check refused.code == ecModule
      check refused.message ==
        "marked payloads are not supported on this path (INTERFACE §1.4.1)"
    check e.view(Vault).tryGet.state == msReady
    e.finish()

  test "[CAP-0244] [CAP-0257] [CAP-0264] a record holds only its CDDL fields, no ticket, key or secret; the newest call_records records are kept, in order":
    let (e, orch) = ready(records = 3)
    setScript(retaining("call"))
    var h = orch.handle(orch.routeTo(e, Meter, "k"))
    for i in 1 .. 5:
      check h.read(uint32(i)).isOk
    let records = e.audit.records
    check records.mapIt(it.index) == @[2'u64, 3, 4]
    check e.audit.recordAt(1).isNone
    check e.audit.recordAt(4) == Opt.some(records[2].bytes)
    for r in records:
      let m = decodeCbor(r.bytes).tryGet
      check m.entries.mapIt(it[0].text).toHashSet == [
        "commitments", "consumer", "decision_id", "operation", "outcome", "scopes",
        "timestamp",
      ].toHashSet
    # Each call's own request: channel `i` in its order.
    for k, r in records:
      check AuditRecord.decode(r.bytes).tryGet.view.request ==
        Opt.some(meterRoots("meter.read_request", readReq(k + 3)))
    h.release()
    e.finish()

# The Runtime as an ABI caller -----------------------------------------------------------------

suite "run.audit: the Runtime calling _MODULE_dispatch (INTERFACE §2.6)":
  test "[IFC-0249] the Runtime enters _MODULE_dispatch with the response outputs null and zero: a routed synchronous call, an asynchronous one and an authority evaluate (INTERFACE §2.6 l.1754)":
    let (e, orch) = ready()
    let dirty = dirtyEntries.load
    let evaluations = dispatchEntries.load
    discard e.started(rmeter(), Recorder)
    var h = orch.handle(orch.routeTo(e, Recorder, "r"))
    setScript(allow("call", validMs = 0)) # each call evaluated afresh
    forget()
    let entries = recordedEntries.load
    check h.raw("read", readReq(5)).code == ecOk
    check recordedEntries.load == entries + 1
    check h.callAsync(readReq(5)) == ecOk # through a call worker
    check recordedEntries.load == entries + 2
    check recordedDirty.load == 0
    # Each call's `evaluate`, besides those for starting and routing.
    check received().countIt(it.what == "call") == 2
    check dispatchEntries.load >= evaluations + 2
    check dirtyEntries.load == dirty
    h.release()
    e.finish()
