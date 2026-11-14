## The carrier between the Runtime and a Module Host (`runtime/carrier.nim`;
## Tier 4b step 4b-3, DECISIONS G266; plan §2.4) [IMPL]: every message kind
## round-trips byte for byte with every optional field present and absent; a
## body that is not one message, an unknown kind or field, and a frame over
## the carrier's limit are refused; frames split at any byte boundary are
## reassembled. Portable: no socket is involved.

import std/sequtils
import unittest2
import results
import ../src/logos_core/abi/checks
import ../src/logos_core/cbor
import ../src/logos_core/iface/outcome
import ../src/logos_core/runtime/carrier

func failure(): LcnCarrierFailure =
  LcnCarrierFailure(
    code: uint8(ord(ecModule)),
    message: Opt.some("the module refused"),
    detail: Opt.some(@[0xA0'u8]),
    reason: Opt.some("an invalid status"),
  )

proc samples(): seq[LcnCarrierMessage] =
  ## Each kind twice: every optional field absent, then present.
  type
    C = LcnCarrierInitFailedCodeChoiceKind
    P = LcnCarrierInitFailedPhaseChoiceKind

  let root = newSeq[byte](32)
  @[
    toMessage(
      LcnCarrierInit(
        id: 1, module: "probe_module", artifact_path: "/w/a.so", max_payload_depth: 64
      )
    ),
    toMessage(
      LcnCarrierInit(
        id: 2,
        module: "probe_module",
        artifact_path: "/w/a.so",
        state_dir: Opt.some("/w/state/p"),
        configuration: Opt.some(@[0xA1'u8, 0x61, 0x61, 0x01]),
        live: true,
        max_payload_depth: high(uint64),
      )
    ),
    toMessage(LcnCarrierApply(id: 3, configuration: @[0xA0'u8])),
    toMessage(LcnCarrierRelease(id: 4)),
    toMessage(LcnCarrierInitialized(id: 5)),
    toMessage(LcnCarrierInitialized(id: 6, call_surface: Opt.some(@[1'u8, 2, 3]))),
    toMessage(
      LcnCarrierInitFailed(
        id: 7,
        code: LcnCarrierInitFailedCodeChoice(kind: C.Abi_invalid),
        message: "no _MODULE_init",
        phase: LcnCarrierInitFailedPhaseChoice(kind: P.Bind),
      )
    ),
    toMessage(
      LcnCarrierInitFailed(
        id: 8,
        code: LcnCarrierInitFailedCodeChoice(kind: C.Realization_failed),
        message: "",
        phase: LcnCarrierInitFailedPhaseChoice(kind: P.Init),
        cause: Opt.some(failure()),
      )
    ),
    toMessage(LcnCarrierApplied(id: 9)),
    toMessage(LcnCarrierApplied(id: 10, failure: Opt.some(failure()))),
    toMessage(LcnCarrierReleased(id: 11)),
    toMessage(LcnCarrierFatal(message: "the lifecycle thread cannot start")),
    toMessage(
      LcnCarrierRcCall(
        id: 12, `method`: @[0x67'u8], params: @[0xA0'u8], runtime_thread: true
      )
    ),
    toMessage(LcnCarrierRcSubscribe(id: 13, event: @[0x65'u8], local: 1)),
    toMessage(LcnCarrierRcUnsubscribe(id: 14, sub: 3)),
    toMessage(LcnCarrierRcUnsubscribe(id: 15, sub: 3, in_handler: Opt.some(1'u64))),
    toMessage(LcnCarrierRcDelivered(local: 1, seq: 2)),
    toMessage(
      LcnCarrierRcConnectRemote(id: 16, endpoint: @[0xA0'u8], expected_root: root)
    ),
    toMessage(LcnCarrierRcPublish(id: 17, event: @[0x65'u8], data: @[])),
    toMessage(LcnCarrierRcPrepare(id: 18, call: 1, `method`: @[0x67'u8], params: @[])),
    toMessage(
      LcnCarrierRcPrepare(
        id: 19,
        call: 2,
        `method`: @[0x67'u8],
        params: @[0xA0'u8],
        timeout_ms: Opt.some(5000'u64),
      )
    ),
    toMessage(LcnCarrierRcAsyncSubmit(call: 1)),
    toMessage(LcnCarrierRcAsyncCancel(call: 1)),
    toMessage(LcnCarrierRcAsyncRelease(id: 20, call: 1)),
    toMessage(LcnCarrierRcReply(id: 21)),
    toMessage(
      LcnCarrierRcReply(
        id: 22,
        value: Opt.some(@[0xA0'u8]),
        sub: Opt.some(4'u64),
        failure: Opt.some(failure()),
      )
    ),
    toMessage(
      LcnCarrierRcDelivery(
        local: 1,
        seq: 1,
        name: "logos.runtime_control.inventory_changed_event",
        data: @[],
      )
    ),
    toMessage(LcnCarrierAsyncDone(call: 1)),
    toMessage(
      LcnCarrierAsyncDone(
        call: 2, value: Opt.some(@[0xA0'u8]), failure: Opt.some(failure())
      )
    ),
  ]

proc bodyOf(m: LcnCarrierMessage): seq[byte] =
  let f = frameOf(m).tryGet
  f[4 ..^ 1]

suite "run.carrier: messages and frames (plan §2.4) [IMPL]":
  test "[IMPL] every message kind round-trips byte for byte":
    var kinds: set[LcnCarrierMessageKind]
    for m in samples():
      kinds.incl(m.kind)
      let body = bodyOf(m)
      let back = decodeMessage(body)
      check back.isOk
      if back.isOk:
        check back.get.kind == m.kind
        check bodyOf(back.get) == body
    check kinds == {low(LcnCarrierMessageKind) .. high(LcnCarrierMessageKind)}

  test "[IMPL] a body that is not exactly one message is refused":
    let body = bodyOf(toMessage(LcnCarrierRelease(id: 1)))
    check decodeMessage(body & @[0x00'u8]).isErr # a second item
    check decodeMessage(body[0 ..^ 2]).isErr # cut short
    check decodeMessage(@[]).isErr
    check decodeMessage(encodeCbor(cborMap((cbor("kind"), cbor("restart"))))).isErr
    var extra = decodeCbor(body).tryGet
    extra.entries.add((cbor("consumer"), cbor("someone-else")))
    check decodeMessage(encodeCbor(extra)).isErr # no message names a consumer
    # A required field missing, and a value outside its bound.
    check decodeMessage(encodeCbor(cborMap((cbor("kind"), cbor("release"))))).isErr
    let fatal = toMessage(LcnCarrierFatal(message: newString(513)))
    check frameOf(fatal).isErr

  test "[IMPL] frames split at any byte are reassembled; one over the limit fails the reader":
    var stream: seq[byte]
    let all = samples()
    for m in all:
      stream.add(frameOf(m).tryGet)
    var r = newCarrierReader()
    var got: seq[seq[byte]]
    for b in stream:
      let more = r.feed([b])
      check more.isOk
      if more.isOk:
        got.add(more.get)
    check got == all.mapIt(bodyOf(it))
    check r.buffered == 0
    var over = newCarrierReader()
    let prefix = prefixOf(int(CarrierFrameLimit) + 1)
    let refused = over.feed(prefix)
    check refused.isErr
    if refused.isErr:
      check refused.error.declared == uint64(CarrierFrameLimit) + 1
    check over.failed

  test "[IMPL] the largest frame fits an 8 MiB call surface or configuration (LOADER l.441)":
    let big = toMessage(
      LcnCarrierInitialized(
        id: 1, call_surface: Opt.some(newSeq[byte](8 * 1024 * 1024))
      )
    )
    check frameOf(big).isOk
    let tooBig = toMessage(
      LcnCarrierApply(id: 1, configuration: newSeq[byte](int(CarrierFrameLimit)))
    )
    check frameOf(tooBig).isErr

  test "[IMPL] a failure keeps code, message and detail; an out-of-range code reads as MODULE_ERROR":
    let f = failure()
    let a = toAbi(f)
    check a.code == ecModule and a.message == f.message and a.detail == f.detail
    check a.reason == "an invalid status"
    check toCarrier(a) == f
    check toAbi(LcnCarrierFailure(code: 0)).code == ecModule
    check toAbi(LcnCarrierFailure(code: 250)).code == ecModule
    check toInvocation(LcnCarrierFailure(code: uint8(ord(ecNotReady)))).code ==
      ecNotReady
