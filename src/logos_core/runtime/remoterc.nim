## Inbound remote Runtime Control (Tier 5 step 5-7a-2; DECISIONS G413; 5-7a
## plan §3.5, §3.9) [IMPL]: logosd's side of a remote Runtime Control
## connection that a `logos_remote` listener process accepted, authenticated
## against this start's trust snapshot and relays (`remotesup.nim`). No
## module payload crosses it: only Runtime Control, whose requests the engine
## serves for the forwarded consumer the connection is bound to.
##
## - **The Hello** (RUNTIME l.1685-1699, l.2741-2747). The peer is checked
##   again against the snapshot: an active `logos.remote.tls-tcp` record of
##   the Runtime the handshake authenticated, at the revision it presented
##   (§3.5). Then, in TRANSPORT §3.1's order: `module` must be
##   `logos_runtime_control`; `token` must be exactly one deterministic-CBOR
##   `logos.runtime.module_instance_address` whose `runtime_instance_id` is
##   that Runtime (a missing, empty, malformed, non-deterministic,
##   trailing-byte or ownership-mismatched one is the same NOT_AUTHORISED);
##   `schema` must be the Runtime Control contract (VERSION_MISMATCH). The
##   engine then admits the connection while its listener serves Runtime
##   Control (`rqRemoteHello`). Any failure is a ProtocolError and no session;
##   the response's token is empty.
## - **The session** is TRANSPORT's callee side (`session.CalleeConn`), with
##   the payload checks deferred: each Request is dispatched once its method
##   resolves, and its worker asks the method's authorization first, then
##   checks the commitment and schema, then invokes it (RUNTIME l.1835,
##   RUN-1124). Every invocation is bound to the connection's consumer.
## - **Subscriptions** are refused (MODULE_ERROR) [G413 interim]: Runtime
##   Control events are not delivered to a remote consumer until step 5-7b.
## - **Threads.** One session thread owns every connection's state and the
##   snapshot: the supervision thread only queues to it (`RemoteInbound`).
##   Workers, up to `MaxWorkers`, made as needed, run what calls into the
##   engine and may block: an admission, an invocation, an end. Answers go
##   to the one process run they are for (`RemoteSupervisor.post`).
##
## Closing (`closeRemoteRc`) comes after the supervisor's close, so nothing
## more arrives, and before the engine's: a worker may still be in a call.

{.push raises: [], gcsafe.}

import std/[tables, typedthreads]
import results
import logos_sdk/base/[perthread, wipe]
import logos_sdk/cbor
import logos_sdk/iface/[accept, outcome, surface]
import logos_sdk/kit/rc_types
import ../remote/carrier
import ../transport/[boundary, envelope, hello, limits, session]
import ../transport/tls/trust
import ./[forwarded, invoke, remotesup]
from ./plumbing import Engine
from ./routing import RuntimeControlModule

const MaxWorkers = 8 ## [IMPL] the engine calls in flight at once

type RcOutcome = outcome.Outcome ## (not `choice.Outcome`)

type
  InKind = enum
    ikFrame ## a relayed `hello_judge`, `rc_in` or `conn_closed`
    ikEnded ## a listener process run ended
    ikClose ## the engine ended these connections
    ikAdmitted ## an admission's answer
    ikDone ## an invocation's outcome
    ikStop

  Inbox = object
    kind: InKind
    key: seq[byte]
    run, conn, id: uint64
    body: seq[byte]
    tokens: seq[string]
    token: string
    code: ErrorCode ## ikAdmitted: ecOk once admitted
    ok: bool ## ikDone: `response` holds the result; else `failure`
    response: seq[byte] ## ikDone: the encoded response value
    failure: InvocationFailure ## ikDone
    closeConn: bool ## ikDone: the payload check ends the connection

  JobKind = enum
    jbAdmit
    jbCall
    jbClosed
    jbStop

  Job = object
    kind: JobKind
    key: seq[byte]
    run, conn: uint64
    consumer, token: string
    id: uint64 ## jbCall: the Request's
    methodName: string
    params: seq[byte] ## jbCall: the Request's params, encoded (no ref crosses)
    commitment: PayloadCommitment

  ConnKey = (uint64, uint64) ## the process run, its connection number

  Conn = object
    key: seq[byte] ## the listener's address bytes
    consumer: string ## the forwarded consumer (`forwardedId`)
    token: string ## the engine's admission; empty until admitted
    response: seq[byte] ## the Hello response, sent once admitted
    admitted: bool
    ending: bool ## close_conn sent: what it still relays is dropped
    session: CalleeConn

  RemoteRcObj = object
    engine: Engine
    sup: RemoteSupervisor
    snapshot: seq[byte] ## one encoded `lcn.rch_snapshot`
    inbox: Channel[Inbox]
    jobs: Channel[Job]
    thread: Thread[ptr RemoteRcObj]
    workers: array[MaxWorkers, Thread[ptr RemoteRcObj]]
    spawned: int ## session thread only
    busy: int ## session thread only
    limits: TransportLimits

  RemoteRc* = ptr RemoteRcObj

proc rcBoundaryOf(): Boundary =
  let docs = rcDocuments()
  let set = acceptContractSet(docs[0], docs[1], docs[2], AcceptOptions(system: true))
  doAssert set.isOk, "the mirrored Runtime Control contract does not accept"
  let b = boundary(set.get, set.get.primary.root)
  doAssert b.isOk, "the Runtime Control contract gives no boundary"
  b.get

perThread(rcBoundary, Boundary, rcBoundaryOf())

func protocolError(code: ErrorCode): seq[byte] =
  ## [SPEC TRANSPORT §1.3, §2.3, §8.1] Without message or detail: it does not
  ## reveal which condition occurred.
  encodeCbor(
    toCbor(Message(kind: mkProtocolError, protocolError: InvocationFailure(code: code)))
  )

func refusal(code: ErrorCode): HelloFailure =
  failure(code, hrToken, NotAuthorisedMessage)

# The Hello ---------------------------------------------------------------------------

proc judge(
    trust: TrustSnapshot, h: LcnRchHelloJudge, limits: TransportLimits
): Result[string, HelloFailure] =
  ## The forwarded consumer the Hello binds, or why it is refused.
  # [plan §3.5] The peer again, against this start's snapshot.
  if trust.isNil:
    return err(refusal(ecNotAuthorised))
  let rec = trust.record(h.runtime)
  if rec.isNone or rec.get.status != rsActive or rec.get.revision != h.revision:
    return err(refusal(ecNotAuthorised))
  let (hello, schemaOk) = ?readHello(h.hello, limits)
  # [SPEC RUNTIME l.2741-2742; TRANSPORT §3.1] module, token, schema.
  if hello.module != RuntimeControlModule:
    return err(refusal(ecNotAuthorised))
  # [SPEC RUNTIME l.1694-1699] One deterministic value, nothing after it,
  # owned by the authenticated Runtime.
  if hello.token.len == 0:
    return err(refusal(ecNotAuthorised))
  let a = LogosNSRuntimeModuleInstanceAddress.decode(hello.token).valueOr:
    return err(refusal(ecNotAuthorised))
  if a.runtime_instance_id != h.runtime:
    return err(refusal(ecNotAuthorised))
  let consumer = forwardedId(a.runtime_instance_id, a.module_instance_id)
  if consumer.len == 0:
    return err(refusal(ecNotAuthorised))
  if not schemaOk or hello.schema != rcBoundary().selected:
    return err(
      failure(ecVersionMismatch, hrSchema, "the Hello schema is not Runtime Control")
    )
  ok(consumer)

proc helloResponse(limits: TransportLimits): Result[seq[byte], EnvelopeError] =
  ## [SPEC RUNTIME l.1701] The response token is empty.
  encodeMessage(
    Message(
      kind: mkHello,
      hello:
        Hello(module: RuntimeControlModule, token: @[], schema: rcBoundary().selected),
    ),
    limits.payloadDepth,
    limits.peerFrameLimit,
  )

# Workers ---------------------------------------------------------------------------------

proc invoke(r: RemoteRc, j: var Job): Inbox =
  ## One Runtime Control Request of a forwarded consumer, in RUNTIME's order
  ## of checks (l.1824-1835).
  result = Inbox(kind: ikDone, run: j.run, conn: j.conn, id: j.id)
  let bare = j.methodName
  let marked = rcBoundary().marked(bare).request
  defer:
    if marked:
      wipe(j.params) # [DECISIONS G276]
  let authorized = r.engine.rcAuthorizeMethod(j.consumer, j.token, bare)
  if authorized.isErr:
    result.failure = authorized.error
    return
  let decoded = decodeCbor(j.params)
  if decoded.isErr:
    result.failure = InvocationFailure(code: ecModule)
    return
  let request = envelope.Request(
    id: j.id, methodName: bare, params: decoded.get, commitment: j.commitment
  )
  defer:
    if marked:
      wipe(request.params)
  let checked = rcBoundary().checkRequestPayload(request)
  if checked.isErr:
    case checked.error.kind
    of rjClose:
      result.closeConn = true
      result.code = checked.error.failure.code
      return
    of rjRespond:
      result.failure = checked.error.failure
      return
    of rjOwner:
      discard # the schema failure: the invocation answers it, with its detail
  let res = r.engine.rcInvoke(j.consumer, j.token, bare, j.params, authorized = true)
  if res.isErr:
    result.failure = res.error
    return
  result.ok = true
  result.response = res.get

proc workerMain(r: RemoteRc) {.thread.} =
  while true:
    var j: Job
    try:
      j = r.jobs.recv()
    except Exception:
      return # [IMPL] the channel's hooks: not expected
    case j.kind
    of jbStop:
      return
    of jbAdmit:
      let t = r.engine.remoteAdmit(j.key, j.consumer)
      r.inbox.send(
        Inbox(
          kind: ikAdmitted,
          run: j.run,
          conn: j.conn,
          token: t.get(""),
          code: (if t.isOk: ecOk else: t.error.code),
        )
      )
    of jbClosed:
      r.engine.remoteClosed(j.token)
    of jbCall:
      r.inbox.send(r.invoke(j))

# The session thread ------------------------------------------------------------------------

proc queue(r: RemoteRc, j: sink Job) =
  ## A job for the workers; one more worker while all are busy.
  inc r.busy
  if r.busy > r.spawned and r.spawned < MaxWorkers:
    try:
      createThread(r.workers[r.spawned], workerMain, r)
      inc r.spawned
    except ResourceExhaustedError:
      discard # a busy worker takes it
  r.jobs.send(j)

proc send(r: RemoteRc, run: uint64, msgs: varargs[LcnRchMessage]) =
  r.sup.post(run, msgs)

proc endConn(r: RemoteRc, k: ConnKey, c: var Conn, last: openArray[byte]) =
  ## Ends a connection from this side: `last` sent first, if any.
  if c.ending:
    return
  c.ending = true
  if last.len > 0:
    r.send(k[0], toMessage(LcnRchRcOut(id: k[1], frame: @last)))
  r.send(k[0], toMessage(LcnRchCloseConn(id: k[1])))

proc act(r: RemoteRc, k: ConnKey, c: var Conn, acts: seq[CalleeAction]) =
  for a in acts:
    if c.ending:
      return
    case a.kind
    of caDispatch:
      if a.introspection:
        # [SPEC TRANSPORT §8.1] `logos.schema`: the Runtime Control contract's,
        # from its mirrored text.
        let v = schemaResponse(rcBoundary().contracts, rcBoundary().selected)
        let o =
          if v.isOk:
            RcOutcome(ok: true, response: v.get)
          else:
            RcOutcome(ok: false, failure: InvocationFailure(code: ecModule))
        let bytes = c.session.respond(a.request.id, o)
        if bytes.isSome:
          r.send(k[0], toMessage(LcnRchRcOut(id: k[1], frame: bytes.get)))
        r.act(k, c, c.session.workEnded(a.request.id))
      else:
        var params = encodeCbor(a.request.params)
        if c.session.marked(a.request.methodName).request:
          wipe(a.request.params) # [DECISIONS G276] encoded: the tree is done
        r.queue(
          Job(
            kind: jbCall,
            run: k[0],
            conn: k[1],
            consumer: c.consumer,
            token: c.token,
            id: a.request.id,
            methodName: a.request.methodName,
            params: move params,
            commitment: a.request.commitment,
          )
        )
    of caSend:
      r.send(k[0], toMessage(LcnRchRcOut(id: k[1], frame: a.bytes)))
    of caStop:
      discard # its CANCELLED is committed; the invocation runs to its end
    of caSubscribe:
      # [G413 interim] No Runtime Control event reaches a remote consumer
      # until step 5-7b.
      let res = c.session.subscriptionResult(
        a.subId,
        Opt.some(
          InvocationFailure(
            code: ecModule,
            message:
              Opt.some("Runtime Control events are not served to another Runtime yet"),
          )
        ),
      )
      if res.isSome:
        r.send(k[0], toMessage(LcnRchRcOut(id: k[1], frame: res.get)))
    of caUnsubscribe:
      let res = c.session.subscriptionResult(a.id, Opt.none(InvocationFailure))
      if res.isSome:
        r.send(k[0], toMessage(LcnRchRcOut(id: k[1], frame: res.get)))
    of caClose:
      r.endConn(k, c, a.close.send.get(newSeq[byte]()))

proc onFrame(
    r: RemoteRc, conns: var Table[ConnKey, Conn], trust: TrustSnapshot, m: Inbox
) =
  let msg = carrier.decodeMessage(m.body).valueOr:
    return
  type K = LcnRchMessageKind
  case msg.kind
  of K.lcn_Rch_hello_judge:
    let h = msg.arm_lcn_Rch_hello_judge
    let k = (m.run, h.id)
    let consumer = judge(trust, h, r.limits)
    if consumer.isErr:
      let f = consumer.error
      r.send(
        m.run,
        toMessage(
          LcnRchHelloRefuse(
            id: h.id, response: (if f.peer: @[] else: protocolError(f.code))
          )
        ),
      )
      return
    let response = helloResponse(r.limits)
    if response.isErr:
      r.send(
        m.run, toMessage(LcnRchHelloRefuse(id: h.id, response: protocolError(ecModule)))
      )
      return
    conns[k] = Conn(key: m.key, consumer: consumer.get, response: response.get)
    r.queue(
      Job(kind: jbAdmit, key: m.key, run: m.run, conn: h.id, consumer: consumer.get)
    )
  of K.lcn_Rch_rc_in:
    let x = msg.arm_lcn_Rch_rc_in
    let k = (m.run, x.id)
    conns.withValue(k, c):
      if c.admitted and not c.ending:
        r.act(k, c[], c.session.receive(x.frame))
  of K.lcn_Rch_conn_closed:
    let k = (m.run, msg.arm_lcn_Rch_conn_closed.id)
    var c: Conn
    if conns.pop(k, c):
      c.session.lose()
      if c.token.len > 0:
        r.queue(Job(kind: jbClosed, token: c.token))
  else:
    discard

proc sessionMain(r: RemoteRc) {.thread.} =
  var conns: Table[ConnKey, Conn]
  var trust: TrustSnapshot = nil
  let snap = LcnRchMessage.decode(r.snapshot)
  if snap.isOk and snap.get.kind == LcnRchMessageKind.lcn_Rch_snapshot:
    trust = snapshotOf(snap.get.arm_lcn_Rch_snapshot).get(nil)
  while true:
    var m: Inbox
    try:
      m = r.inbox.recv()
    except Exception:
      m = Inbox(kind: ikStop) # [IMPL] the channel's hooks: not expected
    case m.kind
    of ikStop:
      for _ in 0 ..< r.spawned:
        r.jobs.send(Job(kind: jbStop))
      for i in 0 ..< r.spawned:
        joinThread(r.workers[i])
      return
    of ikFrame:
      r.onFrame(conns, trust, m)
    of ikEnded:
      var gone: seq[ConnKey]
      for k in conns.keys:
        if k[0] == m.run:
          gone.add(k)
      for k in gone:
        var c: Conn
        if conns.pop(k, c) and c.token.len > 0:
          r.queue(Job(kind: jbClosed, token: c.token))
    of ikClose:
      for k, c in conns.mpairs:
        if c.token.len > 0 and c.token in m.tokens:
          r.endConn(k, c, [])
    of ikAdmitted:
      dec r.busy
      let k = (m.run, m.conn)
      var found = false
      conns.withValue(k, c):
        found = true
        if m.code == ecOk:
          c.token = m.token
          c.admitted = true
          c.session = calleeConn(rcBoundary(), r.limits, deferPayload = true)
          r.send(k[0], toMessage(LcnRchHelloAdmit(id: k[1], response: c.response)))
        else:
          r.send(
            k[0],
            toMessage(LcnRchHelloRefuse(id: k[1], response: protocolError(m.code))),
          )
      if found and m.code != ecOk:
        conns.del(k)
      elif not found and m.code == ecOk:
        # Ended while it was being admitted.
        r.queue(Job(kind: jbClosed, token: m.token))
    of ikDone:
      dec r.busy
      let k = (m.run, m.conn)
      conns.withValue(k, c):
        if m.closeConn:
          r.endConn(k, c[], protocolError(m.code))
        else:
          var o = RcOutcome(ok: false, failure: m.failure)
          if m.ok:
            let v = decodeCbor(m.response)
            o =
              if v.isOk:
                RcOutcome(ok: true, response: v.get)
              else:
                RcOutcome(ok: false, failure: InvocationFailure(code: ecModule))
          let bytes = c.session.respond(m.id, o)
          if bytes.isSome and not c.ending:
            r.send(k[0], toMessage(LcnRchRcOut(id: k[1], frame: bytes.get)))
          r.act(k, c[], c.session.workEnded(m.id))

# Inbound hooks (the supervision thread, or the engine's caller) -------------------------------

proc inFrame(
    data: pointer, key: seq[byte], run: uint64, body: seq[byte]
) {.nimcall, gcsafe, raises: [].} =
  cast[RemoteRc](data).inbox.send(Inbox(kind: ikFrame, key: key, run: run, body: body))

proc inEnded(
    data: pointer, key: seq[byte], run: uint64
) {.nimcall, gcsafe, raises: [].} =
  cast[RemoteRc](data).inbox.send(Inbox(kind: ikEnded, key: key, run: run))

proc inClose(data: pointer, tokens: seq[string]) {.nimcall, gcsafe, raises: [].} =
  cast[RemoteRc](data).inbox.send(Inbox(kind: ikClose, tokens: tokens))

# The handle ------------------------------------------------------------------------------

proc newRemoteRc*(e: Engine, sup: RemoteSupervisor, snapshot: seq[byte]): RemoteRc =
  ## Serves remote Runtime Control for the listeners `sup` runs, from the
  ## trust snapshot `snapshot` (one encoded `lcn.rch_snapshot`), and becomes
  ## `sup`'s inbound side. Nil when its thread cannot start.
  let r = createShared(RemoteRcObj)
  r.engine = e
  r.sup = sup
  r.snapshot = snapshot
  r.limits = defaultLimits()
  r.inbox.open()
  r.jobs.open()
  try:
    createThread(r.thread, sessionMain, r)
  except ResourceExhaustedError:
    r.inbox.close()
    r.jobs.close()
    {.cast(gcsafe).}:
      `=destroy`(r[]) # its channels are closed; nothing else shares it
    freeShared(r)
    return nil
  sup.setInbound(RemoteInbound(data: r, frame: inFrame, ended: inEnded, close: inClose))
  r

proc closeRemoteRc*(r: RemoteRc) =
  ## Every worker joined; after the supervisor's close, before the engine's.
  ## Idempotent on nil.
  if r == nil:
    return
  r.inbox.send(Inbox(kind: ikStop))
  joinThread(r.thread)
  r.inbox.close()
  r.jobs.close()
  {.cast(gcsafe).}:
    `=destroy`(r[]) # its channels are closed; nothing else shares it
  freeShared(r)

{.pop.}
