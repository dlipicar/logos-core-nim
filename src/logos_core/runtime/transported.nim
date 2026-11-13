## RUNTIME §4.1, §7.5; INTERFACE §2.5, §2.9.1, §5.2; TRANSPORT §3.1, §3.2, §3.4,
## §8.2; DECISIONS I90, G258, G259, G260: the caller half of a transported local
## route. Each route handle materialized over local transport is one `Link`: one
## connection, one Hello with the route's one-time ticket, one invocation-path
## generation (G164, G177).
##
## [IMPL; plan §2.6] In 4b-2 the caller half runs on the Runtime thread, which
## receives every event of the transport I/O thread anyway (`tport.nim`). The
## links live in the engine's table by `ConnId`; a materialization and each
## synchronous call park their reply on the link until the connection's event
## answers it; asynchronous calls are sent by the Runtime thread itself. Nothing
## of a link is memory another thread touches, so the caller half takes no lock
## and hands no Nim heap value across threads under either memory manager.
##
## The consumer's invocation material (`Material`: the endpoint path and the
## ticket of the latest live answer for a route) is kept with the links [IMPL]:
## the invocation boundary MAY retain it (RUNTIME l.958-961). It is taken by
## move at materialization and zeroed wherever it goes. 4b-3 moves the links
## and the material into the Module Host's binding and carries the Runtime's
## orders (`LinkOrders` in `ports.nim`) over the host carrier.
##
## A handle has two codes (plan §2.6, [Rev R4]): `routeCause`, the route's own
## end cause, which every new operation reports (RUNTIME l.1343-1347), and
## `observed`, the first terminal cause, which `observe_end` reports
## (INTERFACE l.1486-1490): the route's end or the connection's, whichever came
## first. A connection lost with no known cause is TRANSPORT_ERROR (TF-15, G256);
## NOT_READY is never inferred from it.
##
## [plan §2.7; I90 part 4b-2c] A subscription through a transported handle is
## a `LinkSub`: the consumer's `subscribe` waits until the provider's
## SubscriptionResult [Rev R6]; the Runtime thread activates the subscription
## when it processes the successful result, before the subscriber returns, so
## an Event that follows on the wire is queued, not dropped [Rev R7]. Events
## are queued on the Runtime thread and drained on the G178 event workers, at
## most one drain per subscription, each Event's credit released once its
## handler returned (TRANSPORT l.721-725).

{.push raises: [], gcsafe.}

import std/[deques, tables]
import results
import ../iface/outcome
import ../transport/ticket
from ../transport/io/api import ConnId, ConnectFailure, CloseCause, CallOutcome
import ../abi/types
import ./[callside, invoke, plumbing]

export results

type
  LinkState* = enum
    lkConnecting ## `cmdConnect` sent; the materialization waits
    lkOpen ## the Hello completed: the handle is returned
    lkClosed ## `evConnectFailed` or `evClosed` came

  Material* = object
    ## [plan §2.4] The invocation material of one live answer for a route: what
    ## its next materialization connects with. Never retained beyond that.
    path*: string
    ticket*: RouteTicket
    expires*: int64 ## the ticket's own expiry, on the engine's monotonic clock

  QueuedEvent* = object ## [plan §2.7] An Event waiting for its handler.
    name*: string
    data*: seq[byte]
    credit*: int ## held by the I/O thread until `cmdRelease`

  LinkSub* = ref object
    ## [plan §2.7] One subscription made through a transported handle.
    id*: uint64 ## its subscription id, on the wire and for the consumer
    sub*: pointer ## its `events.SubState`, with one reference held here
    event*: string
    active*: bool ## the successful SubscriptionResult came; not unsubscribed
    paused*: bool ## [IF l.1446-1449] an Unsubscribe is pending: no handler begins
    subscribing*: ReplyChannel ## the subscriber, until the SubscriptionResult
    outId*: ptr LogosSubscriptionId ## written before the subscriber returns
    unsubscribing*: ReplyChannel ## the unsubscriber, until its result
    queue*: Deque[QueuedEvent]
    draining*: bool ## an event worker drains it
    served*: int ## Events its current drain was handed (`rcDrainQuota`)

  Link* = ref object
    ## One transported route handle's connection, on the Runtime thread.
    conn*: ConnId
    route*, consumer*, attempt*: string
    handle*: pointer ## its `HandleState`
    generation*: uint64 ## [G177] the handle's own invocation-path generation
    state*: LinkState
    observed*: Opt[ErrorCode] ## [Rev R4] the first terminal cause
    routeCause*: Opt[ErrorCode] ## [Rev R4] the route's end cause
    held*: bool ## [Rev R5] the handle is returned and not released
    closeSent*: bool ## `cmdClose` was submitted
    connecting*: ReplyChannel ## the materialization, while `lkConnecting`
    calls*: Table[uint64, ReplyChannel] ## synchronous calls, by tag
    asyncs*: Table[uint64, pointer]
      ## [Rev R5] asynchronous calls by tag, each holding a reference to its
      ## call (and so to this link) until its Response or the connection's end
    nextTag*: uint64
    prepared*: int
      ## [Rev R5] asynchronous calls prepared on the handle and not yet
      ## submitted or released: each keeps the link
    subs*: OrderedTable[uint64, LinkSub] ## [plan §2.7] by subscription id
    nextSub*: uint64

proc burn*(m: var Material) =
  ## [SPEC TRANSPORT l.1038] The raw ticket exists only transiently.
  zeroMem(addr m.ticket[0], m.ticket.len)

func connectOutcome*(
    cause: ConnectFailure, code: ErrorCode
): tuple[code: ErrorCode, transportFailed: bool] =
  ## [plan §2.6; RUNTIME l.786-791; G259] What a failed connection makes of the
  ## materialization, and whether the route fails with `transport-error`. A
  ## Hello failure passes the peer's ProtocolError code or the local check's
  ## code through (the I/O thread reports it as `code`); a loss or the Hello
  ## deadline is TRANSPORT_ERROR. [K12, Rev R2] A peer that is not the expected
  ## identity fails the route, which revokes its tickets (TRANSPORT
  ## l.1131-1132). Local capacity and a construction input the I/O thread
  ## cannot rebuild are MODULE_ERROR [IMPL] (INTERFACE l.2041 pattern); a
  ## stopping loop is NOT_READY.
  case cause
  of cfHello, cfConnect:
    (code: code, transportFailed: false)
  of cfPeerMismatch:
    (code: ecTransport, transportFailed: true)
  of cfCapacity, cfContract, cfUnsupported:
    (code: ecModule, transportFailed: false)
  of cfShutdown:
    (code: ecNotReady, transportFailed: false)

func closedCode*(cause: CloseCause, code: ErrorCode): ErrorCode =
  ## [plan §2.6; TRANSPORT l.991, l.996; TF-15, G256] What a closed connection
  ## tells the handle when the route has not ended: a session the provider
  ## terminated with ProtocolError NOT_AUTHORISED is a known authorization
  ## failure; any other end is TRANSPORT_ERROR, never an inferred NOT_READY.
  if cause == ccPeerError and code == ecNotAuthorised: ecNotAuthorised else: ecTransport

proc observe*(l: Link, code: ErrorCode): bool =
  ## [Rev R4] Sets the first terminal cause; true when this was it.
  if l.observed.isSome:
    return false
  l.observed = Opt.some(code)
  true

func newCallCode*(l: Link): Opt[ErrorCode] =
  ## [SPEC RUNTIME l.1343-1347; plan §2.6 step 1; G22] What a new operation on
  ## the handle fails with before anything is sent: the route's cause, else
  ## the closed connection's.
  if l.routeCause.isSome:
    return l.routeCause
  if l.state != lkOpen:
    return Opt.some(l.observed.get(ecTransport))
  Opt.none(ErrorCode)

proc takeTag*(l: Link): uint64 =
  inc l.nextTag
  l.nextTag

func idle*(l: Link): bool =
  ## [Rev R5] Nothing keeps the connection: the handle is released and no
  ## asynchronous call awaits a Response.
  not l.held and l.connecting.isNil and l.prepared == 0 and l.asyncs.len == 0 and
    l.calls.len == 0

func failureOf*(o: CallOutcome): InvocationFailure =
  o.failure

# The consumer's thread --------------------------------------------------------------

proc linkCall*(
    h: ptr HandleState, bare: string, params: seq[byte]
): Result[seq[byte], InvocationFailure] =
  ## [SPEC INTERFACE §5.2; RUNTIME §4.1 l.1732; plan §2.6] A synchronous call
  ## through a transported handle. The Runtime thread checks the handle's
  ## codes in the order of a direct call's admission, sends the Request on the
  ## link and answers when its Response comes; the provider side authorizes.
  ## The selected contract's own checks (an INVALID_PARAMS the session refused
  ## locally, and G171's validation before a NOT_READY) are run again here,
  ## where the construction input is loaded, so the failure carries the same
  ## detail as on a direct route.
  let reply = h.engine.call(
    Request(
      kind: rqLinkCall,
      origin: moduleOrigin($h.consumer),
      attempt: $h.attempt,
      route: $h.route,
      conn: h.conn,
      bare: bare,
      payload: params,
    )
  )
  if reply.error.isSome:
    return err(notReadyAfter(h.blob, bare, params, reply.error.get))
  if reply.failure.isSome:
    let f = reply.failure.get
    if reply.recheck:
      let sel = selectedOf(h.blob)
      if sel.isOk:
        let r = checkRequest(sel.get, bare, params)
        if r.isErr:
          return err(r.error)
    return err(f)
  ok(reply.bytes)
