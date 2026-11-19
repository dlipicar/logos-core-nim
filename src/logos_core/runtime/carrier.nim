## The carrier between the Runtime and one Module Host (Tier 4b step 4b-3;
## DECISIONS G266; plan §2.4, K3) [IMPL]: one connected `AF_UNIX` stream
## socket pair per hosted attempt, made by the Runtime. Both sides use this
## module.
##
## - **Frames.** A 4-byte big-endian length, then one Logos deterministic-CBOR
##   `lcn.carrier_message` (`carrier.cddl`, codecs in `carrier_types.nim`).
##   The body limit is the Transport floor plus 64 KiB, so an 8 MiB call
##   surface or configuration input fits (LOADER l.441). A frame over it, one
##   that does not decode, or one a side does not expect is terminal carrier
##   loss (RUNTIME RUN-0812): the reader closes, the Runtime ends the host.
## - **Writes.** Every writer holds the carrier's write lock for one whole
##   frame. The socket is non-blocking; a writer waits for room in short
##   `poll` steps and asks `alive` between them, so a writer never outlives
##   the host it writes to.
## - **Lanes.** A message's `kind` fixes its lane (the schema's comment); a
##   message names no consumer, instance or ticket (RUN-0171, RUN-0172).
##
## On Windows only the messages and their codec are built (no host runs
## there; plan §2.1): writing and reading a carrier are POSIX.
##
## Generated case objects never cross threads here: Nim 2.2.14's `=wasMoved`
## (`runtime/plumbing.nim` `MsgKind`) would corrupt one whose first kind has
## fields. Threads hand each other frame bytes and decode their own copy.

{.push raises: [], gcsafe.}

import std/locks
import results
import logos_sdk/abi/checks
import logos_sdk/iface/outcome
import ../transport/framing
import ./carrier_types

when defined(posix):
  import std/posix
  import ../transport/io/sock

export carrier_types, framing

const
  CarrierFrameLimit* = uint32(MinFrameLimit + 64 * 1024)
    ## [IMPL; plan §2.4] the largest frame body either side accepts
  WriteStepMs = 50 ## [IMPL] how long a writer waits for room before it asks `alive`

type
  CarrierWriter* = object ## One side's end, shared by every thread that writes to it.
    fd*: cint
    lock: Lock

  AliveFn* = proc(ctx: pointer): bool {.nimcall, gcsafe, raises: [].}
    ## whether the other side may still read: false ends a wait for room

proc initWriter*(w: var CarrierWriter, fd: cint) =
  w.fd = fd
  initLock(w.lock)

proc deinitWriter*(w: var CarrierWriter) =
  deinitLock(w.lock)

proc newCarrierReader*(): FrameReader =
  newFrameReader(CarrierFrameLimit).expect("the carrier limit is over the floor")

# Messages ------------------------------------------------------------------------------

template arm(T: typedesc, k, field: untyped) =
  func toMessage*(x: sink T): LcnCarrierMessage =
    LcnCarrierMessage(kind: LcnCarrierMessageKind.k, field: x)

arm(LcnCarrierInit, lcn_Carrier_init, arm_lcn_Carrier_init)
arm(LcnCarrierApply, lcn_Carrier_apply, arm_lcn_Carrier_apply)
arm(LcnCarrierRelease, lcn_Carrier_release, arm_lcn_Carrier_release)
arm(LcnCarrierInitialized, lcn_Carrier_initialized, arm_lcn_Carrier_initialized)
arm(LcnCarrierInitFailed, lcn_Carrier_init_failed, arm_lcn_Carrier_init_failed)
arm(LcnCarrierApplied, lcn_Carrier_applied, arm_lcn_Carrier_applied)
arm(LcnCarrierReleased, lcn_Carrier_released, arm_lcn_Carrier_released)
arm(LcnCarrierFatal, lcn_Carrier_fatal, arm_lcn_Carrier_fatal)
arm(LcnCarrierRcCall, lcn_Carrier_rc_call, arm_lcn_Carrier_rc_call)
arm(LcnCarrierRcSubscribe, lcn_Carrier_rc_subscribe, arm_lcn_Carrier_rc_subscribe)
arm(LcnCarrierRcUnsubscribe, lcn_Carrier_rc_unsubscribe, arm_lcn_Carrier_rc_unsubscribe)
arm(LcnCarrierRcDelivered, lcn_Carrier_rc_delivered, arm_lcn_Carrier_rc_delivered)
arm(
  LcnCarrierRcConnectRemote, lcn_Carrier_rc_connect_remote,
  arm_lcn_Carrier_rc_connect_remote,
)
arm(LcnCarrierRcPublish, lcn_Carrier_rc_publish, arm_lcn_Carrier_rc_publish)
arm(LcnCarrierRcDeliver, lcn_Carrier_rc_deliver, arm_lcn_Carrier_rc_deliver)
arm(LcnCarrierRcPrepare, lcn_Carrier_rc_prepare, arm_lcn_Carrier_rc_prepare)
arm(
  LcnCarrierRcAsyncSubmit, lcn_Carrier_rc_async_submit, arm_lcn_Carrier_rc_async_submit
)
arm(
  LcnCarrierRcAsyncCancel, lcn_Carrier_rc_async_cancel, arm_lcn_Carrier_rc_async_cancel
)
arm(
  LcnCarrierRcAsyncRelease, lcn_Carrier_rc_async_release,
  arm_lcn_Carrier_rc_async_release,
)
arm(LcnCarrierRcReply, lcn_Carrier_rc_reply, arm_lcn_Carrier_rc_reply)
arm(LcnCarrierRcDelivery, lcn_Carrier_rc_delivery, arm_lcn_Carrier_rc_delivery)
arm(LcnCarrierAsyncDone, lcn_Carrier_async_done, arm_lcn_Carrier_async_done)

# Lane 1 (4b-3.3): a hosted consumer's route handles.
arm(LcnCarrierRcMaterialize, lcn_Carrier_rc_materialize, arm_lcn_Carrier_rc_materialize)
arm(LcnCarrierRcLinkResult, lcn_Carrier_rc_link_result, arm_lcn_Carrier_rc_link_result)
arm(LcnCarrierRcLinkAdmit, lcn_Carrier_rc_link_admit, arm_lcn_Carrier_rc_link_admit)
arm(LcnCarrierRcLinkClosed, lcn_Carrier_rc_link_closed, arm_lcn_Carrier_rc_link_closed)
arm(
  LcnCarrierRcLinkReleased, lcn_Carrier_rc_link_released,
  arm_lcn_Carrier_rc_link_released,
)
arm(LcnCarrierRouteEnded, lcn_Carrier_route_ended, arm_lcn_Carrier_route_ended)

# Lane 2 (4b-3.2): a hosted provider's endpoint and its calls.
arm(LcnCarrierAdmitVerdict, lcn_Carrier_admit_verdict, arm_lcn_Carrier_admit_verdict)
arm(LcnCarrierCallCancel, lcn_Carrier_call_cancel, arm_lcn_Carrier_call_cancel)
arm(LcnCarrierCallEnded, lcn_Carrier_call_ended, arm_lcn_Carrier_call_ended)
arm(
  LcnCarrierIoAdmitEstablished, lcn_Carrier_io_admit_established,
  arm_lcn_Carrier_io_admit_established,
)
arm(
  LcnCarrierIoAdmitFailed, lcn_Carrier_io_admit_failed, arm_lcn_Carrier_io_admit_failed
)
arm(
  LcnCarrierIoAdmitUnavailable, lcn_Carrier_io_admit_unavailable,
  arm_lcn_Carrier_io_admit_unavailable,
)
arm(LcnCarrierIoClose, lcn_Carrier_io_close, arm_lcn_Carrier_io_close)
arm(LcnCarrierIoClosed, lcn_Carrier_io_closed, arm_lcn_Carrier_io_closed)
arm(LcnCarrierIoDispatch, lcn_Carrier_io_dispatch, arm_lcn_Carrier_io_dispatch)
arm(LcnCarrierIoEstablished, lcn_Carrier_io_established, arm_lcn_Carrier_io_established)
arm(LcnCarrierIoHello, lcn_Carrier_io_hello, arm_lcn_Carrier_io_hello)
arm(
  LcnCarrierIoLocalFailure, lcn_Carrier_io_local_failure,
  arm_lcn_Carrier_io_local_failure,
)
arm(
  LcnCarrierIoPublishFailed, lcn_Carrier_io_publish_failed,
  arm_lcn_Carrier_io_publish_failed,
)
arm(
  LcnCarrierIoPublishResult, lcn_Carrier_io_publish_result,
  arm_lcn_Carrier_io_publish_result,
)
arm(LcnCarrierIoRespond, lcn_Carrier_io_respond, arm_lcn_Carrier_io_respond)
arm(LcnCarrierIoStop, lcn_Carrier_io_stop, arm_lcn_Carrier_io_stop)
arm(
  LcnCarrierIoStopServing, lcn_Carrier_io_stop_serving, arm_lcn_Carrier_io_stop_serving
)
arm(LcnCarrierIoSubscribe, lcn_Carrier_io_subscribe, arm_lcn_Carrier_io_subscribe)
arm(
  LcnCarrierIoSubscriptionResult, lcn_Carrier_io_subscription_result,
  arm_lcn_Carrier_io_subscription_result,
)
arm(LcnCarrierIoTerminate, lcn_Carrier_io_terminate, arm_lcn_Carrier_io_terminate)
arm(
  LcnCarrierIoEndSubscription, lcn_Carrier_io_end_subscription,
  arm_lcn_Carrier_io_end_subscription,
)
arm(LcnCarrierIoUnsubscribe, lcn_Carrier_io_unsubscribe, arm_lcn_Carrier_io_unsubscribe)
arm(LcnCarrierIoWorkEnded, lcn_Carrier_io_work_ended, arm_lcn_Carrier_io_work_ended)
arm(LcnCarrierScopedCheck, lcn_Carrier_scoped_check, arm_lcn_Carrier_scoped_check)
arm(LcnCarrierScopedAdmit, lcn_Carrier_scoped_admit, arm_lcn_Carrier_scoped_admit)
arm(LcnCarrierScopedDone, lcn_Carrier_scoped_done, arm_lcn_Carrier_scoped_done)
arm(LcnCarrierScopedResult, lcn_Carrier_scoped_result, arm_lcn_Carrier_scoped_result)

proc frameOf*(m: LcnCarrierMessage): Result[seq[byte], string] =
  ## The length prefix and the encoded message.
  let body = ?encode(m)
  let f = frame(body, CarrierFrameLimit).valueOr:
    return err("a carrier message of " & $error.declared & " bytes does not fit")
  ok(f)

proc decodeMessage*(body: openArray[byte]): Result[LcnCarrierMessage, string] =
  ## One frame body as one message; anything else is carrier loss.
  LcnCarrierMessage.decode(body)

# Failures ------------------------------------------------------------------------------

func toCarrier*(f: AbiFailure): LcnCarrierFailure =
  result.code = uint8(ord(f.code))
  result.message = f.message
  result.detail = f.detail
  if f.reason.len > 0:
    result.reason = Opt.some(f.reason)

func toCarrier*(f: InvocationFailure): LcnCarrierFailure =
  LcnCarrierFailure(code: uint8(ord(f.code)), message: f.message, detail: f.detail)

func codeOf(c: uint8): ErrorCode =
  if c <= uint8(high(ErrorCode)) and c > 0:
    ErrorCode(c)
  else:
    ecModule

func toAbi*(f: LcnCarrierFailure): AbiFailure =
  AbiFailure(
    code: codeOf(f.code), message: f.message, detail: f.detail, reason: f.reason.get("")
  )

func toInvocation*(f: LcnCarrierFailure): InvocationFailure =
  InvocationFailure(code: codeOf(f.code), message: f.message, detail: f.detail)

when defined(posix):
  # Writing -------------------------------------------------------------------------------

  proc sendAll(
      fd: cint, data: openArray[byte], alive: AliveFn, ctx: pointer
  ): Result[void, string] =
    var off = 0
    while off < data.len:
      let n = sockSend(fd, unsafeAddr data[off], csize_t(data.len - off))
      if n > 0:
        off += int(n)
        continue
      if n == 0 or not (wouldBlock(n) or cint(-n) == posix.EINTR):
        return err("the carrier is closed (" & $(-n) & ")")
      var p = TPollfd(fd: fd, events: POLLOUT)
      discard posix.poll(addr p, 1, WriteStepMs)
      if alive != nil and not alive(ctx):
        return err("the other side has ended")
    ok()

  proc send*(
      w: var CarrierWriter,
      m: LcnCarrierMessage,
      alive: AliveFn = nil,
      ctx: pointer = nil,
  ): Result[void, string] =
    ## One whole frame, under the write lock.
    let f = ?frameOf(m)
    withLock w.lock:
      result = sendAll(w.fd, f, alive, ctx)

  proc sendFrame*(
      w: var CarrierWriter, f: openArray[byte], alive: AliveFn = nil, ctx: pointer = nil
  ): Result[void, string] =
    ## One whole frame `frameOf` made, under the write lock.
    withLock w.lock:
      result = sendAll(w.fd, f, alive, ctx)

  # Reading -------------------------------------------------------------------------------

  type ReadOutcome* = enum
    roFrames ## zero or more complete frames
    roClosed ## the other side closed its end
    roFailed ## a read error or a framing violation

  proc readFrames*(
      fd: cint, r: var FrameReader, frames: var seq[seq[byte]]
  ): (ReadOutcome, string) =
    ## One `recv` on a readable carrier: the frames it completes.
    var buf: array[65536, byte]
    let n = sockRecv(fd, addr buf[0], csize_t(buf.len))
    if n == 0:
      return (roClosed, "the carrier was closed")
    if n < 0:
      if wouldBlock(n) or cint(-n) == posix.EINTR:
        return (roFrames, "")
      return (roFailed, "the carrier failed (" & $(-n) & ")")
    let got = r.feed(buf.toOpenArray(0, int(n) - 1))
    if got.isErr:
      return (
        roFailed,
        "a carrier frame of " & $got.error.declared & " bytes is over the limit",
      )
    for f in got.get:
      frames.add(f)
    (roFrames, "")

else:
  proc send*(
      w: var CarrierWriter,
      m: LcnCarrierMessage,
      alive: AliveFn = nil,
      ctx: pointer = nil,
  ): Result[void, string] =
    err("hosted placement is not supported on this platform")

  proc sendFrame*(
      w: var CarrierWriter, f: openArray[byte], alive: AliveFn = nil, ctx: pointer = nil
  ): Result[void, string] =
    err("hosted placement is not supported on this platform")
