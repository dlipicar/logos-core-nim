## Runtime Control and direct routes (`runtime/bindings.nim`, `runtime/engine.nim`):
## the Runtime Control binding each attempt gets (RUNTIME §9, §9.3), route
## establishment, renewal and closure (§4, §9.3), `materialize_route` and
## route handles (INTERFACE §2.5, §5.2; RUNTIME §4.1, §7.5), invocation access
## (INTERFACE §2.9.3), and the lifecycle methods through Runtime Control.
##
## The provider is the meter kit module; the consumer is a hand-written module
## that keeps the Runtime Control binding of each initialization, so the test
## calls Runtime Control as that module. Module code runs on the engine's
## workers, so the test modules keep their state in atomics.

import std/[atomics, monotimes, os, sequtils, times, typedthreads]
import unittest2
import ../src/logos_core/runtime/engine
import ../src/logos_core/abi/types
import ../src/logos_core/cbor
import ../src/logos_core/commitment
import ../src/logos_core/iface/[accept, outcome, surface]
import ../src/logos_core/iface/common_types
import ./support/[kitbuild, kitruntime]
import ./kit/meter_impl
import ./generated/meter_module_calls

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "routes" / kitVariant
removeDir(work)
createDir(work)

# The consumer module --------------------------------------------------------------

const MaxClients = 16 ## a ring: the latest initializations

var
  clients: array[MaxClients, Atomic[pointer]] ## Runtime Control, by init order
  clientCalls: array[MaxClients, Atomic[int]]
    ## calls through each binding not yet past `release_response`
  clientInits: Atomic[int]
  clientDestroyGate: Atomic[bool] ## true while closed
  initProbe: Atomic[bool] ## call `get_self` from `_MODULE_init`
  initSelfCode: Atomic[int]

type RcResult = object
  code: ErrorCode
  message: string
  detail: seq[byte]
  response: seq[byte]

proc copyBytes(p: ptr UncheckedArray[uint8], n: csize_t): seq[byte] =
  result = newSeq[byte](int(n))
  for i in 0 ..< int(n):
    result[i] = p[i]

proc toResult(r: LogosResult): RcResult =
  result.code = errorCode(int64(r.code)).get
  if r.message != nil:
    result.message = $r.message
  if r.detail != nil:
    result.detail = copyBytes(r.detail, r.detailLen)

proc rcCall(
    rc: ptr LogosRuntimeControlBinding, name: string, params: openArray[byte]
): RcResult {.gcsafe.} =
  # A module releases every response before its `_MODULE_destroy` returns
  # (INTERFACE l.1619, l.3831): the client's destroy waits for these.
  var slot = -1
  for i in 0 ..< MaxClients:
    if clients[i].load == rc:
      slot = i
  if slot >= 0:
    discard clientCalls[slot].fetchAdd(1)
  defer:
    if slot >= 0:
      discard clientCalls[slot].fetchSub(1)
  var buf: ptr UncheckedArray[uint8]
  var len: csize_t
  let r = rc.vtable.call(
    rc,
    cstring(name),
    cast[ptr UncheckedArray[uint8]](unsafeAddr params[0]),
    csize_t(params.len),
    addr buf,
    addr len,
  )
  result = toResult(r)
  if buf != nil:
    result.response = copyBytes(buf, len)
    rc.vtable.releaseResponse(rc, buf, len)

proc clientName(): cstring {.cdecl.} =
  "client_module"

proc clientInit(
    input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
): LogosResult {.cdecl.} =
  let i = clientInits.fetchAdd(1) mod MaxClients
  # A binding's storage is reused once its instance is gone: one slot per pointer.
  for j in 0 ..< MaxClients:
    if clients[j].load == input.runtimeControl:
      clients[j].store(nil)
  clients[i].store(input.runtimeControl)
  if initProbe.load:
    {.cast(gcsafe).}:
      initSelfCode.store(ord(rcCall(input.runtimeControl, "get_self", [0xA0'u8]).code))
  let slot = cast[ptr int](allocShared0(sizeof(int)))
  slot[] = i
  outContext[] = cast[ptr LogosModuleContext](slot)

proc clientDestroy(module: ptr LogosModuleContext) {.cdecl.} =
  let slot = cast[ptr int](module)[]
  while clientDestroyGate.load or clientCalls[slot].load > 0:
    sleep(1)
  deallocShared(module)

proc clientTable(): seq[(string, pointer)] =
  @[
    ("logos_client_module_MODULE_name", cast[pointer](clientName)),
    ("logos_client_module_MODULE_init", cast[pointer](clientInit)),
    ("logos_client_module_MODULE_destroy", cast[pointer](clientDestroy)),
  ]

# A module whose initialization waits at a gate -------------------------------------

var slowGate: Atomic[bool]

proc slowName(): cstring {.cdecl.} =
  "slow_module"

proc slowInit(
    input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
): LogosResult {.cdecl.} =
  while slowGate.load:
    sleep(1)
  outContext[] = cast[ptr LogosModuleContext](allocShared0(16))

proc slowDestroy(module: ptr LogosModuleContext) {.cdecl.} =
  deallocShared(module)

proc slowTable(): seq[(string, pointer)] =
  @[
    ("logos_slow_module_MODULE_name", cast[pointer](slowName)),
    ("logos_slow_module_MODULE_init", cast[pointer](slowInit)),
    ("logos_slow_module_MODULE_destroy", cast[pointer](slowDestroy)),
  ]

# Engine set-up ------------------------------------------------------------------------

proc services(
    instance, attempt: cstring
): InitServices {.nimcall, gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    InitServices(publish: publishOp, publishUserData: addr publishState)

var engines = 0

proc config(policy = allowAll()): EngineConfig =
  inc engines
  result = defaultConfig(work / ("e" & $engines))
  result.services = services
  result.policy = policy
  result.stopDeadline = initDuration(milliseconds = 300)
  result.statics = @[
    checkStaticRegistration("client", clientTable()).tryGet,
    checkStaticRegistration("slow", slowTable()).tryGet,
    checkStaticRegistration("meter", meterModuleStaticSymbols()).tryGet,
  ]

let
  meterSet =
    acceptContractSet(readFile(repo / "spec/mirrors/IFC/3.9.1.module.cddl")).tryGet
  meterRoot = meterSet.primary.root
  meterSchema = encodeCbor(schemaResponse(meterSet, meterRoot).tryGet)

proc declRoot(name: string): seq[byte] =
  let m = meterSet.primary.model
  @(declarationRoot(m, m.find(name).get))

func client(): ModuleRecord =
  ModuleRecord(module: "client_module", strategy: stDirectStatic, binding: "client")

func slow(): ModuleRecord =
  ModuleRecord(module: "slow_module", strategy: stDirectStatic, binding: "slow")

proc meter(): ModuleRecord =
  ModuleRecord(
    module: "meter_module",
    strategy: stDirectStatic,
    binding: "meter",
    primaryContract: Opt.some(meterRoot),
  )

proc waitUntil(cond: proc(): bool {.closure.}, seconds = 10): bool =
  let until = getMonoTime() + initDuration(seconds = seconds)
  while getMonoTime() < until:
    if cond():
      return true
    sleep(2)
  cond()

proc finish(e: Engine) =
  clientDestroyGate.store(false)
  slowGate.store(false)
  gate.store(false)
  e.shutdown()
  check e.close()

proc started(e: Engine, r: ModuleRecord, instance = ""): InstanceView =
  let v = e.create(r, instance).tryGet
  check e.start(v.instance).tryGet.state == msReady
  e.view(v.instance).tryGet

proc startClient(
    e: Engine, instance = ""
): (InstanceView, ptr LogosRuntimeControlBinding) =
  let v = e.started(client(), instance)
  let i = (clientInits.load - 1) mod MaxClients
  (v, cast[ptr LogosRuntimeControlBinding](clients[i].load))

# Requests -----------------------------------------------------------------------------

proc access(
    methods = Opt.none(seq[seq[byte]]),
    publish = Opt.none(seq[seq[byte]]),
    subscribe = Opt.none(seq[seq[byte]]),
): LogosNSRuntimeControlRouteAccess =
  LogosNSRuntimeControlRouteAccess(
    methods: methods, publish_events: publish, subscribe_events: subscribe
  )

proc establishReq(
    key: string,
    root = meterRoot,
    all = false,
    provider = Opt.none(LogosNSRuntimeModuleProviderAddress),
    scope = access(),
): seq[byte] =
  encode(
    LogosNSRuntimeControlEstablishRouteRequest(
      request_key: key,
      contract: SchemaCommitment(schema_root: @root),
      cardinality: LogosNSRuntimeControlProviderRequirementCardinality(
        kind: (
          if all:
          LogosNSRuntimeControlProviderRequirementCardinalityKind.All_runtime_visible
          else: LogosNSRuntimeControlProviderRequirementCardinalityKind.Single
        )
      ),
      provider: provider,
      access: scope,
    )
  ).tryGet

proc establish(
    rc: ptr LogosRuntimeControlBinding,
    key: string,
    root = meterRoot,
    all = false,
    provider = Opt.none(LogosNSRuntimeModuleProviderAddress),
    scope = access(),
): RcResult =
  rcCall(rc, "establish_route", establishReq(key, root, all, provider, scope))

proc routesOf(r: RcResult): LogosNSRuntimeControlEstablishRouteResponse =
  LogosNSRuntimeControlEstablishRouteResponse.decode(r.response).tryGet

proc routeId(rc: ptr LogosRuntimeControlBinding, key: string): string =
  let r = rc.establish(key)
  check r.code == ecOk
  r.routesOf.routes[0].route

proc renew(rc: ptr LogosRuntimeControlBinding, key, route: string): RcResult =
  rcCall(
    rc,
    "renew_route",
    encode(LogosNSRuntimeControlRenewRouteRequest(request_key: key, route: route)).tryGet,
  )

proc close(rc: ptr LogosRuntimeControlBinding, route: string): RcResult =
  rcCall(
    rc,
    "close_route",
    encode(LogosNSRuntimeControlCloseRouteRequest(route: route)).tryGet,
  )

proc providerAddress(
    id: string, runtime = Opt.none(string)
): LogosNSRuntimeModuleProviderAddress =
  LogosNSRuntimeModuleProviderAddress(provider: id, runtime_instance_id: runtime)

proc materialize(
    rc: ptr LogosRuntimeControlBinding,
    route: string,
    root = meterRoot,
    schema = meterSchema,
): (ErrorCode, LogosRouteHandle) =
  var h = LogosRouteHandle()
  var r: ContractRoot = root
  let res = rc.vtable.materializeRoute(
    rc,
    cstring(route),
    addr r,
    cast[ptr UncheckedArray[uint8]](unsafeAddr schema[0]),
    csize_t(schema.len),
    addr h,
  )
  (toResult(res).code, h)

proc handle(rc: ptr LogosRuntimeControlBinding, route: string): LogosRouteHandle =
  let (code, h) = rc.materialize(route)
  check code == ecOk
  h

proc raw(h: var LogosRouteHandle, name: string, params: openArray[byte]): RcResult =
  var buf: ptr UncheckedArray[uint8]
  var len: csize_t
  let r = h.vtable.call(
    addr h,
    cstring(name),
    cast[ptr UncheckedArray[uint8]](unsafeAddr params[0]),
    csize_t(params.len),
    addr buf,
    addr len,
  )
  result = toResult(r)
  if buf != nil:
    result.response = copyBytes(buf, len)
    h.vtable.releaseResponse(addr h, buf, len)

proc read(
    h: var LogosRouteHandle, channel: uint32
): Result[MeterReadResponse, InvocationFailure] =
  invoke(addr h, MeterReadRequest(channel: channel))

proc release(h: var LogosRouteHandle) =
  h.vtable.release(addr h)

proc lifecycle(
    rc: ptr LogosRuntimeControlBinding,
    name, module: string,
    instance = Opt.none(string),
    provider = Opt.none(LogosNSRuntimeModuleProviderAddress),
    expected = Opt.none(uint64),
): RcResult =
  let bytes =
    if name == "start_module":
      encode(
        LogosNSRuntimeControlStartModuleRequest(
          module: module,
          instance: instance,
          provider: provider,
          expected_execution_revision: expected,
        )
      ).tryGet
    else:
      encode(
        LogosNSRuntimeControlStopModuleRequest(
          module: module,
          instance: instance,
          provider: provider,
          expected_execution_revision: expected,
        )
      ).tryGet
  rcCall(rc, name, bytes)

type EndSeen = object
  count: Atomic[int]
  code: Atomic[int]

proc onEnd(reason: CErrorCode, userData: pointer) {.cdecl, gcsafe, raises: [].} =
  let s = cast[ptr EndSeen](userData)
  s.code.store(int(reason))
  s.count.atomicInc

proc observe(h: var LogosRouteHandle, seen: ptr EndSeen): ErrorCode =
  toResult(h.vtable.observeEnd(addr h, onEnd, seen)).code

var
  bgCode, bgValue: Atomic[int]
  bgDone: Atomic[bool]

proc background(h: ptr LogosRouteHandle) {.thread.} =
  let r = invoke(h, MeterReadRequest(channel: 19))
  if r.isOk:
    bgCode.store(0)
    bgValue.store(int(r.get.reading.value))
  else:
    bgCode.store(ord(r.error.code))
  bgDone.store(true)

# Tests --------------------------------------------------------------------------------

suite "run.routes: Runtime Control binding (RUNTIME §9, §9.3; INTERFACE §5.2)":
  test "[RUN-0490] [RUN-0492] a generated Runtime identity is a lowercase UUID version 4 (§9.2 l.2669)":
    let id = newRuntimeInstanceId()
    check id.len == 36
    check id[8] == '-' and id[13] == '-' and id[14] == '4' and id[18] == '-'
    check id[19] in {'8', '9', 'a', 'b'}
    for c in id:
      check c in {'0' .. '9', 'a' .. 'f', '-'}
    check newRuntimeInstanceId() != id

  test "[RUN-0896] [RUN-0901] [RUN-0902] [RUN-0908] [RUN-0909] get_self and get_execution_permissions are caller-bound (§9.3 l.2553, l.2562)":
    let e = newEngine(config(denying(deny(action = Opt.some(aaRuntimeControl)))))
    let (c, rc) = e.startClient()
    let r = rcCall(rc, "get_self", [0xA0'u8])
    check r.code == ecOk
    let me = LogosNSRuntimeControlGetSelfResponse.decode(r.response).tryGet
    check me.consumer.module_instance_id == c.instance
    check me.consumer.runtime_instance_id == e.runtimeInstanceId
    let p = rcCall(rc, "get_execution_permissions", [0xA0'u8])
    check p.code == ecOk
    check LogosNSRuntimeControlGetExecutionPermissionsResponse.decode(p.response).tryGet.kind ==
      LogosNSRuntimeControlGetExecutionPermissionsResponseKind.Unavailable
    # A method needing a policy grant is refused by the same policy.
    check rcCall(rc, "shutdown_runtime", [0xA0'u8]).code == ecNotAuthorised
    e.finish()

  test "[RUN-0897] [RUN-0905] get_self is callable during initialization (§9.3 l.2557)":
    initProbe.store(true)
    initSelfCode.store(-1)
    let e = newEngine(config())
    discard e.startClient()
    initProbe.store(false)
    check initSelfCode.load == ord(ecOk)
    e.finish()

  test "[RUN-0042] [IFC-0416] [IFC-0418] [IFC-0419] method names and requests are checked before anything else (INTERFACE §4.5)":
    let e = newEngine(config())
    let (_, rc) = e.startClient()
    check rcCall(rc, "no_such_method", [0xA0'u8]).code == ecMethodNotFound
    check rcCall(rc, "", [0xA0'u8]).code == ecMethodNotFound
    let extra = rcCall(rc, "get_self", encodeCbor(cborMap(@[(cbor("x"), cbor(1'u64))])))
    check extra.code == ecInvalidParams
    check extra.detail.len > 0
    let broken = rcCall(rc, "get_self", [0xFF'u8])
    check broken.code == ecInvalidParams
    check rcCall(rc, "start_module", [0xA0'u8]).code == ecInvalidParams
    # A method of the contract this Runtime does not perform yet [IMPL].
    check rcCall(rc, "list_modules", [0xA0'u8]).code == ecModule
    var len: csize_t
    let empty = [0xA0'u8]
    let r = rc.vtable.call(
      rc,
      "get_self",
      cast[ptr UncheckedArray[uint8]](unsafeAddr empty[0]),
      1,
      nil,
      addr len,
    )
    check toResult(r).code == ecInvalidParams
    e.finish()

  test "[RUN-0043] [RUN-0044] [IFC-0501] connect_remote: a valid endpoint names no enrolled Runtime (§4.4)":
    let e = newEngine(config())
    let (_, rc) = e.startClient()
    var acquired = LogosRuntimeControlBinding()
    var root: ContractRoot
    let bad = [0xA0'u8]
    check toResult(
      rc.vtable.connectRemote(
        rc,
        cast[ptr UncheckedArray[uint8]](unsafeAddr bad[0]),
        1,
        addr root,
        addr acquired,
      )
    ).code == ecInvalidParams
    let good = encode(
      LogosNSRuntimeControlRuntimeEndpoint(
        address: LogosNSRuntimeControlRuntimeAddress(
          kind:
            LogosNSRuntimeControlRuntimeAddressKind.logos_NS_runtime_control_Unix_stream_runtime_address,
          arm_logos_NS_runtime_control_Unix_stream_runtime_address:
            LogosNSRuntimeControlUnixStreamRuntimeAddress(path: "/run/logos.sock"),
        )
      )
    ).tryGet
    check toResult(
      rc.vtable.connectRemote(
        rc,
        cast[ptr UncheckedArray[uint8]](unsafeAddr good[0]),
        csize_t(good.len),
        addr root,
        addr acquired,
      )
    ).code == ecNotAuthorised
    check acquired.vtable == nil and acquired.state == nil
    e.finish()

  test "[RUN-0794] [RUN-0900] a binding that is stopping is NOT_READY (§3.4 l.629-631)":
    let e = newEngine(config())
    let (c, rc) = e.startClient()
    clientDestroyGate.store(true)
    check e.stop(c.instance).tryGet.state == msStopping
    check rcCall(rc, "get_self", [0xA0'u8]).code == ecNotReady
    clientDestroyGate.store(false)
    check waitUntil(
      proc(): bool =
        e.view(c.instance).tryGet.state == msUnloaded
    )
    e.finish()

  test "[IMPL-DECISION G171] [RUN-0039] [RUN-0850] [RUN-0874] what needs no payload is authorized first, readiness last [IMPL-DECISION G171] (TF-18)":
    let e = newEngine(
      config(
        denying(
          deny(
            action = Opt.some(aaRuntimeControl),
            operation = "establish_route",
            consumer = "c2",
          ),
          deny(
            action = Opt.some(aaRuntimeControl),
            operation = "renew_route",
            consumer = "c2",
          ),
        )
      )
    )
    discard e.started(meter())
    let (_, rc) = e.startClient("c1")
    let (c2, refused) = e.startClient("c2")
    # A malformed request: the method's own authority first, where it names no
    # target from the payload.
    check rcCall(rc, "establish_route", [0xA0'u8]).code == ecInvalidParams
    check rcCall(refused, "establish_route", [0xA0'u8]).code == ecNotAuthorised
    check rcCall(refused, "renew_route", [0xA0'u8]).code == ecInvalidParams
    check rcCall(refused, "shutdown_runtime", [0x01'u8]).code == ecInvalidParams
    # An invalidated binding: authorization, then readiness.
    clientDestroyGate.store(true)
    check e.stop(c2.instance).tryGet.state == msStopping
    check refused.establish("k").code == ecNotAuthorised
    check refused.renew("r", "route-unknown").code == ecNotAuthorised
    check rcCall(refused, "get_self", [0xA0'u8]).code == ecNotReady
    clientDestroyGate.store(false)
    check waitUntil(
      proc(): bool =
        e.view(c2.instance).tryGet.state == msUnloaded
    )
    e.finish()

  test "[RUN-0113] [RUN-0794] a caller waiting in start_module is released when its binding ends (§3.4)":
    let e = newEngine(config())
    let s = e.create(slow()).tryGet
    let (c, rc) = e.startClient()
    slowGate.store(true)
    var t: Thread[(ptr LogosRuntimeControlBinding, string)]
    bgDone.store(false)
    createThread(
      t,
      proc(a: (ptr LogosRuntimeControlBinding, string)) {.thread.} =
        let r = lifecycle(a[0], "start_module", "slow_module", Opt.some(a[1]))
        bgCode.store(ord(r.code))
        bgDone.store(true),
      (rc, s.instance),
    )
    check waitUntil(
      proc(): bool =
        e.view(s.instance).tryGet.state == msLoaded
    )
    check not bgDone.load
    discard e.stop(c.instance)
    joinThread(t)
    check bgCode.load == ord(ecNotReady)
    slowGate.store(false)
    check waitUntil(
      proc(): bool =
        e.view(s.instance).tryGet.state == msReady
    )
    e.finish()

suite "run.routes: establish, renew and close (RUNTIME §4, §9.3)":
  test "[RUN-0557] [RUN-0943] [RUN-0542] [RUN-0624] [RUN-0184] a single route to a ready provider (§9.3 l.3135-3146)":
    let e = newEngine(config())
    let m = e.started(meter())
    let (c, rc) = e.startClient()
    let r = rc.establish("k1")
    check r.code == ecOk
    let resp = r.routesOf
    check resp.routes.len == 1
    check not resp.partial
    check resp.continuations.len == 0
    let rec = resp.routes[0]
    check rec.consumer.module_instance_id == c.instance
    check rec.consumer.runtime_instance_id == e.runtimeInstanceId
    check rec.target_provider.provider == m.providerId
    check rec.target_provider.runtime_instance_id == Opt.some(e.runtimeInstanceId)
    check rec.module == "meter_module"
    check rec.instance == Opt.some(m.instance)
    check rec.expected_contract.get.schema_root == @meterRoot
    check rec.state.kind == LogosNSRuntimeControlRouteStateKind.Ready
    check rec.decision_id.isSome
    check rec.invocation.isNone # a direct route (l.3469)
    check rec.failure.isNone
    check e.routes().mapIt(encode(it).tryGet) == @[encode(rec).tryGet]
    e.finish()

  test "[IMPL-DECISION G169] [RUN-0556] [RUN-0188] [RUN-0121] establishment failures":
    let e = newEngine(config())
    let idle = e.create(meter()).tryGet
    let (_, rc) = e.startClient()
    var zero: Digest
    # [G169 interim (TF-16)] A `discover` allow, and no provider offers it.
    check rc.establish("a", root = zero).code == ecNotReady
    # An allowed provider that is not ready.
    check rc.establish("b").code == ecNotReady
    check rc.establish(
      "c", all = true, provider = Opt.some(providerAddress(idle.providerId))
    ).code == ecInvalidParams
    check e.start(idle.instance).tryGet.state == msReady
    let high = newSeq[byte](32).mapIt(0xFF'u8)
    let low = newSeq[byte](32)
    check rc.establish("d", scope = access(methods = Opt.some(@[high, low]))).code ==
      ecInvalidParams
    check rc.establish("e", scope = access(methods = Opt.some(@[low]))).code ==
      ecInvalidParams
    let event = declRoot("meter.changed_event")
    check rc.establish("f", scope = access(methods = Opt.some(@[event]))).code ==
      ecInvalidParams
    check rc.establish(
      "g", scope = access(publish = Opt.some(@[declRoot("meter.read")]))
    ).code == ecInvalidParams
    check rc.establish("h", scope = access(subscribe = Opt.some(@[event]))).code == ecOk
    check rc.establish(
      "i", provider = Opt.some(providerAddress(idle.providerId, Opt.some("elsewhere")))
    ).code == ecNotAuthorised
    check rc.establish("j", provider = Opt.some(providerAddress("p-unknown"))).code ==
      ecNotReady
    check rc.establish("k", provider = Opt.some(providerAddress(idle.providerId))).code ==
      ecOk
    check e.routes().len == 2
    e.finish()

  test "[IMPL-DECISION G52] [IMPL-DECISION G169] [RUN-0850] [RUN-0186] [RUN-0563] [RUN-0564] authorization at establishment (§9 l.1626, l.3138; G52)":
    for rule in [
      deny(action = Opt.some(aaRuntimeControl), operation = "establish_route"),
      deny(action = Opt.some(aaRoute)),
    ]:
      let e = newEngine(config(denying(rule)))
      discard e.started(meter())
      let (_, rc) = e.startClient()
      check rc.establish("k").code == ecNotAuthorised
      check rc.establish("a", all = true).code == ecNotAuthorised
      check e.routes().len == 0
      e.finish()
    let e = newEngine(config(denying(deny(action = Opt.some(aaDiscover)))))
    discard e.started(meter())
    let (_, rc) = e.startClient()
    check rc.establish("k", all = true).code == ecNotAuthorised
    var zero: Digest
    # [G169 interim (TF-16)] No route allow and no `discover` allow.
    check rc.establish("z", root = zero).code == ecNotAuthorised
    check rc.establish("k").code == ecOk
    e.finish()

  test "[RUN-0947] request_key replay (§9.3 l.3176-3183)":
    let e = newEngine(config())
    let m = e.create(meter()).tryGet
    let (_, rc) = e.startClient()
    check rc.establish("k2").code == ecNotReady # failures are not retained
    check e.start(m.instance).tryGet.state == msReady
    let first = rc.establish("k1")
    check first.code == ecOk
    let again = rc.establish("k1")
    check again.code == ecOk
    check again.response == first.response
    check e.routes().len == 1
    check rc.establish("k1", all = true).code == ecInvalidParams
    check rc.renew("k1", first.routesOf.routes[0].route).code == ecInvalidParams
    check rc.establish("k2").code == ecOk
    check e.routes().len == 2
    e.finish()

  test "[RUN-0556] [RUN-0557] [RUN-0558] [RUN-0280] all-runtime-visible and single selection (§9.3 l.3140-3146)":
    let e = newEngine(config())
    let a = e.started(meter())
    let b = e.create(meter()).tryGet
    let (_, rc) = e.startClient()
    let partial = rc.establish("x1", all = true)
    check partial.code == ecOk
    check partial.routesOf.routes.len == 1
    check partial.routesOf.partial
    check e.start(b.instance).tryGet.state == msReady
    let full = rc.establish("x2", all = true).routesOf
    check full.routes.len == 2
    check not full.partial
    let single = rc.establish("x3").routesOf
    check single.routes.len == 1
    check not single.partial
    check single.routes[0].target_provider.provider == a.providerId
    let chosen =
      rc.establish("x4", provider = Opt.some(providerAddress(b.providerId))).routesOf
    check chosen.routes[0].target_provider.provider == b.providerId
    e.finish()

  test "[RUN-0570] [RUN-0625] [RUN-0360] renew_route (§9.3 l.3183-3190, l.3471-3484)":
    let e = newEngine(
      config(
        denying(
          deny(action = Opt.some(aaRoute), operation = "renew_route", route = "route-x")
        )
      )
    )
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let first = rc.establish("k").routesOf.routes[0]
    let r = rc.renew("r1", first.route)
    check r.code == ecOk
    let renewed =
      LogosNSRuntimeControlRenewRouteResponse.decode(r.response).tryGet.route
    check renewed.route == first.route
    check renewed.decision_id != first.decision_id
    check renewed.access == first.access
    check rc.renew("r2", "route-unknown").code == ecNotAuthorised
    check rc.close(first.route).code == ecOk
    check rc.renew("r3", first.route).code == ecNotReady
    e.finish()

  test "[IMPL-DECISION G170] [RUN-0887] [RUN-0836] [RUN-0990] [RUN-0580] a denied renewal revokes the route [IMPL-DECISION G170] (TF-17)":
    let e = newEngine(
      config(denying(deny(action = Opt.some(aaRoute), operation = "renew_route")))
    )
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let first = rc.establish("k").routesOf.routes[0]
    var h = rc.handle(first.route)
    var seen: EndSeen
    check h.observe(addr seen) == ecOk
    check rc.renew("r1", first.route).code == ecNotAuthorised
    let rec = e.routes()[0]
    check rec.state.kind == LogosNSRuntimeControlRouteStateKind.Revoked
    check rec.failure.get.code == "authority-denied"
    check rec.decision_id == first.decision_id
    check waitUntil(
      proc(): bool =
        seen.count.load == 1
    )
    check seen.code.load == ord(ecNotAuthorised)
    check h.read(5).error.code == ecNotAuthorised
    check rc.renew("r2", first.route).code == ecNotAuthorised
    # A terminal route is reported as it is.
    let closed = rc.close(first.route)
    check closed.code == ecOk
    check LogosNSRuntimeControlCloseRouteResponse.decode(closed.response).tryGet.state.kind ==
      LogosNSRuntimeControlRouteStateKind.Revoked
    h.release()
    e.finish()

  test "[IMPL-DECISION G170] [RUN-0626] close_route (§9.3 l.3486-3492)":
    let e = newEngine(
      config(
        denying(
          deny(
            action = Opt.some(aaRuntimeControl),
            operation = "close_route",
            consumer = "c3",
          )
        )
      )
    )
    discard e.started(meter())
    let (_, rc) = e.startClient("c1")
    let (_, other) = e.startClient("c2")
    let (_, refused) = e.startClient("c3")
    let mine = rc.routeId("k1")
    let theirs = rc.routeId("k2")
    let r = rc.close(mine)
    check r.code == ecOk
    let closed = LogosNSRuntimeControlCloseRouteResponse.decode(r.response).tryGet
    check closed.route == mine
    check closed.state.kind == LogosNSRuntimeControlRouteStateKind.Closed
    check rc.close(mine).code == ecOk
    check rc.close("route-unknown").code == ecNotAuthorised
    check refused.close(theirs).code == ecNotAuthorised
    check other.renew("o", theirs).code == ecNotAuthorised
    check other.close(theirs).code == ecOk
    for rec in e.routes():
      check rec.state.kind == LogosNSRuntimeControlRouteStateKind.Closed
      check rec.failure.isNone
    e.finish()

suite "run.routes: route handles (INTERFACE §2.5, §5.2; RUNTIME §4.1, §7.5)":
  test "[IFC-0510] [IFC-0491] [RUN-0866] [RUN-0152] materialize a route and call the provider through it":
    let e = newEngine(config())
    discard e.started(meter())
    let (c, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    let x = h.read(5).tryGet
    check x.label == "ch5"
    check x.reading.value == 50
    # [SPEC INTERFACE §2.9.3] The provider sees the consumer as its caller.
    let who = h.read(18).tryGet
    check who.label == c.instance
    check who.reading.label == Opt.some(e.runtimeInstanceId)
    check who.reading.value == 0
    h.release()
    e.finish()

  test "[IFC-0448] [IFC-0930] logos.schema is answered by the boundary (INTERFACE l.3275-3277)":
    let e = newEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    let s = h.raw("schema", [0xA0'u8])
    check s.code == ecOk
    check acceptSchemaResponse(s.response, meterRoot).isOk
    check h.raw("schema", [0xA1'u8, 0x61, 0x78, 0x01]).code == ecInvalidParams
    h.release()
    e.finish()

  test "[IMPL-DECISION G172] [RUN-0152] [RUN-0153] [IFC-0932] provider failures, bad requests and bad responses":
    let e = newEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    let f = h.read(13)
    check f.isErr
    check f.error.code == ecModule
    check f.error.message == Opt.some("channel 13 is broken")
    check h.read(14).error.code == ecModule
    check h.read(16).error.code == ecModule
    check h.raw("nope", [0xA0'u8]).code == ecMethodNotFound
    let bad = h.raw("read", encodeCbor(cborMap(@[(cbor("channel"), cbor("x"))])))
    check bad.code == ecInvalidParams
    check bad.detail.len > 0
    check h.read(5).isOk
    h.release()
    e.finish()

  test "[RUN-0866] [RUN-0188] the access scope and the per-call decision (§9.3 l.3003-3004; l.1732)":
    let e =
      newEngine(config(denying(deny(action = Opt.some(aaCall), consumer = "denied"))))
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let empty =
      rc.establish("e", scope = access(methods = Opt.some(newSeq[seq[byte]]())))
    var h = rc.handle(empty.routesOf.routes[0].route)
    check h.read(5).error.code == ecNotAuthorised
    check h.raw("schema", [0xA0'u8]).code == ecNotAuthorised
    h.release()
    let readOnly =
      rc.establish("r", scope = access(methods = Opt.some(@[declRoot("meter.read")])))
    var r = rc.handle(readOnly.routesOf.routes[0].route)
    check r.read(5).isOk
    check r.raw("schema", [0xA0'u8]).code == ecNotAuthorised
    r.release()
    let (_, denied) = e.startClient("denied")
    var d = denied.handle(denied.routeId("d"))
    check d.read(5).error.code == ecNotAuthorised
    d.release()
    e.finish()

  test "[IFC-0943] [IFC-0945] [IFC-0946] [IFC-0947] [RUN-0184] materialize_route failures (INTERFACE §5.2 l.3884-3890)":
    let e = newEngine(
      config(
        denying(
          deny(
            action = Opt.some(aaRoute), operation = "materialize_route", consumer = "c3"
          )
        )
      )
    )
    discard e.started(meter())
    let (_, rc) = e.startClient("c1")
    let (_, other) = e.startClient("c2")
    let (_, refused) = e.startClient("c3")
    let route = rc.routeId("k")
    for (code, h) in [
      rc.materialize("route-unknown"),
      other.materialize(route),
      refused.materialize(refused.routeId("k")),
    ]:
      check code == ecNotAuthorised
      check h.vtable == nil and h.state == nil
    var zero: Digest
    check rc.materialize(route, root = zero)[0] == ecVersionMismatch
    check rc.materialize(route, schema = @[0x01'u8])[0] == ecInvalidParams
    var h = rc.handle(route)
    var h2 = rc.handle(route) # several handles per route
    check h.read(1).isOk and h2.read(2).isOk
    h.release()
    h2.release()
    check rc.close(route).code == ecOk
    check rc.materialize(route)[0] == ecNotReady
    e.finish()

  test "[IFC-0656] [IFC-0657] [IFC-0659] [IFC-0661] [IFC-0663] [IFC-0664] [RUN-0256] [RUN-0837] observe_end and closure (INTERFACE §2.5 l.1474-1497)":
    let e = newEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let route = rc.routeId("k")
    var h = rc.handle(route)
    var late = rc.handle(route)
    var seen, lateSeen: EndSeen
    check toResult(h.vtable.observeEnd(addr h, nil, nil)).code == ecInvalidParams
    check h.observe(addr seen) == ecOk
    check h.observe(addr seen) == ecInvalidParams
    check rc.close(route).code == ecOk
    check waitUntil(
      proc(): bool =
        seen.count.load == 1
    )
    check seen.code.load == ord(ecNotReady)
    check h.read(5).error.code == ecNotReady
    check late.observe(addr lateSeen) == ecNotReady
    sleep(20)
    check seen.count.load == 1
    check lateSeen.count.load == 0
    h.release()
    late.release()
    e.finish()

  test "[IFC-0516] a released handle gets no terminal callback (INTERFACE §5.2 l.3912-3916)":
    let e = newEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let route = rc.routeId("k")
    var h = rc.handle(route)
    var seen: EndSeen
    check h.observe(addr seen) == ecOk
    h.release()
    check rc.close(route).code == ecOk
    sleep(20)
    check seen.count.load == 0
    e.finish()

suite "run.routes: routes follow their provider and consumer (RUNTIME §3.4, §9.3)":
  test "[IMPL-DECISION G171] [RUN-0579] [RUN-0580] [RUN-0360] [RUN-0887] [IFC-0665] a stopped provider fails its routes":
    let e = newEngine(config())
    let m = e.started(meter())
    let (_, rc) = e.startClient()
    let route = rc.routeId("k")
    var h = rc.handle(route)
    var seen: EndSeen
    check h.observe(addr seen) == ecOk
    check e.stop(m.instance).tryGet.state == msUnloaded
    check waitUntil(
      proc(): bool =
        seen.count.load == 1
    )
    check seen.code.load == ord(ecNotReady)
    check h.read(5).error.code == ecNotReady
    # [G171 interim (TF-18)] The payload is validated before readiness.
    let bad = h.raw("read", encodeCbor(cborMap(@[(cbor("channel"), cbor("x"))])))
    check bad.code == ecInvalidParams
    check bad.detail.len > 0
    check h.raw("schema", [0x01'u8]).code == ecInvalidParams
    check h.raw("nope", [0xA0'u8]).code == ecMethodNotFound
    let rec = e.routes()[0]
    check rec.state.kind == LogosNSRuntimeControlRouteStateKind.Failed
    check rec.failure.get.code == "provider-unavailable"
    # Restarting the provider does not revive the route (§9.3 l.3217).
    check e.start(m.instance).tryGet.state == msReady
    check h.read(5).error.code == ecNotReady
    check rc.renew("r", route).code == ecNotReady
    h.release()
    e.finish()

  test "[RUN-0111] [RUN-0112] a stopped consumer closes its routes; a failed one fails them (l.624-626)":
    let e = newEngine(config())
    discard e.started(meter())
    let (c1, rc1) = e.startClient()
    discard rc1.routeId("k")
    check e.stop(c1.instance).tryGet.state == msUnloaded
    let closed = e.routes()[0]
    check closed.state.kind == LogosNSRuntimeControlRouteStateKind.Closed
    check closed.failure.isNone
    let (c2, rc2) = e.startClient()
    discard rc2.routeId("k")
    let r = rcCall(
      rc2,
      "report_failure",
      encode(LogosNSRuntimeControlReportFailureRequest(reason: Opt.some("broken"))).tryGet,
    )
    check r.code == ecOk
    check r.response == @[0xA0'u8]
    check waitUntil(
      proc(): bool =
        e.view(c2.instance).tryGet.state == msError
    )
    let failed = e.routes()[1]
    check failed.state.kind == LogosNSRuntimeControlRouteStateKind.Failed
    check failed.failure.get.code == "consumer-unavailable"
    e.finish()

  test "[IFC-0740] [IFC-0287] an admitted call holds its provider's release and sees cancellation (§3.4 l.623)":
    let e = newEngine(config())
    let m = e.started(meter())
    let (_, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    let before = destroyed.load
    gate.store(true)
    bgDone.store(false)
    var t: Thread[ptr LogosRouteHandle]
    createThread(t, background, addr h)
    check waitUntil(
      proc(): bool =
        held.load == 1
    )
    # The stop deadline passes with the call still inside the provider.
    check e.stop(m.instance).tryGet.state == msStopping
    check destroyed.load == before
    check e.routes()[0].state.kind == LogosNSRuntimeControlRouteStateKind.Failed
    gate.store(false)
    joinThread(t)
    check bgCode.load == 0
    check bgValue.load == 1 # INTERFACE l.2101-2102: marked cancelled
    check waitUntil(
      proc(): bool =
        e.view(m.instance).tryGet.state == msUnloaded
    )
    check destroyed.load == before + 1
    h.release()
    e.finish()

suite "run.routes: lifecycle through Runtime Control (RUNTIME §9.3 l.3640-3690)":
  test "[RUN-1031] [RUN-1032] [RUN-1033] [RUN-1034] [RUN-1035] [RUN-1036] [RUN-1037] [RUN-1042] selection by instance, by name and by provider":
    let e = newEngine(config())
    let m = e.create(meter(), "m1").tryGet
    let (c, rc) = e.startClient()
    let s = rc.lifecycle("start_module", "meter_module", Opt.some("m1"))
    check s.code == ecOk
    let started = LogosNSRuntimeControlStartModuleResponse.decode(s.response).tryGet
    check started.instance == Opt.some("m1")
    check started.provider.isNone
    check started.state.kind == LogosNSRuntimeControlStateKind.Ready
    let v = e.view("m1").tryGet
    check v.intentOrigin.instance == c.instance
    let stop = rc.lifecycle("stop_module", "meter_module")
    check stop.code == ecOk
    check LogosNSRuntimeControlStopModuleResponse.decode(stop.response).tryGet.instance ==
      Opt.some("m1")
    let prov = Opt.some(providerAddress(m.providerId))
    check rc.lifecycle("start_module", "meter_module", Opt.some("m1"), prov).code ==
      ecInvalidParams
    check rc.lifecycle("start_module", "meter_module", provider = prov).code ==
      ecInvalidParams
    check rc.lifecycle(
      "start_module", "meter_module", provider = prov, expected = Opt.some(1'u64)
    ).code == ecInvalidParams
    check rc.lifecycle(
      "start_module",
      "meter_module",
      provider = Opt.some(providerAddress(m.providerId, Opt.some("elsewhere"))),
    ).code == ecInvalidParams
    check rc.lifecycle(
      "start_module", "meter_module", provider = Opt.some(providerAddress("p-unknown"))
    ).code == ecNotAuthorised
    check rc.lifecycle("start_module", "meter_module", Opt.some("nobody")).code ==
      ecNotAuthorised
    check rc.lifecycle("start_module", "other_module", Opt.some("m1")).code ==
      ecInvalidParams
    check rc.lifecycle(
      "start_module", "meter_module", Opt.some("m1"), expected = Opt.some(999'u64)
    ).code == ecInvalidParams
    discard e.create(meter(), "m2").tryGet
    check rc.lifecycle("start_module", "meter_module").code == ecInvalidParams
    check rc.lifecycle("start_module", "nothing_module").code == ecInvalidParams
    e.finish()

  test "[RUN-1038] [RUN-1039] [RUN-1040] name-only selection needs observation authority first (l.3666-3670)":
    let e = newEngine(config(denying(deny(action = Opt.some(aaObserve)))))
    discard e.create(meter(), "m1").tryGet
    let (_, rc) = e.startClient()
    check rc.lifecycle("start_module", "meter_module").code == ecNotAuthorised
    check rc.lifecycle("start_module", "nothing_module").code == ecNotAuthorised
    check rc.lifecycle("start_module", "meter_module", Opt.some("m1")).code == ecOk
    e.finish()

  test "[IMPL-DECISION G173] a caller with a call in progress in the target gets the state at once (TF-20)":
    var cfg = config()
    cfg.stopDeadline = initDuration(seconds = 30) # waiting would take this long
    let e = newEngine(cfg)
    let m = e.started(meter())
    let (_, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    gate.store(true)
    bgDone.store(false)
    var t: Thread[ptr LogosRouteHandle]
    createThread(t, background, addr h)
    check waitUntil(
      proc(): bool =
        held.load == 1
    )
    let begun = getMonoTime()
    let r = rc.lifecycle("stop_module", "meter_module", Opt.some(m.instance))
    check getMonoTime() - begun < initDuration(seconds = 5)
    check r.code == ecOk
    check LogosNSRuntimeControlStopModuleResponse.decode(r.response).tryGet.state.kind ==
      LogosNSRuntimeControlStateKind.Stopping
    check held.load == 1
    gate.store(false)
    joinThread(t)
    check bgCode.load == 0
    check waitUntil(
      proc(): bool =
        e.view(m.instance).tryGet.state == msUnloaded
    )
    h.release()
    e.finish()

  test "[IMPL-DECISION G173] a module stopping itself gets the state at once (TF-20)":
    let e = newEngine(config())
    let (c, rc) = e.startClient()
    clientDestroyGate.store(true)
    let r = rc.lifecycle("stop_module", "client_module", Opt.some(c.instance))
    check r.code == ecOk
    check LogosNSRuntimeControlStopModuleResponse.decode(r.response).tryGet.state.kind ==
      LogosNSRuntimeControlStateKind.Stopping
    clientDestroyGate.store(false)
    check waitUntil(
      proc(): bool =
        e.view(c.instance).tryGet.state == msUnloaded
    )
    e.finish()

  test "[RUN-0671] [RUN-0673] [RUN-0674] [RUN-1051] shutdown_runtime is Runtime-wide and acknowledges acceptance (l.3695-3700)":
    block:
      let e = newEngine(
        config(
          denying(
            deny(action = Opt.some(aaRuntimeControl), operation = "shutdown_runtime")
          )
        )
      )
      let (_, rc) = e.startClient()
      check rcCall(rc, "shutdown_runtime", [0xA0'u8]).code == ecNotAuthorised
      e.finish()
    let e = newEngine(config())
    let m = e.started(meter())
    let (c, rc) = e.startClient()
    let r = rcCall(rc, "shutdown_runtime", [0xA0'u8])
    check r.code == ecOk
    check r.response == @[0xA0'u8]
    e.shutdown()
    for id in [m.instance, c.instance]:
      let v = e.view(id).tryGet
      check v.state == msUnloaded
      check v.execution.intent == inRequested # shutdown preserves intent
    check e.close()
