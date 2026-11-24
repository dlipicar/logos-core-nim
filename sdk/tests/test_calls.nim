## lcn-gen's typed call helpers [IMPL] (INTERFACE §2.7.2, §5.2, App A.5): a
## consumer calls the kit modules of `tests/kit` through a route handle whose
## direct binding dispatches into them (`logos_sdk/testing/testroute`). Nim callers use
## `invoke`. C callers use the helpers of the generated `<stem>_calls.h`, which
## the typed harness drives through the shims in `sdk/tests/kit/calls_shims.c`, so
## every variant of the provider tests (`sdk/tests/test_kit.nim`) runs again
## through a route. Routes that break their side of the contract show what
## the helpers reject. A route set materializes and releases handles over a
## Runtime Control binding stand-in.

import std/[strutils, typedthreads]
from std/os import sleep
import unittest2
from logos_sdk/codegen/callrt import arenaBlocks, failArenaAllocation
from logos_sdk/kit/routes import newRouteSet, materialize, close
import logos_sdk/testing/testroute
import ./support/typedharness
import
  logos_sdk/testing/generated/
    [meter_module_calls, sensor_module_calls, shapes_module_calls]
from ./generated/metrics_provider_calls import nil
from ./generated/metrics_provider_types import nil
import logos_sdk/testing/fixtures/[meter_impl, sensor_impl, shapes_impl]

{.compile("kit/calls_linked.c", "-Werror=incompatible-pointer-types").}

exportMeterModuleCalls()
exportSensorModuleCalls()
exportShapesModuleCalls()

# The modules' exported symbols, as their Runtime declares them ---------------------

template moduleSymbols(prefix: untyped, cname: static string) =
  proc `prefix Init`(
    input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
  ): LogosResult {.
    importc: "logos_" & cname & "_MODULE_init", cdecl, gcsafe, raises: []
  .}

  proc `prefix Destroy`(
    module: ptr LogosModuleContext
  ) {.importc: "logos_" & cname & "_MODULE_destroy", cdecl, gcsafe, raises: [].}

  proc `prefix Dispatch`(
    module: ptr LogosModuleContext,
    methodName: cstring,
    params: ptr UncheckedArray[uint8],
    paramsLen: csize_t,
    outResponse: ptr ptr UncheckedArray[uint8],
    outResponseLen: ptr csize_t,
  ): LogosResult {.
    importc: "logos_" & cname & "_MODULE_dispatch", cdecl, gcsafe, raises: []
  .}

  proc `prefix Free`(
    module: ptr LogosModuleContext, p: pointer
  ) {.importc: "logos_" & cname & "_MODULE_free", cdecl, gcsafe, raises: [].}

moduleSymbols(meter, "meter_module")
moduleSymbols(sensor, "sensor_module")
moduleSymbols(shapes, "shapes_module")

proc thLinkedHelpers(
  h: ptr ThHelpers
) {.importc: "th_linked_helpers", cdecl, gcsafe, raises: [].}
  ## The helpers this program defines (`sdk/tests/kit/calls_linked.c`).

let calls = block:
  var h: ThHelpers
  thLinkedHelpers(addr h)
  throughHelpers(h)

# Instances and routes -------------------------------------------------------------

type Module = enum
  meterModule
  sensorModule
  shapesModule

proc newInstance(m: Module): ptr LogosModuleContext {.gcsafe.} =
  var i = input(publish = m == meterModule)
  let r =
    case m
    of meterModule:
      meterInit(addr i, addr result)
    of sensorModule:
      sensorInit(addr i, addr result)
    of shapesModule:
      shapesInit(addr i, addr result)
  doAssert checkOutcome(r, contextShape(result)).isOk, "init failed"

proc destroy(m: Module, ctx: ptr LogosModuleContext) {.gcsafe.} =
  case m
  of meterModule:
    meterDestroy(ctx)
  of sensorModule:
    sensorDestroy(ctx)
  of shapesModule:
    shapesDestroy(ctx)

proc direct(
    m: Module, ctx: ptr LogosModuleContext, record = false
): ptr TestRoute {.gcsafe.} =
  ## A direct route to `ctx`, as a Runtime materializes one (§5.2).
  case m
  of meterModule:
    newRoute(rmDirect, ctx, meterDispatch, meterFree, record = record)
  of sensorModule:
    newRoute(rmDirect, ctx, sensorDispatch, sensorFree, record = record)
  of shapesModule:
    newRoute(rmDirect, ctx, shapesDispatch, shapesFree, record = record)

template withRoute(m: Module, name: untyped, body: untyped) =
  ## A fresh instance of `m` and a direct route to it, both released after
  ## `body`, which must leave no response buffer unreleased.
  block:
    let ctx {.inject.} = newInstance(m)
    let name = direct(m, ctx, record = true)
    body
    check not name.outstanding
    check name.counts[2] == 0 # every release named the buffer it was given
    name.dispose()
    destroy(m, ctx)

template shapesCalls(ctx: ptr LogosModuleContext): int =
  var n: int
  block:
    let s {.cursor.} = cast[Shapes](instanceOf(ctx))
    n = s.calls.load
  n

proc failureOf[T](r: Result[T, InvocationFailure]): InvocationFailure =
  if r.isOk:
    InvocationFailure(code: ecOk)
  else:
    r.error

# Tests ------------------------------------------------------------------------------

suite "ifc.calls: typed call helpers from Nim (INTERFACE §5.2, App A.5) [IMPL]":
  test "[IFC-0489] [IFC-0491] [IFC-0702] invoke encodes the request, calls the route with the bare method name and checks the response":
    withRoute(meterModule, r):
      let resp = invoke(r.routeHandle, MeterReadRequest(channel: 4))
      check resp.isOk
      check resp.get.label == "ch4" and resp.get.reading.value == 40
      check r.lastMethod == "read"
      check r.lastParams == encode(MeterReadRequest(channel: 4)).get
      check r.counts == (1, 1, 0) # one call, one release of its buffer
    withRoute(sensorModule, r):
      check invoke(r.routeHandle, SensorNSControlConfigureRequest()).isOk
        # an empty response
      check r.lastMethod == "configure"
      let snap = invoke(r.routeHandle, MetricsProviderSnapshotRequest())
        # the interface's
      check snap.isOk and snap.get.count == 1
      check r.lastMethod == "snapshot"
      check r.counts == (2, 2, 0)
    withRoute(shapesModule, r):
      let byName = invoke(
        r.routeHandle,
        ShapesPickRequest(
          kind: ShapesPickRequestKind.Name,
          arm_Name: ShapesPickRequestARNameMap(name: "nm"),
        ),
      )
      check byName.isOk and byName.get.kind == ShapesPickResponseKind.True
      check byName.get.arm_True.entry.arm_Dir.entries == @["nm", "nm"]
      check invoke(r.routeHandle, ShapesPingRequest()).isOk

  test "a standalone interface's helpers call any provider of it":
    withRoute(sensorModule, r):
      check invoke(r.routeHandle, SensorNSControlConfigureRequest()).isOk
      let snap = metrics_provider_calls.invoke(
        r.routeHandle, metrics_provider_types.MetricsProviderSnapshotRequest()
      )
      check snap.isOk and snap.get.count == 1 # the configure call above
      check r.lastMethod == "snapshot"

  test "the provider's failure comes back as it returned it":
    withRoute(meterModule, r):
      let f = invoke(r.routeHandle, MeterReadRequest(channel: 13)).failureOf
      check f.code == ecModule and f.message.get("") == "channel 13 is broken"
      check r.counts == (1, 0, 0) # a failure hands out no buffer

suite "ifc.calls: typed call helpers from C (INTERFACE §2.4, §2.7.2, App A.5) [IMPL]":
  test "the harness's Nim mirrors have its C structs' sizes":
    check harnessMatches()

  test "[IFC-0648] [IFC-0699] [IFC-0700] [IFC-0702] [IFC-0703] every C shape converts in both directions through the route":
    withRoute(shapesModule, r):
      let base = arenaBlocks()
      let full = typedReflect(calls, r.asModule, rvFull)
      check full.status.isOk and full.same and full.owned
      check full.text == fullReflect
      check r.lastMethod == "reflect"
      for v in [rvDeep, rvAbsent, rvEmpty, rvNumbers]:
        let t = typedReflect(calls, r.asModule, v)
        checkpoint $v & ": " & t.message
        check t.status.isOk and t.same and t.text.endsWith(" empty=0/0")
      check r.counts == (5, 5, 0)
      check shapesCalls(ctx) == 5
      check arenaBlocks() == base

  test "the primary's and the implemented interface's methods; an empty response's empty owner":
    withRoute(meterModule, r):
      let t = typedRead(calls, r.asModule, 4)
      check t.status.isOk and t.owned
      check t.text == "label=\"ch4\" reading=(absent,40)"
    withRoute(sensorModule, r):
      let conf = typedConfigure(calls, r.asModule, "sensor", 9)
      check conf.status.isOk and not conf.owned
      let snap = typedSnapshot(calls, r.asModule)
      check snap.status.isOk and not snap.owned and snap.text == "count=1"
    withRoute(shapesModule, r):
      let ping = typedPing(calls, r.asModule)
      check ping.status.isOk and not ping.owned

  test "[IFC-0425] a choice-valued request and response, including a schema-defined miss":
    withRoute(shapesModule, r):
      let byId = typedPick(calls, r.asModule, pvId)
      check byId.status.isOk
      check byId.text == "found=true entry=file{kind=\"file\" path=\"/id/5\"}"
      let missing = typedPick(calls, r.asModule, pvMissing)
      check missing.status.isOk and not missing.owned and missing.text == "found=false"
      let byName = typedPick(calls, r.asModule, pvName)
      check byName.text ==
        "found=true entry=dir{kind=\"dir\" path=\"/nm\" entries=[\"nm\",\"nm\"]}"

  test "an input with no CBOR value fails with INVALID_PARAMS before the route is called":
    withRoute(shapesModule, r):
      for v in [
        rvNullText, rvBadKind, rvNullList, rvBadUtf8, rvCycle, rvNullArray, rvNullBytes,
        rvNullRecursive, rvNullStruct, rvTooDeep, rvBadEntry,
      ]:
        let t = typedReflect(calls, r.asModule, v)
        checkpoint $v & ": " & t.message
        check t.code == ecInvalidParams and t.untouched
        check t.status.error.detail.isNone
      for v in [pvBadKind, pvNull]:
        let t = typedPick(calls, r.asModule, v)
        checkpoint $v & ": " & t.message
        check t.code == ecInvalidParams and t.untouched
      check r.counts == (0, 0, 0)

  test "an input outside its schema reaches the provider, whose INVALID_PARAMS comes back":
    withRoute(shapesModule, r):
      for v in [rvLongName, rvBadCode]:
        let t = typedReflect(calls, r.asModule, v)
        checkpoint $v & ": " & t.message
        check t.code == ecInvalidParams and t.untouched
        check t.status.error.detail.isSome # the provider's validation detail
      check r.counts == (2, 0, 0)
      check shapesCalls(ctx) == 0

  test "[IFC-0141] the helpers' encoders emit each required literal, whatever its C member holds":
    withRoute(shapesModule, r):
      # `a` is the literal 7; the harness sets it to 8
      let t = typedReflect(calls, r.asModule, rvWrongLiteral)
      check t.status.isOk and t.text.startsWith("a=7 ")
      # arm `id` with the `name` arm's `by` literal: still a pick by id
      let tag = typedPick(calls, r.asModule, pvWrongTag)
      check tag.status.isOk
      check tag.text == typedPick(calls, r.asModule, pvId).text
      check r.counts == (3, 3, 0)

  test "the provider's failures and its own invalid response come back as it returned them":
    withRoute(shapesModule, r):
      let fails = typedReflect(calls, r.asModule, rvFails)
      check fails.code == ecModule and fails.untouched and fails.message == "thirteen"
      let bad = typedReflect(calls, r.asModule, rvBadResponse)
      check bad.code == ecModule and bad.untouched
      check r.counts == (2, 0, 0)

  test "a null route, owner or output is refused before the route is called [IMPL]":
    withRoute(shapesModule, r):
      for v in [rvNullOutput, rvNullOwner]:
        let t = typedReflect(calls, r.asModule, v)
        check t.code == ecModule and t.untouched
      check typedPing(calls, nil).code == ecModule
      check r.counts == (0, 0, 0)

  test "[IFC-0162] [IFC-0702] an allocation failure anywhere in the outputs rolls them back; the route's buffer is still released":
    withRoute(shapesModule, r):
      let base = arenaBlocks()
      var n = 1
      while n <= 500:
        failArenaAllocation(n)
        let t = typedReflect(calls, r.asModule, rvFull)
        failArenaAllocation(0)
        if t.status.isOk:
          check t.same
          break
        checkpoint "allocation " & $n & ": " & t.message
        check t.code == ecModule and t.untouched
        check "out of memory" in t.message
        check arenaBlocks() == base
        inc n
      check n > 20 and n <= 500
      let (c, released, _) = r.counts
      check c == n and released == n
      check arenaBlocks() == base

  test "[IFC-0925] [IFC-0929] the payload depth limit, on a thread with 512 KiB of stack [IMPL]":
    withRoute(shapesModule, r):
      let base = arenaBlocks()
      let deepest = typedReflectOnStack(calls, r.asModule, rvDeepest, 512 * 1024)
      check deepest.status.isOk and deepest.same
      check deepest.text.count("left=") == 1021
      for v in [rvTooDeep, rvCycle]:
        let t = typedReflectOnStack(calls, r.asModule, v, 512 * 1024)
        check t.code == ecInvalidParams and t.untouched
        check t.status.error.detail.isNone
      check r.counts == (1, 1, 0)
      check arenaBlocks() == base

  test "[IFC-0685] [IFC-0686] [IFC-0688] [IFC-0703] decoded storage outlives the route's buffer and another call, until cleared":
    withRoute(shapesModule, r):
      let base = arenaBlocks()
      let t = typedReflectCleared(calls, r.asModule)
      check t.status.isOk and t.same
      check t.text & " empty=0/0" == fullReflect
      check arenaBlocks() == base

  test "[IFC-0701] [IFC-0704] [IFC-0705] the owner needs neither the route nor the module: it clears after both are gone":
    let ctx = newInstance(shapesModule)
    let r = direct(shapesModule, ctx)
    let base = arenaBlocks()
    var t = typedReflect(calls, r.asModule, rvFull, keep = true)
    check t.status.isOk and t.owned
    check r.counts == (1, 1, 0) # the module freed its buffer once, through the route
    r.dispose()
    destroy(shapesModule, ctx)
    check arenaBlocks() > base
    clear(t.owner)
    check arenaBlocks() == base

  test "[IFC-0706] [IFC-0707] [IFC-0708] [IFC-0709] [IFC-0710] a typed cleanup helper clears the owner and resets every output, harmlessly again":
    for which in ClearCall:
      let m =
        case which
        of ccRead: meterModule
        else: shapesModule
      withRoute(m, r):
        let base = arenaBlocks()
        let t = typedClear(calls, r.asModule, which)
        checkpoint $which & ": " & t.message
        check t.status.isOk and t.untouched and t.same and not t.owned
        check arenaBlocks() == base
        if which == ccReflect:
          check t.text & " empty=0/0" == fullReflect
        if which == ccPick:
          check "\"/nm\"" in t.text

proc both(r: ptr TestRoute): (Typed, InvocationFailure) =
  ## The same ping from C and from Nim.
  (typedPing(calls, r.asModule), invoke(r.routeHandle, ShapesPingRequest()).failureOf)

suite "ifc.calls: what a helper rejects from its route (INTERFACE §2.7.2, §5.2) [IMPL]":
  test "[IFC-0490] [IFC-0491] [IFC-0933] a result and buffer combination the route may not return is MODULE_ERROR; only a buffer handed over with LOGOS_OK is released, exactly once":
    for mode in [rmOkNull, rmOkEmpty, rmOkMessage, rmFailBuffer, rmBadCode]:
      let r = newRoute(mode, response = diag("{}"))
      let (c, n) = both(r)
      checkpoint $mode & ": " & c.message
      check c.code == ecModule and c.untouched
      check n.code == ecModule
      check "route call" in c.message
      let released = if mode in {rmOkEmpty, rmOkMessage}: 2 else: 0
      check r.counts == (2, released, 0)
      check r.outstanding == (mode == rmFailBuffer)
      r.dispose()

  test "a valid failure comes back with its code and message":
    let r = newRoute(rmFailure)
    let (c, n) = both(r)
    check c.code == ecNotAuthorised and c.message == "the route says no" and c.untouched
    check n.code == ecNotAuthorised and n.message.get("") == "the route says no"
    check r.counts == (2, 0, 0)
    r.dispose()

  test "[IFC-0491] [IFC-0702] a success whose bytes are not a response is MODULE_ERROR after the buffer is released exactly once":
    for bytes in [
      @[0xA1'u8, 0x61, 0x78, 0x18, 0x01], # {"x": 1} with a non-shortest integer
      @[0xA0'u8, 0x00], # a trailing item
      @[0xFF'u8], # not CBOR
      diag("{\"x\": 1}"), # deterministic, but not the response map
      diag("[]"),
    ]:
      let r = newRoute(rmGive, response = bytes)
      let (c, n) = both(r)
      checkpoint c.message
      check c.code == ecModule and c.untouched
      check n.code == ecModule
      check r.counts == (2, 2, 0)
      check not r.outstanding
      r.dispose()

  test "a success with a valid response is converted, its buffer released once":
    let r = newRoute(rmGive, response = diag("{}"))
    let (c, n) = both(r)
    check c.status.isOk and not c.owned
    check n.code == ecOk
    check r.counts == (2, 2, 0)
    r.dispose()
    let read = newRoute(
      rmGive, response = diag("{\"label\": \"x\", \"reading\": {\"value\": 3}}")
    )
    let t = typedRead(calls, read.asModule, 1)
    check t.status.isOk and t.text == "label=\"x\" reading=(absent,3)"
    check read.counts == (1, 1, 0)
    read.dispose()

  test "[IFC-0216] a route handle that fails its consumer's checks is never called":
    let base = newRoute(rmGive, response = diag("{}"))
    let good = base.handle.vtable[]
    var bad: LogosRouteVtable
    for (change, code) in [
      ("version", ecVersionMismatch),
      ("extent", ecVersionMismatch),
      ("call", ecModule),
      ("state", ecModule),
    ]:
      bad = good
      var h = base.handle
      case change
      of "version":
        bad.abiVersion = 4
      of "extent":
        # the version-2 extent under version 3
        bad.structSize = csize_t(offsetOf(LogosRouteVtable, observeSubscriptionEnd))
      of "call":
        bad.call = nil
      else:
        h.state = nil
      h.vtable = addr bad
      let t = typedPing(calls, cast[ptr LogosModuleContext](addr h))
      checkpoint change & ": " & t.message
      check t.code == code and t.untouched
      check invoke(addr h, ShapesPingRequest()).failureOf.code == code
    check base.counts == (0, 0, 0)
    base.dispose()

# Wrapped and materialized handles (DECISIONS G339) -------------------------------
#
# A test route under the vtable a consumer wraps: the route's own `call` and
# `release_response`, end registrations that succeed, and a `release` that notes
# what was still going on through the handle.

var
  heldRoute: ptr TestRoute ## the route whose state `wrappedVtable`'s handles carry
  wrappedVtable: LogosRouteVtable
  routeReleases: Atomic[int]
  callsAtRelease, releasesAtRelease: Atomic[int]
  outstandingAtRelease: Atomic[bool] ## a buffer the route handed over was unreleased
  operationHeld: Atomic[bool] ## `holdOperation` was admitted
  operationEnded: Atomic[bool] ## `holdOperation`'s call returned
  endedAtRelease: Atomic[bool]

proc noteRelease(route: ptr LogosRouteHandle) {.cdecl, gcsafe, raises: [].} =
  routeReleases += 1
  let r = heldRoute
  let (c, n, _) = r.counts
  callsAtRelease.store(c)
  releasesAtRelease.store(n)
  outstandingAtRelease.store(r.outstanding)
  endedAtRelease.store(operationEnded.load)

proc observeOk(
    route: ptr LogosRouteHandle, handler: LogosRouteEndHandler, userData: pointer
): LogosResult {.cdecl, gcsafe, raises: [].} =
  LogosResult()

proc observeSubscriptionsOk(
    route: ptr LogosRouteHandle, handler: LogosSubscriptionEndHandler, userData: pointer
): LogosResult {.cdecl, gcsafe, raises: [].} =
  LogosResult()

proc wrappable(r: ptr TestRoute): LogosRouteHandle =
  ## `r`'s handle under `wrappedVtable`, its release noted.
  heldRoute = r
  wrappedVtable = r.handle.vtable[]
  wrappedVtable.release = noteRelease
  wrappedVtable.observeEnd = observeOk
  wrappedVtable.observeSubscriptionEnd = observeSubscriptionsOk
  routeReleases.store(0)
  operationHeld.store(false)
  operationEnded.store(false)
  LogosRouteHandle(vtable: addr wrappedVtable, state: r.handle.state)

proc holdOperation(h: RouteHandle) {.thread.} =
  ## What a generated helper does through `h` (`beginOperation`, the call,
  ## `endOperation`), paused once admitted, while the test releases `h`.
  if h.beginOperation().isErr:
    return
  operationHeld.store(true)
  sleep(50)
  discard invoke(h.raw, MeterReadRequest(channel: 5))
  operationEnded.store(true)
  h.endOperation()

var
  materializeCalls, nullOnEntry: Atomic[int]
  materializeCode: Atomic[int32] ## what `materialize_route` returns
  handOut: LogosRouteHandle ## what a successful `materialize_route` writes

proc materializeOp(
    binding: ptr LogosRuntimeControlBinding,
    routeId: cstring,
    expectedContractRoot: ptr ContractRoot,
    schemaCbor: ptr UncheckedArray[uint8],
    schemaCborLen: csize_t,
    outRoute: ptr LogosRouteHandle,
): LogosResult {.cdecl, gcsafe, raises: [].} =
  materializeCalls += 1
  if outRoute.vtable == nil and outRoute.state == nil:
    nullOnEntry += 1
  let code = materializeCode.load
  if code != 0:
    return LogosResult(code: CErrorCode(code))
  {.cast(gcsafe).}:
    outRoute[] = handOut
  LogosResult()

var
  materializeVtable = block:
    var v = rcVtable # every other operation one the set must not call
    v.materializeRoute = materializeOp
    v
  materializeBinding =
    LogosRuntimeControlBinding(vtable: addr materializeVtable, state: addr rcState)

suite "ifc.calls: wrapped and materialized route handles (INTERFACE §5.2; DECISIONS G339) [IMPL]":
  test "[IFC-0513] a route set sets the output handle to null before each materialize_route":
    let r = newRoute(rmGive, response = diag("{}"))
    handOut = wrappable(r)
    let s = newRouteSet(addr materializeBinding).get
    var root: ContractRoot
    root[0] = 1
    materializeCode.store(int32(ord(ecNotAuthorised)))
    let refused = s.materialize("route-1", root, diag("{}"))
    check refused.isErr and refused.error.code == ecNotAuthorised
    materializeCode.store(0)
    check s.materialize("route-1", root, diag("{}")).isOk
    check s.materialize("route-2", root, diag("{}")).isOk
    check materializeCalls.load == 3
    check nullOnEntry.load == 3
    check s.close().isOk
    check routeReleases.load == 2 # the two handles it held
    check r.counts == (0, 0, 0)
    r.dispose()

  test "[IFC-0517] a wrapped handle is released after the operation in progress and after every buffer the route handed over, failures included":
    let ctx = newInstance(meterModule)
    let r = direct(meterModule, ctx)
    let h = wrapRoute(wrappable(r)).get
    check invoke(h, MeterReadRequest(channel: 4)).isOk
    check invoke(h, MeterReadRequest(channel: 13)).failureOf.code == ecModule
      # the provider's failure
    check invoke(h, MeterReadRequest(channel: 14)).failureOf.code == ecModule
      # its invalid response
    check not r.outstanding
    var t: Thread[RouteHandle]
    createThread(t, holdOperation, h)
    while not operationHeld.load:
      sleep(1)
    check h.release().isOk
    joinThread(t)
    check routeReleases.load == 1
    check endedAtRelease.load # the operation admitted first had returned
    check not outstandingAtRelease.load
    check callsAtRelease.load == 4 and r.counts[0] == 4 # none after the release
    check releasesAtRelease.load == r.counts[1] and r.counts[2] == 0
    r.dispose()
    destroy(meterModule, ctx)
    # A success whose bytes are not a response: its buffer too was released
    # before the handle.
    let bad = newRoute(rmGive, response = diag("{\"x\": 1}"))
    let b = wrapRoute(wrappable(bad)).get
    check invoke(b, MeterReadRequest(channel: 1)).failureOf.code == ecModule
    check b.release().isOk
    check routeReleases.load == 1 and not outstandingAtRelease.load
    check releasesAtRelease.load == 1 and bad.counts == (1, 1, 0)
    bad.dispose()

# Threads --------------------------------------------------------------------------

const rounds = 40

var
  sharedShapes, sharedMeter: ptr LogosModuleContext
  threadFailures: Atomic[int]

proc worker(id: int) {.thread.} =
  ## Each thread has its own routes: one handle is never used by two threads
  ## at once (§2.8).
  let shapes = direct(shapesModule, sharedShapes)
  let meter = direct(meterModule, sharedMeter)
  for i in 0 ..< rounds:
    let full = typedReflect(calls, shapes.asModule, rvFull)
    if not (full.status.isOk and full.same):
      threadFailures += 1
    let pick = typedPick(calls, shapes.asModule, pvName)
    if not pick.status.isOk or "\"/nm\"" notin pick.text:
      threadFailures += 1
    let channel = uint32(1000 + id * rounds + i)
    let r = invoke(meter.routeHandle, MeterReadRequest(channel: channel))
    if r.isErr or r.get.label != "ch" & $channel:
      threadFailures += 1
    let t = typedRead(calls, meter.asModule, channel)
    if not t.status.isOk or "\"ch" & $channel & "\"" notin t.text:
      threadFailures += 1
    # Failures keep their own message on each thread (§2.7).
    let broken = typedRead(calls, meter.asModule, 13)
    if broken.code != ecModule or broken.message != "channel 13 is broken":
      threadFailures += 1
    let local = typedReflect(calls, shapes.asModule, rvNullText)
    if local.code != ecInvalidParams or local.message != "a null text pointer":
      threadFailures += 1
  if shapes.counts != (2 * rounds, 2 * rounds, 0) or
      meter.counts != (3 * rounds, 2 * rounds, 0):
    threadFailures += 1
  shapes.dispose()
  meter.dispose()

suite "ifc.calls: helpers on several threads (INTERFACE §2.8) [IMPL]":
  test "[IFC-0260] [IFC-0265] helpers on distinct routes to shared contexts, from several threads at once":
    sharedShapes = newInstance(shapesModule)
    sharedMeter = newInstance(meterModule)
    let base = arenaBlocks()
    var threads: array[4, Thread[int]]
    for i in 0 ..< threads.len:
      createThread(threads[i], worker, i)
    joinThreads(threads)
    check threadFailures.load == 0
    check arenaBlocks() == base
    check shapesCalls(sharedShapes) == 2 * rounds * threads.len
    destroy(shapesModule, sharedShapes)
    destroy(meterModule, sharedMeter)
