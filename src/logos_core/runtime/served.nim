## RUNTIME §4.1, §6.2, §7.5; TRANSPORT §3.1, §4, §6, §8.1, §8.2; DECISIONS I90,
## G257: the provider half of transported local routes. The Runtime serves a
## direct provider at an endpoint of its own (G257, owner batch B decision 6):
## the provider's code runs in this process, on the engine's call workers,
## while its consumers reach it over `logos.local.unix-stream`.
##
## [Rev R11] This half never touches the engine's state, so 4b-3 can run it in a
## Module Host. On the Runtime thread it keeps:
## - the endpoints, one per provider realization, made lazily the first time a
##   transported route to that realization is established [IMPL];
## - the sessions, by accepted `ConnId`, each bound to the route its ticket
##   named, and the served invocations dispatched on it;
## - the orders the Runtime gives it (`EndpointOrders`): stop serving,
##   terminate, drain, close.
## The engine is its Session Authority in 4b-2: it judges Hellos (ticket store,
## state checks), admits calls, and ends sessions; it passes the results in.
## The served invocations themselves are `asynccall.AsyncCall`s with a session
## origin; this half holds them only as opaque `CallRef`s (`ports.nim`).
##
## [IMPL] Every command it submits is uncharged, so a Runtime-thread submit is
## never busy (`tport.submitOwner`).

{.push raises: [], gcsafe.}

import std/[monotimes, sets, tables]
import results
import ../hash/hashinput
import ../iface/outcome
import ../transport/hello
import ../transport/io/[api, endpoint, sock]
import ./[ports, tport]

export results, ports

type
  EndpointState* = enum
    esServing ## `cmdServe` sent; accepting
    esStopped ## `cmdStopServing` sent: established sessions stay (§2.5)
    esFailed ## the I/O thread refused it (`evServeFailed`)

  ServedEndpoint* = ref object ## One endpoint of one provider realization.
    id*: EndpointId
    realization*: string ## the provider instance and its attempt
    instance*: string ## the provider instance
    provider*: string ## its provider record
    module*: string
    ep*: Endpoint
    callee*: CalleeEndpoint ## what a Hello is checked against
    state*: EndpointState
    listening*: bool
    sessions*: HashSet[ConnId]

  Session* = ref object
    ## One accepted connection, from its Hello verdict until `evClosed`.
    conn*: ConnId
    endpoint*: EndpointId
    route*: string ## the route its ticket named (TRANSPORT l.1055)
    consumer*: string ## the ticket record's consumer, never the caller's word
    consumerAttempt*: string ## the attempt that established the route
    generation*: uint64 ## its own invocation-path generation (G177)
    endsAt*: Opt[int64]
      ## [Rev R1; TRN-0317] its bound decision's end on the engine's monotonic
      ## clock: the Runtime terminates it then, also after a renewal
    established*: bool ## `evEstablished` came
    draining*: bool ## [Rev R1] no new admission; closes once its calls end
    drainUntil*: Opt[MonoTime]
    ended*: bool ## terminate or close was ordered
    calls*: OrderedTable[uint64, CallRef]
      ## dispatched Requests not yet ended, by id: the served invocations

  Served* = ref object
    tport: TransportPorts
    base: string ## `runtime.endpoint_dir`
    limits*: TransportLimits ## for `acceptHello`
    nextEndpoint: EndpointId
    nextGeneration: uint64
    endpoints*: OrderedTable[EndpointId, ServedEndpoint]
    byRealization: Table[string, EndpointId]
    sessions*: OrderedTable[ConnId, Session]

proc newServed*(tport: TransportPorts, base: string): Served =
  Served(
    tport: tport,
    base: base,
    limits: tport.config.connLimits().get(defaultLimits()),
    nextGeneration: 1'u64 shl 40, # [IMPL] apart from handle generations
  )

func isServed*(conn: ConnId): bool =
  ## Accepted connections are the provider half's; lower ids are links.
  conn >= AcceptedConnBase

proc submit(sv: Served, cmd: sink IoCommand) =
  discard sv.tport.submitOwner(cmd)

# Endpoints ------------------------------------------------------------------------

proc endpointOf*(sv: Served, realization: string): ServedEndpoint =
  ## The serving endpoint of a provider realization, or nil.
  let id = sv.byRealization.getOrDefault(realization)
  result = sv.endpoints.getOrDefault(id)
  if result != nil and result.state != esServing:
    result = nil

proc openEndpoint*(
    sv: Served,
    realization, instance, provider, module: string,
    contracts: seq[Digest],
    primary: ContractInput,
): Result[ServedEndpoint, string] =
  ## [SPEC TRANSPORT §8.2; G58; plan §2.5] Creates and validates the endpoint
  ## on this thread, then hands a duplicate of its listener to the I/O thread.
  ## The socket is listening in the kernel before this returns, and `cmdServe`
  ## precedes any later `cmdConnect` in the loop's order, so a route can be
  ## returned `ready` at once (RUNTIME l.3118).
  let ep = createEndpoint(sv.base, module, sv.tport.config.listenBacklog).valueOr:
    return err("the endpoint cannot be created: " & error.msg)
  validateEndpoint(ep).isOkOr:
    discard removeEndpoint(ep)
    return err("the endpoint is not valid: " & error.msg)
  let fd = dupFd(ep.listener)
  if fd < 0:
    discard removeEndpoint(ep)
    return err("the listener cannot be duplicated")
  inc sv.nextEndpoint
  let e = ServedEndpoint(
    id: sv.nextEndpoint,
    realization: realization,
    instance: instance,
    provider: provider,
    module: module,
    ep: ep,
    callee: CalleeEndpoint(
      # [IMPL-DECISION G257] the Hello's `module` (TRANSPORT l.451): the
      # flat module name; the realization is bound by the endpoint itself
      endpoint: ep.path,
      provider: module,
      contracts: contracts,
    ),
    state: esServing,
  )
  let r = sv.tport.submitOwner(
    IoCommand(
      kind: cmdServe, endpoint: e.id, listener: fd, served: e.callee, contract: primary
    )
  )
  if r != sbOk:
    discard fdClose(fd)
    discard removeEndpoint(ep)
    return err("the transport is stopping")
  sv.endpoints[e.id] = e
  sv.byRealization[realization] = e.id
  ok(e)

proc maybeRemove(sv: Served, e: ServedEndpoint) =
  ## [SPEC RUNTIME l.1166] Removed once it no longer serves and its last
  ## session has closed.
  if e.state == esServing or e.sessions.len > 0:
    return
  sv.endpoints.del(e.id)
  if sv.byRealization.getOrDefault(e.realization) == e.id:
    sv.byRealization.del(e.realization)
  discard removeEndpoint(e.ep)

proc listening*(sv: Served, id: EndpointId) =
  let e = sv.endpoints.getOrDefault(id)
  if e != nil:
    e.listening = true

proc serveFailed*(sv: Served, id: EndpointId): ServedEndpoint =
  ## `evServeFailed`: the endpoint is unusable; nil when unknown.
  result = sv.endpoints.getOrDefault(id)
  if result != nil and result.state == esServing:
    result.state = esFailed
    sv.maybeRemove(result)

proc stopServing*(sv: Served, id: EndpointId) =
  ## [plan §2.5] `EndpointOrders.stopServing`: no new connection; established
  ## sessions stay until their routes' ends close them.
  let e = sv.endpoints.getOrDefault(id)
  if e == nil or e.state != esServing:
    return
  e.state = esStopped
  sv.submit(IoCommand(kind: cmdStopServing, stopEndpoint: id))
  sv.maybeRemove(e)

proc stopServingAll*(sv: Served) =
  ## [SPEC RUNTIME l.3846-3849] Shutdown, step 1.
  var ids: seq[EndpointId]
  for id in sv.endpoints.keys:
    ids.add(id)
  for id in ids:
    sv.stopServing(id)

proc stopServingRealization*(sv: Served, instance: string) =
  ## [L3] The provider instance left `ready`: none of its endpoints serves.
  var ids: seq[EndpointId]
  for id, e in sv.endpoints:
    if e.instance == instance and e.state == esServing:
      ids.add(id)
  for id in ids:
    sv.stopServing(id)

proc removeAll*(sv: Served) =
  ## [plan §2.9] At close: every endpoint still present is removed; the I/O
  ## thread has stopped.
  for e in sv.endpoints.values:
    discard removeEndpoint(e.ep)
  sv.endpoints.clear()
  sv.byRealization.clear()
  sv.sessions.clear()

# Hello ----------------------------------------------------------------------------

proc admitted*(
    sv: Served,
    conn: ConnId,
    e: ServedEndpoint,
    est: Established,
    consumerAttempt: string,
): Session =
  ## [plan §2.5 Hello steps 3-5] The Hello passed and its ticket was redeemed:
  ## the session is recorded at the verdict. Its end at its decision's expiry
  ## is the Runtime's timer (`endsAt`), so the I/O end timer is not armed.
  inc sv.nextGeneration
  result = Session(
    conn: conn,
    endpoint: e.id,
    route: est.binding.route,
    consumer: est.binding.consumer,
    consumerAttempt: consumerAttempt,
    generation: sv.nextGeneration,
    endsAt: est.binding.expires,
  )
  sv.sessions[conn] = result
  e.sessions.incl(conn)
  sv.submit(
    IoCommand(
      conn: conn,
      kind: cmdAdmit,
      verdict: AdmitVerdict(
        kind: avEstablished,
        response: est.response,
        binding: est.binding,
        endsIn: Opt.none(int64),
      ),
    )
  )

proc refused*(sv: Served, conn: ConnId, f: HelloFailure) =
  ## A Hello check failed: its code, unless the peer sent it.
  sv.submit(
    IoCommand(
      conn: conn,
      kind: cmdAdmit,
      verdict: AdmitVerdict(kind: avFailed, code: f.code, peer: f.peer),
    )
  )

proc unavailable*(sv: Served, conn: ConnId) =
  ## [SPEC TRANSPORT §3.1 step 3] The Hello was not evaluated: MODULE_ERROR,
  ## and its ticket stays live.
  sv.submit(
    IoCommand(conn: conn, kind: cmdAdmit, verdict: AdmitVerdict(kind: avUnavailable))
  )

proc established*(sv: Served, conn: ConnId) =
  let s = sv.sessions.getOrDefault(conn)
  if s != nil:
    s.established = true

# Served invocations ---------------------------------------------------------------

proc session*(sv: Served, conn: ConnId): Session =
  sv.sessions.getOrDefault(conn)

proc addCall*(s: Session, requestId: uint64, call: CallRef) =
  s.calls[requestId] = call

proc respondFailure*(sv: Served, conn: ConnId, requestId: uint64, code: ErrorCode) =
  ## A Request answered with `code` before any served invocation exists; its
  ## work has ended.
  sv.submit(
    IoCommand(
      conn: conn,
      kind: cmdRespond,
      requestId: requestId,
      outcome: CallOutcome(ok: false, failure: InvocationFailure(code: code)),
      workEnded: true,
    )
  )

proc close*(sv: Served, s: Session)

proc callEnded*(sv: Served, conn: ConnId, requestId: uint64) =
  ## [SPEC TRANSPORT §6, §8.6] Nothing of the served invocation runs any more:
  ## its slot is released (a no-op when its Response said so). [Rev R1] A
  ## draining session whose last served call ended closes, with no
  ## ProtocolError (K13).
  sv.submit(IoCommand(conn: conn, kind: cmdWorkEnded, endedId: requestId))
  let s = sv.sessions.getOrDefault(conn)
  if s == nil:
    return
  s.calls.del(requestId)
  if s.draining and s.calls.len == 0:
    sv.close(s)

# Orders -----------------------------------------------------------------------------

proc terminate*(sv: Served, s: Session): seq[CallRef] =
  ## [plan §2.8 step 4; owner batch B 7] `EndpointOrders.terminate`: an
  ## authority end. Every in-flight served Request is answered NOT_AUTHORISED
  ## (uncharged; the I/O thread ignores one already answered), then the
  ## session terminates: ProtocolError NOT_AUTHORISED when writable, then close
  ## (TRANSPORT l.987-991). The loop's order puts the Responses first. Returns
  ## the served invocations, which now commit nothing.
  if s.ended:
    return
  s.ended = true
  for id, c in s.calls:
    result.add(c)
    sv.submit(
      IoCommand(
        conn: s.conn,
        kind: cmdRespond,
        requestId: id,
        outcome:
          CallOutcome(ok: false, failure: InvocationFailure(code: ecNotAuthorised)),
        workEnded: false,
      )
    )
  sv.submit(IoCommand(conn: s.conn, kind: cmdTerminate))

proc drain*(sv: Served, s: Session, deadline: MonoTime) =
  ## [Rev R1] `EndpointOrders.drain`: a readiness end. The session admits
  ## nothing new (the route is terminal, so `admit` refuses NOT_READY);
  ## in-flight Requests commit their own results; it closes once its last
  ## served call ended, or at `deadline`.
  if s.ended or s.draining:
    return
  s.draining = true
  s.drainUntil = Opt.some(deadline)
  if s.calls.len == 0:
    sv.close(s)

proc close*(sv: Served, s: Session) =
  ## `EndpointOrders.close`: at once, with no ProtocolError.
  if s.ended:
    return
  s.ended = true
  sv.submit(IoCommand(conn: s.conn, kind: cmdClose))

proc checkDrains*(sv: Served, now: MonoTime) =
  ## Draining sessions past their deadline close.
  var due: seq[Session]
  for s in sv.sessions.values:
    if s.draining and not s.ended and s.drainUntil.isSome and now >= s.drainUntil.get:
      due.add(s)
  for s in due:
    sv.close(s)

proc nextDrain*(sv: Served): Opt[MonoTime] =
  var t = Opt.none(MonoTime)
  for s in sv.sessions.values:
    if s.draining and not s.ended and s.drainUntil.isSome:
      if t.isNone or s.drainUntil.get < t.get:
        t = s.drainUntil
  t

proc closed*(sv: Served, conn: ConnId): Session =
  ## `evClosed` on a served connection: the session is gone (nil when it was
  ## never admitted). Its calls stay in the returned record for the Runtime;
  ## the endpoint goes once it no longer serves and has no session.
  var s: Session
  if not sv.sessions.pop(conn, s):
    return nil
  let e = sv.endpoints.getOrDefault(s.endpoint)
  if e != nil:
    e.sessions.excl(conn)
    sv.maybeRemove(e)
  s.ended = true
  s
