## TRANSPORT §2.1, §3, §8.2, §8.6; G77(a): the public types of the unix-stream
## transport I/O layer. One Runtime-owned I/O thread per process runs a chronos
## dispatcher (`loop.nim`); an owner on any other thread talks to it only through
## values: `IoCommand`s in, `IoEvent`s out. Neither type holds a `ref`, a `ptr`
## or a closure (checked below at compile time): payloads cross as deterministic
## CBOR bytes and are decoded again on the receiving thread, because a cyclic
## `ref` graph moved between threads crashes ORC (DECISIONS I75).

{.push raises: [].}

import std/macros
import results
import ../../cbor
import ../../hash/hashinput
import ../../iface/outcome
import ../[framing, hello, limits, ticket]

export results, hashinput, outcome, hello, limits, ticket

type
  ConnId* = uint64
    ## One connection. An owner picks the ids of its outbound connections below
    ## `AcceptedConnBase`; accepted connections get ids from it upward.
  EndpointId* = uint64 ## one served endpoint, chosen by the owner

const AcceptedConnBase* = 1'u64 shl 62

type
  PeerIdentity* = object
    ## [SPEC TRANSPORT §8.2] The operating-system identity a caller expects at
    ## the endpoint, from its protected Runtime context, never from the
    ## descriptor (TRN-0187).
    uid*: uint32

  PeerCred* = object
    ## What `SO_PEERCRED` or `getpeereid` reports for a connected socket: the
    ## identity of the process that created the listener (for a caller) or that
    ## connected (for a callee). `pid` is for diagnostics only.
    uid*, gid*: uint32
    pid*: Opt[int32]

  ContractInput* = object
    ## The construction input a thread rebuilds a contract from: the encoded
    ## `logos.schema_response` whose primary contract is `root` (INTERFACE §5.1).
    ## A callee gives its provider's primary contract, so any contract it serves
    ## can be selected; a caller gives the route's selected contract.
    root*: Digest
    schema*: seq[byte]
    system*: bool ## a Logos-defined contract, which may use reserved names

  TransportConfig* = object
    ## Every limit of one I/O thread, documented with its scope and exhaustion
    ## behaviour in `aggregate.nim` and `docs/CONFORMANCE.md` [SPEC TRANSPORT
    ## §8.6]. Times are nanoseconds. Checked by `validate` before a loop starts.
    frameLimit*, peerFrameLimit*: uint32 ## per connection (§2.1, I52)
    maxPayloadDepth*: int ## P for every decoder (INTERFACE §4.5.1; C36)
    maxInFlight*, maxCalls*, maxSubscriptionIds*: int ## per connection (I52)
    helloTimeout*: int64 ## the whole Hello exchange (G61)
    admissionTimeout*: int64 ## how long a frame waits for input bytes
    writeStallTimeout*: int64 ## pending output and no byte written
    closeLinger*: int64 ## flushing a final ProtocolError before close
    connOutputBytes*: int ## one connection's committed output
    controlReserve*: int ## of `connOutputBytes`, for control frames only
    maxInbound*: int ## accepted connections, pending Hellos included
    maxPendingHellos*: int
    maxOutbound*: int
    maxHelloInputBytes*: int ## frame bodies read before establishment
    maxInputBytes*: int ## frame bodies held after establishment
    maxOutputBytes*: int ## committed output, all connections
    listenBacklog*: int

  SubmitResult* = enum
    sbOk ## queued for the I/O thread
    sbBusy ## not queued: an output budget is full; submit again later
    sbStopped ## not queued: the loop has stopped

  AdmitVerdictKind* = enum
    ## [IMPL] The first kind carries no fields, as `IoCommandKind`.
    avUnavailable
      ## the owner could not evaluate the Hello: ProtocolError MODULE_ERROR,
      ## close, and the ticket stays live (§3.1 step 3)
    avEstablished ## the Hello passed and its ticket was redeemed
    avFailed ## a Hello check failed: send `code` (unless the peer sent it) and close

  AdmitVerdict* = object
    case kind*: AdmitVerdictKind
    of avUnavailable:
      discard
    of avEstablished:
      response*: seq[byte] ## the encoded Hello response
      binding*: RouteBinding ## never the ticket
      endsIn*: Opt[int64] ## when the session's authorization ends, from now
    of avFailed:
      code*: ErrorCode
      peer*: bool ## the caller reported it with a ProtocolError: send nothing

  CallOutcome* = object
    ## A call's terminal outcome: the encoded result map when `ok`, else
    ## `failure`. [IMPL] Not a case object: a `bool` discriminator cannot have
    ## a first branch without fields (`IoCommandKind`).
    ok*: bool
    result*: seq[byte]
    failure*: InvocationFailure

  IoCommandKind* = enum
    ## [IMPL] The first kind carries no fields (as the runtime's `MsgKind`).
    ## Nim 2.2.14's `=wasMoved` for a case object resets the active branch,
    ## sets the discriminator to its first value and resets that branch too,
    ## reading the discriminators of case objects nested in it from bytes
    ## another branch wrote: undefined behaviour (UBSan: `Channel.send` of a
    ## `cmdCall`, with `cmdServe` first). A field-less first branch leaves
    ## nothing to reset.
    cmdShutdown ## internal: `stopTransport`
    cmdServe ## accept on `listener` for `served`
    cmdStopServing ## stop accepting; established connections stay
    cmdAdmit ## the verdict on an `evHello`
    cmdRespond ## the terminal Response of a dispatched Request
    cmdConnect ## open an outbound connection and run the Hello
    cmdCall ## send a Request
    cmdCancel ## send Cancel for a call
    cmdAbandon ## stop awaiting a call (§3.4)
    cmdClose ## close a connection

  IoCommand* = object
    conn*: ConnId
    case kind*: IoCommandKind
    of cmdShutdown, cmdClose:
      discard
    of cmdServe:
      endpoint*: EndpointId
      listener*: cint ## an adopted listening fd; the I/O thread owns this copy
      served*: CalleeEndpoint
      contract*: ContractInput ## the provider's primary contract
    of cmdStopServing:
      stopEndpoint*: EndpointId
    of cmdAdmit:
      verdict*: AdmitVerdict
    of cmdRespond:
      requestId*: uint64
      outcome*: CallOutcome
    of cmdConnect:
      path*: string ## the exact endpoint path (§9.1)
      expected*: PeerIdentity
      module*: string
      ticket*: RouteTicket ## taken by value; zeroed once written
      selected*: ContractInput ## the route's selected contract
      firstId*: uint64 ## the first Request id
    of cmdCall:
      tag*: uint64 ## owner-chosen, unique on the connection
      methodName*: string
      params*: seq[byte] ## the encoded params map
    of cmdCancel, cmdAbandon:
      callTag*: uint64

  CloseCause* = enum
    ccPeerClosed ## end of input or a reset from the peer
    ccPeerError ## the peer sent ProtocolError `code`
    ccProtocol ## this side sent (or tried to send) ProtocolError `code`
    ccNotWritable ## the peer stopped reading (write stall) or a write failed
    ccHelloTimeout ## no complete Hello exchange within `helloTimeout`
    ccOwner ## `cmdClose`
    ccShutdown ## `stopTransport`

  ConnectFailure* = enum
    cfCapacity ## `maxOutbound` connections are open: nothing was opened
    cfConnect ## the exact path could not be connected to
    cfPeerMismatch ## the peer is not the expected identity: nothing was sent
    cfHello ## the Hello exchange failed or timed out
    cfContract ## the selected contract's construction input is invalid
    cfUnsupported ## this platform has no unix-stream profile (§8.2.1)
    cfShutdown ## the loop is stopping

  IoEventKind* = enum
    ## [IMPL] The first kind's branch holds no case object (`IoCommandKind`).
    evListening ## accepting for an endpoint
    evServeFailed ## the listener or the contract input was refused
    evHello ## a Hello to admit: answer with `cmdAdmit`
    evEstablished ## a callee session: route binding and peer
    evDispatch ## run a Request
    evStop ## try to stop a Request whose CANCELLED Response is committed
    evConnected ## a caller session is established
    evConnectFailed
    evResponse ## a call's terminal outcome
    evLocalFailure ## a command refused locally; nothing was sent
    evClosed ## the connection closed
    evStopped ## the loop has stopped; the last event

  IoEvent* = object
    conn*: ConnId
    case kind*: IoEventKind
    of evListening:
      listening*: EndpointId
    of evServeFailed:
      failedEndpoint*: EndpointId
      serveError*: string
    of evHello:
      helloEndpoint*: EndpointId
      frame*: seq[byte] ## the first frame body, for `acceptHello`
      helloPeer*: Opt[PeerCred] ## diagnostics only
    of evEstablished:
      endpoint*: EndpointId
      binding*: RouteBinding
      peer*: Opt[PeerCred]
    of evDispatch:
      requestId*: uint64
      methodName*: string
      params*: seq[byte] ## the encoded, validated params map
    of evStop:
      stopId*: uint64
    of evConnected:
      connectedPeer*: PeerCred
    of evConnectFailed:
      failCode*: ErrorCode
      failCause*: ConnectFailure
      observed*: Opt[PeerCred] ## the peer's identity on a mismatch
      failMsg*: string ## never contains the ticket
    of evResponse:
      tag*: uint64
      outcome*: CallOutcome
    of evLocalFailure:
      localTag*: uint64
      localCode*: ErrorCode
      localMsg*: string
    of evClosed:
      cause*: CloseCause
      code*: ErrorCode ## the ProtocolError code for ccPeerError and ccProtocol
      ids*: seq[uint64]
        ## callee: the Requests dispatched and not answered; caller: the tags
        ## of the calls that failed with TRANSPORT_ERROR (each also reported
        ## as an `evResponse`)
    of evStopped:
      discard

  IoSink* = proc(ev: sink IoEvent, ctx: pointer) {.nimcall, gcsafe, raises: [].}
    ## Called on the I/O thread with every event, in order (per connection, the
    ## wire order). It must not block and must not call `stopTransport`.

# The no-ref check ------------------------------------------------------------------

proc refFree(t: NimNode, seen: var seq[string]): string =
  ## The name of the first `ref`, `ptr`, closure or pointer type reachable from
  ## `t`; empty when there is none.
  case t.kind
  of nnkSym:
    let name = t.strVal
    case name
    of "string", "bool", "char", "int", "int8", "int16", "int32", "int64", "uint",
        "uint8", "uint16", "uint32", "uint64", "float", "float32", "float64", "cint",
        "byte":
      return ""
    of "pointer", "cstring":
      return name
    else:
      discard
    if name in seen:
      return ""
    seen.add(name)
    let impl = t.getTypeImpl
    if impl.kind == nnkSym and impl.strVal == name:
      return ""
    return refFree(impl, seen)
  of nnkRefTy, nnkPtrTy, nnkProcTy:
    return t.repr
  of nnkObjectTy:
    for c in t:
      let r = refFree(c, seen)
      if r.len > 0:
        return r
  of nnkRecList, nnkRecCase, nnkOfBranch, nnkElse:
    for c in t:
      if c.kind in {nnkIdentDefs, nnkRecList, nnkRecCase, nnkOfBranch, nnkElse}:
        let r = refFree(c, seen)
        if r.len > 0:
          return r
  of nnkIdentDefs:
    let r = refFree(t[^2], seen)
    if r.len > 0:
      return r
  of nnkBracketExpr:
    if t[0].kind == nnkSym and t[0].strVal in ["ref", "ptr"]:
      return t.repr
    for i in 1 ..< t.len:
      if t[i].kind in {nnkSym, nnkBracketExpr, nnkObjectTy, nnkTupleTy}:
        let r = refFree(t[i], seen)
        if r.len > 0:
          return r
    if t[0].kind == nnkSym and t[0].strVal notin ["seq", "array", "set", "range"]:
      return refFree(t.getTypeImpl, seen)
  of nnkTupleTy, nnkTupleConstr:
    for c in t:
      let r = refFree(c, seen)
      if r.len > 0:
        return r
  of nnkDistinctTy:
    return refFree(t[0], seen)
  else:
    discard
  ""

macro assertValueOnly(t: typedesc): untyped =
  var seen: seq[string]
  let r = refFree(t.getTypeInst[1], seen)
  if r.len > 0:
    error($t & " must cross threads by value, but holds " & r, t)
  newEmptyNode()

assertValueOnly(IoCommand)
assertValueOnly(IoEvent)

# Configuration ---------------------------------------------------------------------

const
  Millisecond = 1_000_000'i64
  Second = 1000 * Millisecond
  MiB = 1024 * 1024

func defaultTransportConfig*(): TransportConfig =
  ## The [IMPL] defaults of the table in `aggregate.nim`.
  TransportConfig(
    frameLimit: MinFrameLimit,
    peerFrameLimit: MinFrameLimit,
    maxPayloadDepth: DefaultMaxDepth,
    maxInFlight: DefaultMaxInFlight,
    maxCalls: DefaultMaxCalls,
    maxSubscriptionIds: DefaultMaxSubscriptionIds,
    helloTimeout: 10 * Second,
    admissionTimeout: 10 * Second,
    writeStallTimeout: 30 * Second,
    closeLinger: 1 * Second,
    connOutputBytes: 2 * MinFrameLimit + 64 * 1024,
    controlReserve: 64 * 1024,
    maxInbound: 1024,
    maxPendingHellos: 64,
    maxOutbound: 1024,
    maxHelloInputBytes: 32 * MiB,
    maxInputBytes: 256 * MiB,
    maxOutputBytes: 256 * MiB,
    listenBacklog: 128,
  )

func connLimits*(c: TransportConfig): Result[TransportLimits, string] =
  ## The per-connection limits (I52) the session state machines run under.
  transportLimits(
    c.frameLimit, c.peerFrameLimit, c.maxPayloadDepth, c.maxInFlight, c.maxCalls,
    c.maxSubscriptionIds,
  )

func validate*(c: TransportConfig): Result[void, string] =
  ## [SPEC TRANSPORT §2.1, §8.6] Every limit finite and positive; the output
  ## budget holds one maximal frame and the control reserve; each input pool
  ## admits one maximal frame, so the active frame maximum stays at least
  ## 16 MiB (F10).
  discard ?c.connLimits()
  for (name, v) in [
    ("helloTimeout", c.helloTimeout),
    ("admissionTimeout", c.admissionTimeout),
    ("writeStallTimeout", c.writeStallTimeout),
    ("closeLinger", c.closeLinger),
  ]:
    if v <= 0:
      return err(name & " is not positive (TRANSPORT §8.6)")
  for (name, v) in [
    ("connOutputBytes", c.connOutputBytes),
    ("controlReserve", c.controlReserve),
    ("maxInbound", c.maxInbound),
    ("maxPendingHellos", c.maxPendingHellos),
    ("maxOutbound", c.maxOutbound),
    ("maxHelloInputBytes", c.maxHelloInputBytes),
    ("maxInputBytes", c.maxInputBytes),
    ("maxOutputBytes", c.maxOutputBytes),
    ("listenBacklog", c.listenBacklog),
  ]:
    if v <= 0:
      return err(name & " is not positive (TRANSPORT §8.6)")
  if c.controlReserve < 4096:
    return err("controlReserve is below 4096 bytes: it must hold control frames")
  if int64(c.connOutputBytes) < int64(c.peerFrameLimit) + int64(c.controlReserve) + 4:
    return err("connOutputBytes cannot hold a maximal frame and the control reserve")
  if c.maxOutputBytes < c.connOutputBytes:
    return err("maxOutputBytes is below connOutputBytes")
  for (name, v) in [
    ("maxHelloInputBytes", c.maxHelloInputBytes), ("maxInputBytes", c.maxInputBytes)
  ]:
    if int64(v) < int64(c.frameLimit):
      return err(
        name & " is below frameLimit: a maximal frame could never be admitted " &
          "(TRANSPORT §2.1)"
      )
  if c.maxPendingHellos > c.maxInbound:
    return err("maxPendingHellos is above maxInbound")
  ok()
