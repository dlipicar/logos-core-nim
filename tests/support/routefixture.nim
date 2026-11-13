## Included by the route, event and asynchronous-call tests
## (`tests/test_routes.nim`, `tests/test_events.nim`, `tests/test_async.nim`),
## which define `repo` and `work` first: a consumer module that keeps the
## Runtime Control binding of each initialization, so a test calls Runtime
## Control as that module; a module whose initialization waits at a gate; the
## meter kit module as provider; and request and route-handle helpers. Module
## code runs on the engine's workers, so the test modules keep their state in
## atomics. Bounds that only limit a wait scale with `Slow`.

import ./slowdown

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
  clientPublishes: Atomic[int] ## initializations given a non-null publish callback
  clientAccessState, clientCurrent: Atomic[pointer]
    ## the invocation access of the latest initialization

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
  if not input.publish.isNil:
    clientPublishes += 1
  clientAccessState.store(input.invocationAccess.state)
  clientCurrent.store(cast[pointer](input.invocationAccess.current))
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

proc clientContext(): ptr LogosInvocationContext =
  ## What `current` returns on this thread, through the consumer's access.
  let f = cast[proc(state: pointer): ptr LogosInvocationContext {.
    cdecl, gcsafe, raises: []
  .}](clientCurrent.load)
  if f.isNil:
    nil
  else:
    f(clientAccessState.load)

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

var engines = 0

when declared(caParity):
  # The parity pass (step 8b-1; DECISIONS I85): `test_routes_ca` and
  # `test_events_ca` run these cases with a Capability Authority bound, the
  # fake one allowing everything for ten minutes, instead of the internal
  # policy. A case that scripts the internal policy's denials keeps it.
  import ./fakeca

  const ParityCa = "parity-ca"

let PassingStop = initDuration(milliseconds = 300 * Slow)
  ## [IMPL] The stop deadline of a case about the deadline: one that waits for
  ## it to pass.

when declared(transportParity):
  # The local-transport parity pass (step 4b-2; DECISIONS I90): `test_routes_lt`,
  # `test_async_lt` and `test_routes_ca_lt` run these cases with the meter and
  # sensor providers routed over local transport (G254), each reached through
  # the Runtime's endpoint for it (G257). A documented difference has its own
  # `when declared(transportParity)` branch.
  import std/exitprocs
  import ../../src/logos_core/runtime/routing
  import ./shortdir

  proc removeAtExit(dir: string) =
    ## The closure keeps its own copy: the main module's globals are destroyed
    ## before exit procedures run.
    addExitProc(
      proc() =
        removeDir(dir)
    )

  let parityBase = makeShortBase("lcnlt", "/e999/12345678/logos_sensor_module.sock")
  removeAtExit(parityBase)

proc config(policy = allowAll(), extra: seq[StaticRegistration] = @[]): EngineConfig =
  inc engines
  result = defaultConfig(work / ("e" & $engines))
  result.policy = policy
  # [IMPL] Otherwise the stop deadline only bounds the stops a case waits for.
  # A stop releases through the Module Loader on a lifecycle worker, and a
  # worker's first Loader call loads that thread's contract tables (on an idle
  # Mac about 40 ms under refc and 140 ms under ASan), which a loaded CI host
  # pushed past 300 ms × `Slow` (2026-11-13).
  result.stopDeadline = initDuration(seconds = 10 * Slow)
  result.statics = @[
    checkStaticRegistration("client", clientTable()).tryGet,
    checkStaticRegistration("slow", slowTable()).tryGet,
    checkStaticRegistration("meter", meterModuleStaticSymbols()).tryGet,
  ]
  result.statics.add(extra)
  when declared(transportParity):
    result.routing = @[
      RoutingRule(callee: "meter_module", mode: rmLocalTransport),
      RoutingRule(callee: "sensor_module", mode: rmLocalTransport),
    ]
    result.endpointDir = parityBase / ("e" & $engines)
  when declared(caParity):
    result.statics.add(fakeCaRegistration())
    if policy.rules.len == 0:
      # No parity case tests the evaluation deadline: a generous one keeps a
      # sanitizer build on a loaded host from failing closed.
      result.authority = Opt.some(
        AuthorityPolicy(
          instance: ParityCa, evaluationDeadline: initDuration(seconds = 60)
        )
      )

var live: Engine ## the test's engine from `fixtureEngine` until `finish`

proc fixtureEngine(cfg: EngineConfig): Engine =
  ## A new engine, remembered so `leftover` can close it; in the parity pass,
  ## with the authority bound.
  result = newEngine(cfg)
  live = result
  when declared(caParity):
    if cfg.authority.isSome:
      resetFake()
      discard result.create(fakeCaRecord(), ParityCa).tryGet
      doAssert result.start(ParityCa).tryGet.state == msReady
      doAssert result.authorityBound()[0], "the parity authority is not bound"

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

proc waitUntil(cond: proc(): bool {.closure.}, seconds = 10 * Slow): bool =
  let until = getMonoTime() + initDuration(seconds = seconds)
  while getMonoTime() < until:
    if cond():
      return true
    sleep(2)
  cond()

let overTransport = declared(transportParity) ## the local-transport parity pass

template directOnly() =
  ## A case with no transported counterpart (plan §2.13): skipped in the
  ## local-transport parity pass, with the reason beside the call. It leaves
  ## the test body's block, so the case reports SKIPPED.
  if overTransport:
    skip()
    break

proc arrives(cond: proc(): bool {.closure.}): bool =
  ## `cond` holds once a handler has run. Direct delivery runs before publish
  ## returns, so it is checked at once. Over local transport handlers run on
  ## event workers after the Event arrives (plan §2.13, difference 5), so the
  ## parity pass waits for it first, within a bound.
  when declared(transportParity):
    waitUntil(cond)
  else:
    cond()

proc settled() =
  ## Before a check that an Event was not delivered: over local transport,
  ## time for one that should not have been sent to arrive anyway.
  when declared(transportParity):
    sleep(50 * Slow)

var stopReply: Atomic[int] ## the state `stopOn` got, or -1; -2 while it waits

proc stopOn(arg: (Engine, string)) {.thread.} =
  let r = arg[0].stop(arg[1])
  stopReply.store(
    if r.isOk:
      ord(r.get.state)
    else:
      -1
  )

proc stopping(e: Engine, instance: string, t: var Thread[(Engine, string)]): bool =
  ## Stops `instance` from `t`, with its destroy held, and waits until it is
  ## `stopping`. The engine's stop deadline must outlast the caller's checks.
  stopReply.store(-2)
  createThread(t, stopOn, (e, instance))
  waitUntil(
    proc(): bool =
      e.view(instance).tryGet.state == msStopping
  )

proc finish(e: Engine) =
  if live == e:
    live = nil
  clientDestroyGate.store(false)
  slowGate.store(false)
  gate.store(false)
  e.shutdown()
  check e.close(initDuration(seconds = 10 * Slow))

proc leftover() =
  ## [IMPL] For a suite's `teardown`: a test that ended before its `finish`,
  ## such as one whose failed wait was followed by a defect, closes its engine
  ## here. `close` joins every worker, so nothing of that engine, such as a
  ## late completion callback, reaches the next test.
  if live != nil:
    live.finish()

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

proc redacted(r: RcResult): seq[byte] =
  ## [G255] `establish_route`'s answer as a replay gives it: without each
  ## route's one-time invocation.
  var resp = r.routesOf
  for rec in resp.routes.mitems:
    rec.invocation = Opt.none(LogosNSRuntimeControlInvocationDescriptor)
  encode(resp).tryGet

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

var renewals = 0 ## the parity pass's renewals for a fresh ticket

proc rawMaterialize(
    rc: ptr LogosRuntimeControlBinding,
    route: string,
    root: Digest,
    schema: seq[byte],
    h: var LogosRouteHandle,
): LogosResult =
  var r: ContractRoot = root
  result = rc.vtable.materializeRoute(
    rc,
    cstring(route),
    addr r,
    cast[ptr UncheckedArray[uint8]](unsafeAddr schema[0]),
    csize_t(schema.len),
    addr h,
  )
  when declared(transportParity):
    # [G258; K11] A transported route's ticket opens one connection: where a
    # direct route materializes again, the parity pass renews it for a fresh
    # ticket first, as a consumer must.
    if result.code == CErrorCode(ord(ecNotAuthorised)) and result.message != nil and
        "unused ticket" in $result.message:
      inc renewals
      let n = rcCall(
        rc,
        "renew_route",
        encode(
          LogosNSRuntimeControlRenewRouteRequest(
            request_key: "parity-renewal-" & $renewals, route: route
          )
        ).tryGet,
      )
      if n.code == ecOk:
        result = rc.vtable.materializeRoute(
          rc,
          cstring(route),
          addr r,
          cast[ptr UncheckedArray[uint8]](unsafeAddr schema[0]),
          csize_t(schema.len),
          addr h,
        )

proc materialize(
    rc: ptr LogosRuntimeControlBinding,
    route: string,
    root = meterRoot,
    schema = meterSchema,
): (ErrorCode, LogosRouteHandle) =
  var h = LogosRouteHandle()
  let res = rawMaterialize(rc, route, root, schema, h)
  (toResult(res).code, h)

type Materialized = object
  code: ErrorCode
  detailNull: bool ## the status's `detail` pointer was null
  detailLen: int ## the status's `detail_len`
  handle: LogosRouteHandle

proc materializeStatus(
    rc: ptr LogosRuntimeControlBinding,
    route: string,
    root = meterRoot,
    schema = meterSchema,
): Materialized =
  ## `materialize`, with the returned status's validation detail as given.
  let res = rawMaterialize(rc, route, root, schema, result.handle)
  result.code = errorCode(int64(res.code)).get
  result.detailNull = res.detail == nil
  result.detailLen = int(res.detailLen)

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

proc readiness(
    rc: ptr LogosRuntimeControlBinding,
    module: string,
    instance = Opt.none(string),
    provider = Opt.none(LogosNSRuntimeModuleProviderAddress),
): RcResult =
  rcCall(
    rc,
    "get_readiness",
    encode(
      LogosNSRuntimeControlGetReadinessRequest(
        module: module, instance: instance, provider: provider
      )
    ).tryGet,
  )

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
