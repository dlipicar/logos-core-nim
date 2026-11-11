## Typed provider calls (INTERFACE §2.4, §2.7.1) made from C: the harness in
## `tests/kit/typed_harness.c` builds each call's inputs in C, calls the
## provider function it is given, and reports what a C caller sees. This module
## mirrors its two structs and turns a report into the ABI caller's verdict
## (`abi/checks`). `tests/test_kit.nim` passes the functions it links,
## `tests/test_kit_dylib.nim` the ones `dlsym` finds.

{.compile: "../kit/typed_harness.c".}

import results
import ../../src/logos_core/abi/[checks, types]
import ../../src/logos_core/iface/outcome

export checks, types, outcome

const thText = 32768

type
  ThFns* = object ## `th_fns_t`: the provider functions under test.
    meterRead*, sensorConfigure*, sensorSnapshot*: pointer
    shapesReflect*, shapesPick*, shapesPing*: pointer

  ThReport = object ## `th_report_t`
    result: LogosResult
    owner: LogosResponseOwner
    untouched, complete, same: cint
    text: array[thText, char]

  Typed* = object ## One typed call as its C caller saw it.
    status*: AbiCheck ## the result and outputs, read together (§2.4)
    untouched*: bool ## the owner and every output object still all zero
    same*: bool ## reflect: the outputs read back as the inputs
    owned*: bool ## the call returned a nonempty owner
    owner*: LogosResponseOwner ## with `keep`: the owner, still to be cleared
    text*: string ## the outputs, on success

  ReflectVariant* = enum
    ## The variants of `th_shapes_reflect`, in `typed_harness.h` order.
    rvFull
    rvNullText
    rvBadKind
    rvNullList
    rvBadUtf8
    rvLongName
    rvWrongLiteral
    rvCycle
    rvFails
    rvBadResponse
    rvDeep
    rvNullArray
    rvNullBytes
    rvAbsent
    rvEmpty
    rvNullRecursive
    rvBadCode
    rvNullOutput
    rvNullStruct
    rvTooDeep
    rvNullOwner
    rvNumbers
    rvDeepest
    rvBadEntry

  PickVariant* = enum
    ## The variants of `th_shapes_pick`, in `typed_harness.h` order.
    pvId
    pvMissing
    pvName
    pvBadKind
    pvNull
    pvWrongTag

{.push cdecl, gcsafe, raises: [].}

proc thSizes(fns, report, text: ptr csize_t) {.importc: "th_sizes".}
proc thMeterRead(
  f: ptr ThFns, m: ptr LogosModuleContext, channel: uint32, rep: ptr ThReport
) {.importc: "th_meter_read".}

proc thSensorConfigure(
  f: ptr ThFns,
  m: ptr LogosModuleContext,
  kind: cstring,
  limit: uint64,
  rep: ptr ThReport,
) {.importc: "th_sensor_configure".}

proc thSensorSnapshot(
  f: ptr ThFns, m: ptr LogosModuleContext, rep: ptr ThReport
) {.importc: "th_sensor_snapshot".}

proc thShapesReflect(
  f: ptr ThFns, m: ptr LogosModuleContext, variant: cint, rep: ptr ThReport
) {.importc: "th_shapes_reflect".}

proc thShapesReflectOnStack(
  f: ptr ThFns,
  m: ptr LogosModuleContext,
  variant: cint,
  stack: csize_t,
  rep: ptr ThReport,
): cint {.importc: "th_shapes_reflect_on_stack".}

proc thShapesReflectCleared(
  f: ptr ThFns, m: ptr LogosModuleContext, rep: ptr ThReport
) {.importc: "th_shapes_reflect_cleared".}

proc thShapesPick(
  f: ptr ThFns, m: ptr LogosModuleContext, variant: cint, rep: ptr ThReport
) {.importc: "th_shapes_pick".}

proc thShapesPing(
  f: ptr ThFns, m: ptr LogosModuleContext, rep: ptr ThReport
) {.importc: "th_shapes_ping".}

{.pop.}

proc harnessMatches*(): bool =
  ## The Nim mirrors have the C structs' sizes.
  var fns, report, text: csize_t
  thSizes(addr fns, addr report, addr text)
  int(fns) == sizeof(ThFns) and int(report) == sizeof(ThReport) and
    int(text) == offsetOf(ThReport, text)

proc clear*(owner: var LogosResponseOwner) {.gcsafe, raises: [].} =
  ## `logos_response_owner_clear` (INTERFACE §2.7.1): empty the owner first,
  ## then release what it held.
  let previous = owner
  owner = LogosResponseOwner()
  if not previous.release.isNil:
    previous.release(previous.state)

template run(keep: bool, body: untyped): Typed =
  ## Runs `body` with `rep` (a heap `ThReport`) and reads the report. Without
  ## `keep` the owner is cleared once its outputs have been read.
  let rep {.inject.} = cast[ptr ThReport](allocShared0(sizeof(ThReport)))
  body
  var t = Typed(
    status: checkOutcome(
      rep.result, typedShape(rep.owner, rep.untouched != 0, rep.complete != 0)
    ),
    untouched: rep.untouched != 0,
    same: rep.same != 0,
    owned: not ownerEmpty(rep.owner),
    owner: rep.owner,
    text: $cast[cstring](addr rep.text[0]),
  )
  deallocShared(rep)
  if not keep:
    clear(t.owner)
  t

proc typedRead*(
    f: ThFns, m: ptr LogosModuleContext, channel: uint32, keep = false
): Typed {.gcsafe.} =
  var f = f
  run(keep):
    thMeterRead(addr f, m, channel, rep)

proc typedConfigure*(
    f: ThFns, m: ptr LogosModuleContext, kind: string, limit: uint64
): Typed {.gcsafe.} =
  var f = f
  run(false):
    thSensorConfigure(addr f, m, cstring(kind), limit, rep)

proc typedSnapshot*(f: ThFns, m: ptr LogosModuleContext): Typed {.gcsafe.} =
  var f = f
  run(false):
    thSensorSnapshot(addr f, m, rep)

proc typedReflect*(
    f: ThFns, m: ptr LogosModuleContext, v: ReflectVariant, keep = false
): Typed {.gcsafe.} =
  var f = f
  run(keep):
    thShapesReflect(addr f, m, cint(ord(v)), rep)

proc typedReflectOnStack*(
    f: ThFns, m: ptr LogosModuleContext, v: ReflectVariant, stack: int
): Typed {.gcsafe.} =
  ## `typedReflect` on a new C thread with exactly `stack` bytes of stack.
  var f = f
  run(false):
    doAssert thShapesReflectOnStack(addr f, m, cint(ord(v)), csize_t(stack), rep) == 0,
      "could not start a thread"

proc typedReflectCleared*(f: ThFns, m: ptr LogosModuleContext): Typed {.gcsafe.} =
  ## A full reflect whose outputs are read again after another call, then
  ## cleared with `logos_response_owner_clear` in C: `same` says the outputs
  ## stayed readable and unchanged and the caller's objects survived clearing.
  var f = f
  run(false):
    thShapesReflectCleared(addr f, m, rep)

proc typedPick*(
    f: ThFns, m: ptr LogosModuleContext, v: PickVariant, keep = false
): Typed {.gcsafe.} =
  var f = f
  run(keep):
    thShapesPick(addr f, m, cint(ord(v)), rep)

proc typedPing*(f: ThFns, m: ptr LogosModuleContext): Typed {.gcsafe.} =
  var f = f
  run(false):
    thShapesPing(addr f, m, rep)

proc code*(t: Typed): ErrorCode =
  if t.status.isOk: ecOk else: t.status.error.code

proc message*(t: Typed): string =
  if t.status.isOk:
    ""
  else:
    t.status.error.message.get("")
