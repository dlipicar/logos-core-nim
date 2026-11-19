## The boundary-invariance case table (Tier 4b step 4b-3, part 4b-3.4; plan
## §4.3 `test_boundary_invariance`; INTERFACE Abstract l.52-66; RUNTIME l.51-53,
## l.161, l.970): what `probe_module`'s `serve` thread does through one route
## handle (slot 0) to a kit provider, as lines of its commands
## (`tests/kit/probe_impl.nim`). `test_boundary_invariance` runs each script in
## four placements and compares every answer, delivery and completion with the
## direct run.
##
## Two lines are the runner's own, never sent to the probe: `wait-deliveries
## <n>` and `wait-done <n>` wait until the probe has noted that many. In a
## command, `{sub}` is the id the latest `subscribe` returned.

import std/strutils
import results
import logos_sdk/cbor
import logos_sdk/kit/rc_types
import logos_sdk/testing/generated/[meter_module_types, shapes_module_types]
import ./[rcaddresses, slowdown]

type Script* = object
  kit*: string ## the provider's source under `tests/kit/`
  module*: string ## its module name
  lines*: seq[string]
  deliveries*: int ## the Events the script's subscription is delivered
  completions*: int ## the asynchronous calls it completes

func hexOf*(b: openArray[byte]): string =
  for x in b:
    result.add(toHex(x, 2).toLowerAscii)

proc call(meth: string, params: openArray[byte]): string =
  "call 0 " & meth & " " & hexOf(params)

proc prepare(n: int, meth: string, params: openArray[byte], timeout = "-"): string =
  "prepare 0 " & $n & " " & meth & " " & hexOf(params) & " " & timeout

proc read(channel: uint32): seq[byte] =
  encode(MeterReadRequest(channel: channel)).tryGet

proc meterLines(): seq[string] =
  @[
    # Calls: a value, introspection, validation, an unknown method, and the
    # provider's own failure, a response outside its schema and an invalid
    # status (G172).
    call("read", read(4)),
    call("schema", [0xA0'u8]),
    call("schema", [0xA1'u8, 0x61, 0x78, 0x01]),
    call("read", encodeCbor(cborMap((cbor("channel"), cbor("x"))))),
    call("read", [0x01'u8]),
    call("nope", [0xA0'u8]),
    call("read", read(13)),
    call("read", read(14)),
    call("read", read(16)),
    # Events: a name that fails INTERFACE §1.5 (I106), an unknown event, then
    # one subscription, which sees a publication, an invocation-scoped one
    # (17) and one from a call that names its caller (21), in order; none
    # after it ends.
    "subscribe 0 meter.nope s9",
    "subscribe 0 meter.nope_event s0",
    "subscribe 0 meter.changed_event s1",
    call("read", read(15)),
    call("read", read(17)),
    call("read", read(21)),
    "wait-deliveries 3",
    "unsubscribe 0 {sub}",
    "unsubscribe 0 {sub}",
    call("read", read(15)),
    # Asynchronous calls: a value, the provider's failure, invalid params.
    prepare(1, "read", read(5)),
    "submit 1",
    "wait-done 1",
    "release-call 1",
    # A timeout that does not pass: the provider's failure answers first. Far
    # from any round trip, as it costs nothing: a hosted call under TSan on a
    # CI runner took longer than 5000 ms (2026-11-15).
    prepare(2, "read", read(13), $(60_000 * Slow)),
    "submit 2",
    "wait-done 2",
    "release-call 2",
    prepare(3, "read", [0x01'u8]),
    "submit 3",
    "wait-done 3",
    "release-call 3",
    "observe-end 0 e1",
  ]

proc meterScript*(): Script =
  ## The meter kit, answering in its own `_MODULE_dispatch`.
  Script(
    kit: "meter_impl.nim",
    module: "meter_module",
    lines: meterLines(),
    deliveries: 3,
    completions: 3,
  )

proc deferredScript*(): Script =
  ## The same, from a provider that completes through its `async_api`
  ## (INTERFACE §2.9.2).
  Script(
    kit: "deferred_adapter.nim",
    module: "meter_module",
    lines: meterLines(),
    deliveries: 3,
    completions: 3,
  )

type RemoteOutcome* = enum
  roDetail ## INVALID_PARAMS with validation detail
  roPlain ## INVALID_PARAMS without validation detail
  roDenied ## NOT_AUTHORISED
  roOk

proc remoteAddressCases*(ownRuntime: string): seq[(string, RemoteOutcome)] =
  ## [IFC-0939, IFC-0940; RUN-1152, RUN-1153; M8] `connect_remote`'s
  ## endpoint checks and the listener address of the three remote methods,
  ## each line with what it must answer in every placement.
  let other = Opt.some(OtherRuntime)
  proc connect(id: Opt[string], a: LogosNSRuntimeControlRuntimeAddress): string =
    "connect-remote " & hexOf(endpointOf(id, a))

  proc listener(a: LogosNSRuntimeControlRuntimeAddress): string =
    "rc set_remote_listener " &
      hexOf(
        encode(
          LogosNSRuntimeControlSetRemoteListenerRequest(
            listener: LogosNSRuntimeControlRemoteListenerRecord(
              address: listenerAddress(a),
              enabled: false,
              runtime_control_enabled: false,
            )
          )
        ).tryGet
      )

  proc exports(a: LogosNSRuntimeControlRuntimeAddress): string =
    "rc list_provider_exports " &
      hexOf(
        encode(
          LogosNSRuntimeControlListProviderExportsRequest(
            listener: Opt.some(listenerAddress(a))
          )
        ).tryGet
      )

  proc exportLine(a: LogosNSRuntimeControlRuntimeAddress): string =
    "rc set_provider_export " &
      hexOf(
        encode(
          LogosNSRuntimeControlSetProviderExportRequest(
            `export`: LogosNSRuntimeControlProviderExportRecord(
              enabled: true,
              listener: listenerAddress(a),
              provider:
                LogosNSRuntimeModuleProviderAddress(provider: "no_such_provider"),
            )
          )
        ).tryGet
      )

  let mismatched = [
    tlsAddress(Opt.some(RemoteQuic)),
    quicAddress(profile = Opt.some(RemoteTlsTcp)),
    quicAddress(alpn = Opt.some("h3")),
  ]
  result = @[
    ("connect-remote a0", roDetail),
    (connect(Opt.none(string), tlsAddress()), roPlain),
    (connect(other, unixAddress()), roPlain),
    (connect(other, unixAddress(Opt.some("logos.local.unix-stream"))), roPlain),
    (connect(Opt.some(ownRuntime), tlsAddress()), roPlain),
    (connect(other, tlsAddress(Opt.some(RemoteTlsTcp))), roDenied),
    (connect(other, quicAddress(Opt.some(RemoteQuic), Opt.some(RemoteQuic))), roDenied),
    ("rc set_remote_listener a0", roDetail),
    (listener(tlsAddress(Opt.some(RemoteTlsTcp))), roOk),
    (exports(tlsAddress(Opt.some(RemoteTlsTcp))), roOk),
    (exportLine(tlsAddress(Opt.some(RemoteTlsTcp))), roDenied),
  ]
  for a in mismatched:
    result.add((connect(other, a), roPlain))
    result.add((listener(a), roPlain))
    result.add((exports(a), roPlain))
    result.add((exportLine(a), roPlain))

proc remoteAddressScript*(ownRuntime: string): Script =
  ## The cases of `remoteAddressCases`, from a consumer of the meter kit.
  result = Script(kit: "meter_impl.nim", module: "meter_module")
  for (line, _) in remoteAddressCases(ownRuntime):
    result.lines.add(line)

proc reflectReq*(b: int, levels: int): seq[byte] =
  ## A valid `reflect` request whose deepest container is at `levels`, the
  ## root map being 1 (as `test_async`'s): `u` chains `levels - 2` tree maps
  ## through `left`, and the innermost one's empty `kids` is one level deeper.
  var u = cborMap((cbor("kids"), cborArray()), (cbor("tag"), cbor("leaf")))
  for _ in 1 ..< levels - 2:
    u = cborMap(
      (cbor("kids"), cborArray()), (cbor("left"), u), (cbor("tag"), cbor("leaf"))
    )
  let zero32 = cbor(newSeq[byte](32))
  encodeCbor(
    cborMap(
      (cbor("a"), cbor(7'u64)),
      (cbor("b"), cbor(int64(b))),
      (cbor("c"), cbor("")),
      (cbor("d"), zero32),
      (cbor("e"), cborArray()),
      (cbor("f"), cborArray()),
      (cbor("g"), cbor(1'u64)),
      (
        cbor("i"),
        cborMap(
          (cbor("commitment_model"), cbor("logos.commitment-model.2026-10")),
          (cbor("schema_root"), zero32),
          (cbor("hash_profile"), cbor("logos.hash-profile.2026-08.choice-index")),
          (cbor("hash_suite"), cbor("logos.hash-suite.blake3-256")),
        ),
      ),
      (cbor("j"), cborArray()),
      (cbor("l"), cbor(newSeq[byte]())),
      (cbor("m"), cbor(0'u64)),
      (cbor("n"), cbor(0'u64)),
      (cbor("o"), cbor(0'u64)),
      (cbor("p"), cbor(0'u64)),
      (cbor("r"), (if b == 2: cborArray(cbor("much too long")) else: cborArray())),
      (cbor("s"), cbor(newSeq[byte]())),
      (cbor("t"), cborArray()),
      (cbor("u"), u),
      (cbor("v"), cborMap((cbor("w"), cbor(true)))),
      (cbor("y"), cbor(@[1'u8])),
      (cbor("z"), cbor(newSeq[byte](4))),
    )
  )

proc shapesScript*(depth: int): Script =
  ## The shapes kit under `max_payload_depth` `depth` (INTERFACE §4.5.1):
  ## every C shape its typed functions carry, a value outside the schema
  ## (`b` 2: a name over 8 bytes), and requests and responses at and past the
  ## limit, synchronous and asynchronous.
  let id = encode(
    ShapesPickRequest(
      kind: ShapesPickRequestKind.Id, arm_Id: ShapesPickRequestARIdMap(id: 7)
    )
  ).tryGet
  let missing = encode(
    ShapesPickRequest(
      kind: ShapesPickRequestKind.Id, arm_Id: ShapesPickRequestARIdMap(id: 0)
    )
  ).tryGet
  let name = encode(
    ShapesPickRequest(
      kind: ShapesPickRequestKind.Name, arm_Name: ShapesPickRequestARNameMap(name: "x")
    )
  ).tryGet
  Script(
    kit: "shapes_impl.nim",
    module: "shapes_module",
    lines: @[
      call("reflect", reflectReq(1, 8)),
      call("reflect", reflectReq(2, 8)),
      call("reflect", reflectReq(13, 8)),
      call("reflect", reflectReq(14, 8)),
      call("reflect", reflectReq(15, 8)),
      call("reflect", reflectReq(1, depth)),
      call("reflect", reflectReq(1, depth + 1)),
      call("reflect", reflectReq(15, depth - 1)),
      call("reflect", reflectReq(15, depth)),
      call("pick", id),
      call("pick", missing),
      call("pick", name),
      call("ping", encode(ShapesPingRequest()).tryGet),
      call("schema", [0xA0'u8]),
      prepare(1, "reflect", reflectReq(1, depth)),
      "submit 1",
      "wait-done 1",
      "release-call 1",
      prepare(2, "reflect", reflectReq(1, depth + 1)),
      "submit 2",
      "wait-done 2",
      "release-call 2",
    ],
    deliveries: 0,
    completions: 2,
  )
