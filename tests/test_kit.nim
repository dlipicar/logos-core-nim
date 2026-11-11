## lcn-gen's module kit [IMPL]: a module written in Nim (`tests/kit/`) exports
## the INTERFACE §2.6 identity, lifecycle and provider symbols, and an ABI
## caller that knows only those C symbols gets what §2.6-§2.8 promise. Every
## call goes through the exported C functions; their results are checked with
## the ABI caller's own rules (`abi/checks`).

import std/[os, osproc, strutils, typedthreads]
import unittest2
import ../src/logos_core/cbor
import ../src/logos_core/iface/[accept, provider]
from ../src/logos_core/codegen/callrt import
  arenaBlocks, failArenaAllocation, CallArena, text, release
from ../src/logos_core/codegen/common_mirrors import commonMirrorLayout
import ./support/[kitruntime, specdata, typedharness]
import ./generated/meter_module_kit
from ./generated/sensor_module_kit import sensorModuleLayout
from ./generated/shapes_module_kit import shapesModuleLayout
import ./kit/[meter_impl, sensor_impl, shapes_impl]

{.compile("kit/typed_linked.c", "-Werror=incompatible-pointer-types").}

const deviceTarget = defined(android) or defined(ios)

# The exported symbols, as an ABI caller declares them -------------------------------

proc meterName(): cstring {.
  importc: "logos_meter_module_MODULE_name", cdecl, gcsafe, raises: []
.}

proc meterInit(
  input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
): LogosResult {.importc: "logos_meter_module_MODULE_init", cdecl, gcsafe, raises: [].}

proc meterDestroy(
  module: ptr LogosModuleContext
) {.importc: "logos_meter_module_MODULE_destroy", cdecl, gcsafe, raises: [].}

proc meterCallSurface(
  outLen: ptr csize_t
): ptr uint8 {.
  importc: "logos_meter_module_MODULE_call_surface", cdecl, gcsafe, raises: []
.}

proc meterFree(
  module: ptr LogosModuleContext, p: pointer
) {.importc: "logos_meter_module_MODULE_free", cdecl, gcsafe, raises: [].}

proc meterDispatch(
  module: ptr LogosModuleContext,
  methodName: cstring,
  params: ptr UncheckedArray[uint8],
  paramsLen: csize_t,
  outResponse: ptr ptr UncheckedArray[uint8],
  outResponseLen: ptr csize_t,
): LogosResult {.
  importc: "logos_meter_module_MODULE_dispatch", cdecl, gcsafe, raises: []
.}

proc sensorInit(
  input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
): LogosResult {.importc: "logos_sensor_module_MODULE_init", cdecl, gcsafe, raises: [].}

proc sensorDestroy(
  module: ptr LogosModuleContext
) {.importc: "logos_sensor_module_MODULE_destroy", cdecl, gcsafe, raises: [].}

proc sensorDispatch(
  module: ptr LogosModuleContext,
  methodName: cstring,
  params: ptr UncheckedArray[uint8],
  paramsLen: csize_t,
  outResponse: ptr ptr UncheckedArray[uint8],
  outResponseLen: ptr csize_t,
): LogosResult {.
  importc: "logos_sensor_module_MODULE_dispatch", cdecl, gcsafe, raises: []
.}

proc sensorFree(
  module: ptr LogosModuleContext, p: pointer
) {.importc: "logos_sensor_module_MODULE_free", cdecl, gcsafe, raises: [].}

proc shapesInit(
  input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
): LogosResult {.importc: "logos_shapes_module_MODULE_init", cdecl, gcsafe, raises: [].}

proc shapesDestroy(
  module: ptr LogosModuleContext
) {.importc: "logos_shapes_module_MODULE_destroy", cdecl, gcsafe, raises: [].}

proc thLinked(f: ptr ThFns) {.importc: "th_linked", cdecl, gcsafe, raises: [].}
  ## The typed provider functions of the modules linked in, by their header
  ## names (`tests/kit/typed_linked.c`).

# Calling helpers ------------------------------------------------------------------------

proc newMeter(i: LogosModuleInitInput): ptr LogosModuleContext {.gcsafe.} =
  var i = i
  var ctx: ptr LogosModuleContext = nil
  let r = meterInit(addr i, addr ctx)
  doAssert checkOutcome(r, contextShape(ctx)).isOk, "meter init failed"
  ctx

proc newInstance(
    init: proc(
      input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
    ): LogosResult {.cdecl, gcsafe, raises: [].}
): ptr LogosModuleContext {.gcsafe.} =
  ## An instance of a module without events.
  var i = input(publish = false)
  let r = init(addr i, addr result)
  doAssert checkOutcome(r, contextShape(result)).isOk, "init failed"

proc meterCall(
    ctx: ptr LogosModuleContext, bare: string, params: openArray[byte]
): Call {.gcsafe.} =
  call(meterDispatch, meterFree, ctx, bare, params)

proc read(channel: uint32): seq[byte] =
  encode(MeterReadRequest(channel: channel)).get

proc decoded(c: Call): MeterReadResponse =
  MeterReadResponse.decode(c.response).get

template withInstance(ctx: ptr LogosModuleContext, T: typedesc, name, body: untyped) =
  ## The author's instance behind a kit context (white-box: tests only),
  ## borrowed: the kit's `GC_ref` keeps it alive.
  block:
    let name {.cursor.} = cast[T](instanceOf(ctx))
    body

# Tests ------------------------------------------------------------------------------------

suite "ifc.kit: module identity and the call surface (INTERFACE §2.6) [IMPL]":
  test "[IFC-0194] [IFC-0195] [IFC-0224] [IFC-0262] the module name is one static string":
    let a = meterName()
    check $a == "meter_module"
    check meterName() == a # the same static storage on every call
    let ctx = newMeter(input())
    check meterName() == a # an instance changes nothing
    meterDestroy(ctx)

  test "[IFC-0198] [IFC-0199] [IFC-0233] [IFC-0262] the call surface is the binding's descriptor, the same bytes every call":
    var n1, n2: csize_t
    let p1 = meterCallSurface(addr n1)
    let ctx = newMeter(input())
    let p2 = meterCallSurface(addr n2)
    meterDestroy(ctx)
    check p1 == p2 and n1 == n2 and n1 > 0
    let bytes = @(cast[ptr UncheckedArray[uint8]](p1).toOpenArray(0, int(n1) - 1))
    let b = acceptBinding(
      "meter_module", Opt.some(mirror("IFC/3.9.1.module.cddl")), [], []
    ).get
    check bytes == callSurfaceDescriptor(b).get
    let accepted = acceptCallSurfaceDescriptor(bytes, $meterName())
    check accepted.isOk

suite "ifc.kit: lifecycle (INTERFACE §2.6) [IMPL]":
  test "[IFC-0196] [IFC-0197] [IFC-0211] [IFC-0212] each initialization returns a distinct context; destroy runs the author's hook":
    let before = destroyed.load
    let a = newMeter(input())
    let b = newMeter(input())
    check a != nil and b != nil and a != b
    check instanceOf(a) != instanceOf(b)
    meterDestroy(a)
    meterDestroy(b)
    check destroyed.load == before + 2

  test "[IFC-0217] [IFC-0218] [IFC-0219] the state directory and configuration are copied, not retained":
    var dir = "/var/lib/meter"
    var config = diag("{\"rate\": 5}")
    let ctx = newMeter(input(stateDir = cstring(dir), configuration = config))
    dir[1] = 'X'
    config[0] = 0
    withInstance(ctx, Meter, m):
      check m.stateDir == Opt.some("/var/lib/meter")
      check m.configuration == Opt.some(diag("{\"rate\": 5}"))
    meterDestroy(ctx)

  test "[IFC-0222] a failed initialization returns a nonzero code and a null context":
    let refusing = @[0xF4'u8] # the author refuses CBOR `false`
    let notOneValue = @[0xFF'u8] # a break code: not one CBOR value
    # `input` borrows the configuration bytes, so they outlive each call.
    var i = input(configuration = refusing)
    var ctx = cast[ptr LogosModuleContext](addr rcState) # not null on purpose
    var r = meterInit(addr i, addr ctx)
    check ctx == nil
    let st = checkOutcome(r, contextShape(ctx))
    check st.isErr and st.error.code == ecModule
    check st.error.message == Opt.some("configuration says no")
    i = input()
    i.abiVersion = 1 # [SPEC INTERFACE §5.2] an older input
    r = meterInit(addr i, addr ctx)
    check ctx == nil and
      checkOutcome(r, contextShape(ctx)).error.code == ecVersionMismatch
    i = input()
    i.runtimeControl = nil
    r = meterInit(addr i, addr ctx)
    check ctx == nil and checkOutcome(r, contextShape(ctx)).error.code == ecModule
    i = input(configuration = notOneValue)
    r = meterInit(addr i, addr ctx)
    check ctx == nil and checkOutcome(r, contextShape(ctx)).error.code == ecInvalidParams

suite "ifc.kit: dispatch (INTERFACE §2.6, §2.7, §4.5, App A.3) [IMPL]":
  test "[IFC-0201] [IFC-0672] [IFC-0256] [IFC-0263] a call returns one response map that the instance's free releases":
    let ctx = newMeter(input())
    let c = meterCall(ctx, "read", read(4))
    check c.status.isOk
    check c.response == diag("{\"label\": \"ch4\", \"reading\": {\"value\": 40}}")
    check c.decoded.reading.value == 40
    meterFree(ctx, nil) # a no-op
    withInstance(ctx, Meter, m):
      check m.reads.load == 1
    meterDestroy(ctx)

  test "[IFC-0250] a rejected request never reaches the handler and leaves the outputs null":
    let ctx = newMeter(input())
    check meterCall(ctx, "write", read(1)).code == ecMethodNotFound
    check meterCall(ctx, "schema", diag("{}")).code == ecMethodNotFound # App A.3
    let malformed = meterCall(ctx, "read", @[0xA1'u8])
    check malformed.code == ecInvalidParams
    check malformed.status.error.detail ==
      Opt.some(invalidParamsDetail(iprMalformedCbor))
    let nondet = meterCall(
      ctx,
      "read",
      @[0xA1'u8, 0x67] & @(toOpenArrayByte("channel", 0, 6)) & @[0x18'u8, 0x04],
    )
    check nondet.code == ecInvalidParams
    check nondet.status.error.detail ==
      Opt.some(invalidParamsDetail(iprNonDeterministicCbor))
    let mismatch = meterCall(ctx, "read", diag("{\"channel\": \"four\"}"))
    check mismatch.code == ecInvalidParams
    check mismatch.status.error.detail ==
      Opt.some(invalidParamsDetail(iprSchemaMismatch, Opt.some(@[cbor("channel")])))
    check meterCall(ctx, "read", []).code == ecInvalidParams
    withInstance(ctx, Meter, m):
      check m.reads.load == 0
    meterDestroy(ctx)

  test "a handler's failure, an invalid response and an invalid failure":
    let ctx = newMeter(input())
    let failed = meterCall(ctx, "read", read(13))
    check failed.code == ecModule
    check failed.status.error.message == Opt.some("channel 13 is broken")
    let invalid = meterCall(ctx, "read", read(14)) # label outside 1..64 bytes
    check invalid.code == ecModule
    check invalid.response.len == 0
    let bogus = meterCall(ctx, "read", read(16)) # a failure with code OK
    check bogus.code == ecModule
    check bogus.status.error.message.isNone
    meterDestroy(ctx)

  test "[IFC-0206] a module with _implements dispatches its own and its interface's methods":
    var i = input(publish = false)
    var ctx: ptr LogosModuleContext = nil
    check checkOutcome(sensorInit(addr i, addr ctx), contextShape(ctx)).isOk
    let snap0 = call(sensorDispatch, sensorFree, ctx, "snapshot", diag("{}"))
    check snap0.status.isOk and snap0.response == diag("{\"count\": 0}")
    let conf = call(
      sensorDispatch,
      sensorFree,
      ctx,
      "configure",
      diag("{\"settings\": {\"kind\": \"sensor\", \"limit\": 9}}"),
    )
    check conf.status.isOk and conf.response == diag("{}")
    check call(
      sensorDispatch,
      sensorFree,
      ctx,
      "configure",
      diag("{\"settings\": {\"kind\": \"meter\", \"limit\": 9}}"),
    ).code == ecInvalidParams # the literal `kind`
    let snap1 = call(sensorDispatch, sensorFree, ctx, "snapshot", diag("{}"))
    check snap1.response == diag("{\"count\": 1}")
    withInstance(ctx, Sensor, sensor):
      check sensor.limit.load == 9
    sensorDestroy(ctx)

suite "ifc.kit: events and the invocation context (INTERFACE §2.5, §2.9.3, App A.4) [IMPL]":
  test "[IFC-0220] a typed publish helper encodes the event; a null callback is never called":
    ## A module whose call surface declares events refuses a null callback at
    ## `_MODULE_init` (`checkInitInput`), so the kit never holds one it could
    ## call; a module without events has no publish helper at all.
    withLock publishedLock:
      published.setLen(0)
    let ctx = newMeter(input())
    check meterCall(ctx, "read", read(15)).status.isOk
    withLock publishedLock:
      check published == @[("meter.changed_event", diag("{\"value\": 150}"), "plain")]
      published.setLen(0)
    meterDestroy(ctx)
    var i = input(publish = false)
    var quiet: ptr LogosModuleContext = nil
    let r = meterInit(addr i, addr quiet)
    check quiet == nil and checkOutcome(r, contextShape(quiet)).error.code == ecModule
    var si = input(publish = false)
    var sensor: ptr LogosModuleContext = nil
    check checkOutcome(sensorInit(addr si, addr sensor), contextShape(sensor)).isOk
    sensorDestroy(sensor)
    withLock publishedLock:
      check published.len == 0

  test "the caller, cancellation and scoped publication come from the current invocation":
    withLock publishedLock:
      published.setLen(0)
    let ctx = newMeter(input())
    check meterCall(ctx, "read", read(17)).code == ecNotReady # no provider entry
    var invocation =
      LogosInvocationContext(vtable: addr contextVtable, state: addr contextState)
    activeContext = addr invocation
    cancelled.store(true)
    let c = meterCall(ctx, "read", read(17))
    activeContext = nil
    cancelled.store(false)
    check c.status.isOk
    check c.decoded.label == consumerId
    check c.decoded.reading.label == Opt.some(runtimeId)
    check c.decoded.reading.value == 1 # cancelled
    withLock publishedLock:
      check published == @[("meter.changed_event", diag("{\"value\": 170}"), "scoped")]
      published.setLen(0)
    meterDestroy(ctx)

# Concurrency ---------------------------------------------------------------------------

const
  workers = 4
  rounds = 150

var
  sharedMeter: ptr LogosModuleContext
  concurrentFailures: Atomic[int]

proc worker(id: int) {.thread.} =
  ## Calls on one shared context from several threads at once (§2.8), plus the
  ## context-free symbols and an instance of the thread's own.
  let own = newMeter(input())
  for i in 0 ..< rounds:
    let channel = uint32(100 + id * rounds + i)
    let c = meterCall(sharedMeter, "read", read(channel))
    if c.status.isErr or
        MeterReadResponse.decode(c.response).get.label != "ch" & $channel:
      concurrentFailures += 1
    let f = meterCall(sharedMeter, "read", read(13))
    if f.status.isOk or f.status.error.message != Opt.some("channel 13 is broken"):
      concurrentFailures += 1
    if $meterName() != "meter_module":
      concurrentFailures += 1
    var n: csize_t
    if meterCallSurface(addr n) == nil or n == 0:
      concurrentFailures += 1
    if meterCall(own, "read", read(1)).status.isErr:
      concurrentFailures += 1
  meterDestroy(own)

suite "ifc.kit: concurrency (INTERFACE §2.7, §2.8) [IMPL]":
  test "[IFC-0259] [IFC-0265] [IFC-0266] [IFC-0267] [IFC-0268] [IFC-0269] [IFC-0271] [IFC-0272] [IFC-0273] [IFC-0274] [IFC-0286] calls on one context from several threads at once":
    sharedMeter = newMeter(input())
    var threads: array[workers, Thread[int]]
    for i in 0 ..< workers:
      createThread(threads[i], worker, i)
    joinThreads(threads)
    check concurrentFailures.load == 0
    withInstance(sharedMeter, Meter, m):
      check m.reads.load == workers * rounds * 2
    meterDestroy(sharedMeter)

# Typed provider functions ------------------------------------------------------------------

var linked: ThFns
thLinked(addr linked)

template shapesCalls(ctx: ptr LogosModuleContext): int =
  var n: int
  withInstance(ctx, Shapes, s):
    n = s.calls.load
  n

suite "ifc.kit: typed provider functions (INTERFACE §2.3, §2.4, §2.7.1) [IMPL]":
  test "the harness's Nim mirrors have its C structs' sizes":
    check harnessMatches()

  test "[IFC-0164] [IFC-0648] a typed call reads C inputs and writes complete C outputs its owner holds":
    let ctx = newMeter(input())
    let base = arenaBlocks()
    var t = typedRead(linked, ctx, 4, keep = true)
    check t.status.isOk
    check t.text == "label=\"ch4\" reading=(absent,40)"
    check t.owned and ownerValid(t.owner)
    check arenaBlocks() > base
    clear(t.owner)
    check arenaBlocks() == base
    check meterCall(ctx, "read", read(4)).decoded.label == "ch4" # the same handler
    withInstance(ctx, Meter, m):
      check m.reads.load == 2
    meterDestroy(ctx)

  test "[IFC-0162] a failure leaves the owner and every output as the caller set them":
    let ctx = newMeter(input())
    let base = arenaBlocks()
    let failed = typedRead(linked, ctx, 13)
    check failed.code == ecModule and failed.untouched
    check failed.message == "channel 13 is broken"
    let invalid = typedRead(linked, ctx, 14) # label outside 1..64 bytes
    check invalid.code == ecModule and invalid.untouched
    let bogus = typedRead(linked, ctx, 16) # a failure with code OK
    check bogus.code == ecModule and bogus.untouched
    check arenaBlocks() == base
    meterDestroy(ctx)

  test "[IFC-0045] [IFC-0141] [IFC-0650] [IFC-0689] the primary and the implemented interface's methods; an empty response's empty owner":
    let ctx = newInstance(sensorInit)
    let conf = typedConfigure(linked, ctx, "sensor", 9)
    check conf.status.isOk and not conf.owned
    let wrong = typedConfigure(linked, ctx, "meter", 9) # the literal `kind`
    check wrong.code == ecInvalidParams and wrong.untouched
    let snap = typedSnapshot(linked, ctx)
    check snap.status.isOk and not snap.owned
    check snap.text == "count=1"
    let viaDispatch = call(sensorDispatch, sensorFree, ctx, "snapshot", diag("{}"))
    check viaDispatch.response == diag("{\"count\": 1}") # one instance behind both
    withInstance(ctx, Sensor, sensor):
      check sensor.limit.load == 9
    sensorDestroy(ctx)
    let shapes = newInstance(shapesInit)
    let ping = typedPing(linked, shapes)
    check ping.status.isOk and not ping.owned
    withInstance(shapes, Shapes, s):
      check s.pings.load == 1
    shapesDestroy(shapes)

  test "[IFC-0137] [IFC-0636] [IFC-0910] every C shape converts in both directions":
    let ctx = newInstance(shapesInit)
    let base = arenaBlocks()
    let full = typedReflect(linked, ctx, rvFull)
    check full.status.isOk and full.same and full.owned
    check full.text == fullReflect
    let deep = typedReflect(linked, ctx, rvDeep)
    check deep.status.isOk and deep.same
    check deep.text.count("left=") == 99 and "g=value:true" in deep.text
    let absent = typedReflect(linked, ctx, rvAbsent)
    check absent.status.isOk and absent.same
    for part in [
      " g=[5] ", " h=absent ", " q=absent ", " u={kids=[] tag=\"leaf\"} ",
      " v=(true,absent) ",
    ]:
      check part in absent.text
    let empty = typedReflect(linked, ctx, rvEmpty)
    check empty.status.isOk and empty.same # empty outputs point to storage
    for part in [" e=[] f=[] g=[3,4] ", " r=[] s=h'' t=[] u={kids=[] "]:
      check part in empty.text
    let numbers = typedReflect(linked, ctx, rvNumbers)
    check numbers.status.isOk and numbers.same
    for part in [
      " b=-9223372036854775808 ", " g=value:18446744073709551615 ",
      " m=-128 n=0 o=4294967295 p=0 ",
    ]:
      check part in numbers.text
    for t in [full, deep, absent, empty, numbers]:
      check t.text.endsWith(" empty=0/0")
    check shapesCalls(ctx) == 5
    check arenaBlocks() == base
    shapesDestroy(ctx)

  test "[IFC-0139] [IFC-0140] [IFC-0141] [IFC-0636] an input without a canonical value is INVALID_PARAMS and never reaches the handler":
    let ctx = newInstance(shapesInit)
    for v in [
      rvNullText, rvBadKind, rvNullList, rvBadUtf8, rvLongName, rvWrongLiteral, rvCycle,
      rvNullArray, rvNullBytes, rvNullRecursive, rvBadCode, rvNullStruct, rvTooDeep,
      rvBadEntry,
    ]:
      let t = typedReflect(linked, ctx, v)
      checkpoint $v & ": " & t.message
      check t.code == ecInvalidParams and t.untouched
    for v in [pvBadKind, pvNull, pvWrongTag]:
      let t = typedPick(linked, ctx, v)
      checkpoint $v & ": " & t.message
      check t.code == ecInvalidParams and t.untouched
    check shapesCalls(ctx) == 0
    shapesDestroy(ctx)

  test "[IFC-0925] [IFC-0926] [IFC-0927] [IFC-0928] [IFC-0929] the payload depth limit holds for typed inputs, on a thread with 1 MiB of stack [IMPL]":
    ## The converters, like the dispatch codecs, recurse once per nesting
    ## level: a provider entry at the limit needs up to 1 MiB of stack (I72).
    let ctx = newInstance(shapesInit)
    let base = arenaBlocks()
    let deepest = typedReflectOnStack(linked, ctx, rvDeepest, 1 shl 20)
    check deepest.status.isOk and deepest.same
    check deepest.text.count("left=") == 1021
    for v in [rvTooDeep, rvCycle]:
      let t = typedReflectOnStack(linked, ctx, v, 1 shl 20)
      check t.code == ecInvalidParams and t.untouched
      check t.status.error.detail.isNone
    check shapesCalls(ctx) == 1
    check arenaBlocks() == base
    shapesDestroy(ctx)

  test "a handler's failure and a response outside its schema":
    let ctx = newInstance(shapesInit)
    let fails = typedReflect(linked, ctx, rvFails)
    check fails.code == ecModule and fails.untouched and fails.message == "thirteen"
    let bad = typedReflect(linked, ctx, rvBadResponse)
    check bad.code == ecModule and bad.untouched
    check shapesCalls(ctx) == 2
    shapesDestroy(ctx)

  test "a null module, owner or output is refused before the handler [IMPL]":
    let ctx = newInstance(shapesInit)
    for v in [rvNullOutput, rvNullOwner]:
      let t = typedReflect(linked, ctx, v)
      check t.code == ecModule and t.untouched
    check typedPing(linked, nil).code == ecModule
    check shapesCalls(ctx) == 0
    withInstance(ctx, Shapes, s):
      check s.pings.load == 0
    shapesDestroy(ctx)

  test "[IFC-0425] a choice-valued request and response, including a schema-defined miss":
    let ctx = newInstance(shapesInit)
    let byId = typedPick(linked, ctx, pvId)
    check byId.status.isOk and byId.owned
    check byId.text == "found=true entry=file{kind=\"file\" path=\"/id/5\"}"
    let missing = typedPick(linked, ctx, pvMissing)
    check missing.status.isOk and not missing.owned
    check missing.text == "found=false"
    let byName = typedPick(linked, ctx, pvName)
    check byName.status.isOk
    check byName.text ==
      "found=true entry=dir{kind=\"dir\" path=\"/nm\" entries=[\"nm\",\"nm\"]}"
    shapesDestroy(ctx)

  test "[IFC-0162] an allocation failure anywhere in the response rolls it back":
    let ctx = newInstance(shapesInit)
    let base = arenaBlocks()
    var n = 1
    while n <= 500:
      failArenaAllocation(n)
      let t = typedReflect(linked, ctx, rvFull)
      failArenaAllocation(0)
      if t.status.isOk:
        check t.same
        break
      checkpoint "allocation " & $n & ": " & t.message
      check t.code == ecModule and t.untouched
      check "out of memory" in t.message
      check arenaBlocks() == base
      inc n
    check n > 20 and n <= 500 # every allocation of a full response failed once
    check arenaBlocks() == base
    shapesDestroy(ctx)

  test "a text with U+0000 has no canonical C value":
    var a: CallArena
    check a.text("a\0b").isErr
    check a.text("ab").isOk
    a.release()

  test "[IFC-0685] [IFC-0686] [IFC-0688] [IFC-0692] the owner keeps the response readable until cleared and frees only its own storage":
    let ctx = newInstance(shapesInit)
    let base = arenaBlocks()
    let t = typedReflectCleared(linked, ctx)
    check t.status.isOk and t.same
    check t.text & " empty=0/0" == fullReflect
    check arenaBlocks() == base
    shapesDestroy(ctx)

  test "[IFC-0694] distinct owners are released concurrently on threads other than the call's":
    const owners = 40
    let ctx = newInstance(shapesInit)
    let base = arenaBlocks()
    var held = newSeq[LogosResponseOwner](owners)
    for i in 0 ..< owners:
      let t =
        typedReflect(linked, ctx, if i mod 2 == 0: rvFull else: rvDeep, keep = true)
      check t.status.isOk
      held[i] = t.owner
    check arenaBlocks() > base

    proc releaser(args: (ptr UncheckedArray[LogosResponseOwner], int)) {.thread.} =
      for i in 0 ..< 10:
        clear(args[0][args[1] * 10 + i])

    var threads:
      array[owners div 10, Thread[(ptr UncheckedArray[LogosResponseOwner], int)]]
    let all = cast[ptr UncheckedArray[LogosResponseOwner]](addr held[0])
    for k in 0 ..< threads.len:
      createThread(threads[k], releaser, (all, k))
    joinThreads(threads)
    check arenaBlocks() == base
    shapesDestroy(ctx)

const typedRounds = 60

var
  sharedShapes: ptr LogosModuleContext
  typedFailures: Atomic[int]

proc typedWorker(id: int) {.thread.} =
  for i in 0 ..< typedRounds:
    let full = typedReflect(linked, sharedShapes, rvFull)
    if not (full.status.isOk and full.same):
      typedFailures += 1
    let pick = typedPick(linked, sharedShapes, pvName)
    if not pick.status.isOk or "\"/nm\"" notin pick.text:
      typedFailures += 1
    let bad = typedReflect(linked, sharedShapes, rvNullText)
    if bad.code != ecInvalidParams or not bad.untouched:
      typedFailures += 1
    let channel = uint32(1000 + id * typedRounds + i)
    let r = typedRead(linked, sharedMeter, channel)
    if not r.status.isOk or
        r.text != "label=\"ch" & $channel & "\" reading=(absent," & $(channel * 10) & ")":
      typedFailures += 1

suite "ifc.kit: typed calls on shared contexts (INTERFACE §2.7.1, §2.8) [IMPL]":
  test "[IFC-0265] [IFC-0694] typed calls on one context from several threads at once":
    sharedShapes = newInstance(shapesInit)
    sharedMeter = newMeter(input())
    let base = arenaBlocks()
    var threads: array[workers, Thread[int]]
    for i in 0 ..< workers:
      createThread(threads[i], typedWorker, i)
    joinThreads(threads)
    check typedFailures.load == 0
    check arenaBlocks() == base
    check shapesCalls(sharedShapes) == workers * typedRounds * 2
    shapesDestroy(sharedShapes)
    meterDestroy(sharedMeter)

# Layout --------------------------------------------------------------------------------------

proc cCompiler(): string =
  result = getEnv("CC")
  for name in ["cc", "gcc", "clang"]:
    if result.len == 0:
      result = findExe(name)

proc cExpr(key: string): string =
  ## A layout fact's key (`T`, `T@align`, `T.m`, `T.m@size`) as a C expression.
  if key.endsWith("@align"):
    return "_Alignof(" & key[0 ..^ 7] & ")"
  let dot = key.find('.')
  if dot < 0:
    return "sizeof(" & key & ")"
  let (t, m) = (key[0 ..< dot], key[dot + 1 .. ^1])
  if m.endsWith("@size"):
    "sizeof(((" & t & "*)0)->" & m[0 ..^ 6] & ")"
  else:
    "offsetof(" & t & ", " & m & ")"

proc cFacts(facts: seq[(string, int)]): Result[seq[string], string] =
  ## Each fact as the C compiler computes it from the generated headers.
  let cc = cCompiler()
  if cc.len == 0:
    return err("no C compiler on PATH")
  let dir = "build" / "kit-layout"
  createDir(dir)
  var src =
    "#include <stdio.h>\n#include <stddef.h>\n" &
    "#include \"meter_module_types.h\"\n#include \"sensor_module_types.h\"\n" &
    "#include \"shapes_module_types.h\"\nint main(void) {\n"
  for (key, _) in facts:
    src.add "  printf(\"" & key & " %zu\\n\", (size_t)" & cExpr(key) & ");\n"
  src.add "  return 0;\n}\n"
  let base = dir / "layout"
  writeFile(base & ".c", src)
  let exe = base & (when defined(windows): ".exe" else: "")
  let generated = currentSourcePath().parentDir / "generated"
  let (o, rc) = execCmdEx(
    quoteShell(cc) & " -std=c17 -Wall -Werror -I " & quoteShell(generated) & " " &
      quoteShell(base & ".c") & " -o " & quoteShell(exe)
  )
  if rc != 0:
    return err(o)
  let (run, rc2) = execCmdEx(quoteShell(exe))
  if rc2 != 0:
    return err(run)
  ok(run.strip.splitLines)

suite "ifc.kit: the converters' C layout (INTERFACE §2.3) [IMPL]":
  test "[IFC-0934] every mirror's size, alignment and member offsets match the generated headers":
    let facts =
      commonMirrorLayout() & meterModuleLayout() & sensorModuleLayout() &
      shapesModuleLayout()
    check facts.len > 100
    when deviceTarget:
      skip()
    else:
      let got = cFacts(facts)
      if got.isErr:
        checkpoint got.error
        fail()
      else:
        check got.get.len == facts.len
        for i, (key, n) in facts:
          if i < got.get.len and got.get[i] != key & " " & $n:
            checkpoint "C: " & got.get[i] & "  Nim: " & key & " " & $n
            fail()
