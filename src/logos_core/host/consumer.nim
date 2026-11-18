## A hosted consumer's route handles, in the Module Host (Tier 4b step 4b-3,
## part 4b-3.3; plan §2.8 [Rev R11, R15, R18]; DECISIONS G267) [IMPL].
##
## The owner's direct layout (2026-11-14): payloads go between this process
## and the provider's endpoint directly, and the Runtime stays on the control
## path. The handle's connection, its calls, subscriptions, prepared calls and
## end observer live here, and run 4b-2's caller half against the host's own
## transport loop; the Runtime decides every control step and keeps the
## handle's codes, its pin and its observer's registration (a hosted `Link`,
## `runtime/transported.nim`).
##
## - **Retained material (RUN-0174).** The binding's `establish_route` and
##   `renew_route` answers are read here before the module gets them as they
##   are: each route record with a local-transport `invocation` keeps
##   `{route → path, ticket}`, replacing an older one, whose ticket is wiped.
##   Nothing else of any answer is kept (RUN-0173, RUN-0175). The Runtime's
##   `route_ended` wipes a route's.
## - **Materialization (RUN-0177-RUN-0179).** After the direct binding's local
##   checks, the route's material is taken and the Runtime makes its §4.1
##   checks against its current state (`rc_materialize`, which says whether
##   there was material: none is NOT_AUTHORISED, K11). On a refusal the
##   material is put back, as the Runtime keeps a direct consumer's. Otherwise
##   the Runtime names the handle's link, the provider's peer uid (TRN-0187)
##   and module; the host's loop connects to the material's path, checks the
##   peer and sends the Hello with the ticket, which is wiped when the command
##   is built and in the command once it is queued (R18). The outcome goes to
##   the Runtime (`rc_link_result`), which answers as for a direct handle: a
##   peer that is not the expected identity fails the route first (K12, R15),
##   and a route that ended meanwhile gives its cause (K42).
## - **Operations.** Each call, subscribe, unsubscribe and `observe_end` is
##   admitted by the Runtime first (`rc_link_admit`), in a direct transported
##   handle's order (RUNTIME l.1343-1347); only then does it go on the
##   connection. A NOT_READY refusal validates the request first (G171). A
##   prepared call is admitted and sent from a worker once submitted; its
##   timeout, cancellation and first terminal decision are kept here as
##   `asynccall.nim` keeps them (INTERFACE l.2050-2087).
## - **Events (G178).** A subscription's Events are queued here and run on the
##   host's consumer workers, one handler at a time per subscription; each
##   Event's credit goes back once its handler returned (TRANSPORT l.721-725).
## - **Ends [R4, R11].** The Runtime's `route_ended` gives each of the route's
##   handles the route's cause and its first terminal cause; a revoked route
##   ends the calls still running (G174). The connection's own end is reported
##   (`rc_link_closed`), and the Runtime answers with the handle's first cause
##   (its route's when that came first, else TF-15's TRANSPORT_ERROR or the
##   provider's NOT_AUTHORISED). This replaces plan R11's `route_ended_ack`
##   and `route_cause`: the Runtime orders the two causes itself. An installed
##   observer runs once, on a worker, with the first cause.
## - **Release.** Subscriptions are abandoned, a running handler or observer on
##   another thread is waited for, the Runtime drops the pin and the
##   observer's registration (`rc_link_released`), and the connection closes
##   once no prepared call awaits its Response (IF l.1506).

{.push raises: [], gcsafe.}

import std/[atomics, locks, monotimes, times]
from std/os import sleep
import results
import ../abi/[checks, cstatus, types]
import ../base/[perthread, wipe]
import ../cbor/utf8
import ../hash/hashinput
import ../iface/[accept, outcome, surface]
import ../transport/io/api except decodeMessage
import ../transport/io/loop
import ../runtime/[callcheck, entryframe, hostio], ../kit/rc_types
import ./state

const
  MaxWorkers = 16 ## [IMPL] consumer handlers, observers and completions at once
  TimerStepMs = 2 ## [IMPL] the longest wait between looks at prepared calls' deadlines
  BusyStepMs = 1

# Shared text and bytes ------------------------------------------------------------------

proc sharedText(s: string): cstring =
  result = cast[cstring](allocShared0(s.len + 1))
  for i, c in s:
    result[i] = c

proc sharedBytes(b: openArray[byte]): ptr UncheckedArray[uint8] =
  if b.len == 0:
    return nil
  result = cast[ptr UncheckedArray[uint8]](allocShared(b.len))
  copyMem(result, unsafeAddr b[0], b.len)

proc freeText(p: var cstring) =
  ## [DECISIONS G276] Zeroed, then released: a failure's text may be the
  ## provider's, and may quote a payload.
  if p != nil:
    secureZero(p, p.len)
    deallocShared(p)
    p = nil

proc freeBytes(p: var ptr UncheckedArray[uint8], n: int) =
  ## [DECISIONS G276] `n` bytes: zeroed, then released.
  if p != nil:
    freeWiped(p, n)
    p = nil

proc bytesOf(p: ptr UncheckedArray[uint8], n: int): seq[byte] =
  result = newSeq[byte](n)
  if n > 0:
    copyMem(addr result[0], p, n)

proc nameBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s:
    result[i] = byte(c)

func codeOf(c: uint8): ErrorCode =
  errorCodeOf(c).get(ecModule)

func closedCodeOf(cause: CloseCause, code: ErrorCode): ErrorCode =
  ## [plan §2.6; TRANSPORT l.991, l.996; TF-15, G256] As
  ## `transported.closedCode`: a session the provider terminated with
  ## ProtocolError NOT_AUTHORISED is a known authorization failure; any other
  ## end is TRANSPORT_ERROR, never an inferred NOT_READY.
  if cause == ccPeerError and code == ecNotAuthorised: ecNotAuthorised else: ecTransport

# Retained material (RUN-0174) ----------------------------------------------------------

type MaterialObj = object
  route: cstring
  path: cstring
  ticket: RouteTicket
  next: ptr MaterialObj

var
  matLock: Lock
  materials: ptr MaterialObj

proc burn(m: ptr MaterialObj) =
  zeroMem(addr m.ticket[0], m.ticket.len)
  freeText(m.route)
  freeText(m.path)
  freeShared(m)

proc unlinkMaterialLocked(route: string): ptr MaterialObj =
  var p = addr materials
  while p[] != nil:
    if $p[].route == route:
      let m = p[]
      p[] = m.next
      m.next = nil
      return m
    p = addr p[].next
  nil

proc keepMaterial(route, path: string, ticket: openArray[byte]) =
  if ticket.len != TicketBytes or route.len == 0 or path.len == 0:
    return
  let m = createShared(MaterialObj)
  m.route = sharedText(route)
  m.path = sharedText(path)
  for i in 0 ..< TicketBytes:
    m.ticket[i] = ticket[i]
  var old: ptr MaterialObj
  withLock matLock:
    old = unlinkMaterialLocked(route)
    m.next = materials
    materials = m
  if old != nil:
    burn(old) # [IMPL] the older unused ticket expires on its own

proc keep(rec: LogosNSRuntimeControlRouteRecord) =
  if rec.invocation.isNone:
    return
  let d = rec.invocation.get
  if d.kind == LogosNSRuntimeControlInvocationDescriptorKind.Case0:
    keepMaterial(rec.route, d.arm_0.path, d.arm_0.ticket)

proc retainFrom*(bare: string, response: openArray[byte]) =
  ## [SPEC RUNTIME l.958-961; RUN-0174; plan §2.8] A successful
  ## `establish_route` or `renew_route` answer, before the module gets it.
  case bare
  of "establish_route":
    let r = LogosNSRuntimeControlEstablishRouteResponse.decode(response)
    if r.isOk:
      for rec in r.get.routes:
        keep(rec)
  of "renew_route":
    let r = LogosNSRuntimeControlRenewRouteResponse.decode(response)
    if r.isOk:
      keep(r.get.route)
  else:
    discard

proc takeMaterial(route: string): ptr MaterialObj =
  withLock matLock:
    result = unlinkMaterialLocked(route)

proc putBack(m: ptr MaterialObj) =
  ## A refused materialization leaves the material as it was, unless a newer
  ## answer replaced it meanwhile.
  var newer = false
  withLock matLock:
    var p = materials
    while p != nil:
      if $p.route == $m.route:
        newer = true
        break
      p = p.next
    if not newer:
      m.next = materials
      materials = m
  if newer:
    burn(m)

proc dropMaterial(route: string) =
  let m = takeMaterial(route)
  if m != nil:
    burn(m)

# Links ------------------------------------------------------------------------------------

type
  Outcome = object ## One wait's answer, filled by another thread under `cl`.
    done: bool
    ok: bool
    code: ErrorCode
    message: cstring ## nil: none
    detail: ptr UncheckedArray[uint8] ## nil: none
    detailLen: int
    recheck: bool ## the session refused the request locally as INVALID_PARAMS
    value: ptr UncheckedArray[uint8]
    valueLen: int

  CallWait = object
    tag: uint64
    o: ptr Outcome
    next: ptr CallWait

  QEvent = object
    name: cstring
    data: ptr UncheckedArray[uint8]
    len, credit: int
    next: ptr QEvent

  LSub = object
    id: uint64
    handler: LogosEventHandler
    userData: pointer
    outId: ptr LogosSubscriptionId
    active, paused, gone: bool
    keep: bool ## gone, and its unsubscriber frees it, not its drain
    subscribing, unsubscribing: ptr Outcome
    head, tail: ptr QEvent
    draining: bool
    runner: int ## the thread running one of its handlers; 0: none
    next: ptr LSub

  LinkPhase = enum
    lpConnecting
    lpOpen
    lpClosed

  ObserverState = enum
    obNone
    obInstalled
    obScheduled
    obRunning
    obDone
    obSuppressed

  AsyncPhase = enum
    apPrepared
    apSubmitted
    apTerminal
    apCompleting
    apDone

  HAsync = object
    link: ptr HLink
    tag: uint64 ## on the link, once sent
    sent: bool
    methodName: cstring
    params: ptr UncheckedArray[uint8]
    paramsLen: int
    hasTimeout: bool
    timeoutMs: uint64
    deadline: MonoTime
    complete: LogosAsyncCompleteFn
    userData: pointer
    phase: AsyncPhase
    cancelledEarly: bool
    o: Outcome
    completer: int
    jobs: int ## queued or running jobs that hold it
    released: bool ## the module released it; the last job frees it
    next: ptr HAsync

  HLink = object
    num: uint64 ## the Runtime's number for the handle, and the loop's ConnId
    route: cstring
    root: Digest
    schema: ptr UncheckedArray[uint8] ## the construction input, for rechecks
    schemaLen: int
    phase: LinkPhase
    connected, connectFailed: bool
    failCause: ConnectFailure
    failCode: ErrorCode
    closedKnown: bool ## the loop reported the connection's end
    closed: ErrorCode
    hasRouteCause: bool
    routeCause: ErrorCode
    hasFirst: bool ## the Runtime gave the handle's first terminal cause
    first: ErrorCode
    observer: LogosRouteEndHandler
    observerData: pointer
    obs: ObserverState
    obsRunner: int
    held: bool ## returned to the module and not released
    closeSent: bool
    calls: ptr CallWait
    subs: ptr LSub
    asyncs: ptr HAsync
    nextTag, nextSub: uint64
    refs: int ## the handle, each prepared call, each queued job
    next: ptr HLink

  JobKind = enum
    jkQuit
    jkDrain
    jkObserver
    jkComplete
    jkSubmit
    jkClosed

  Job = object
    kind: JobKind
    link: ptr HLink
    sub: ptr LSub
    call: ptr HAsync

  Workers = object
    ch: Channel[Job]
    lock: Lock
    done: Cond
    idle, count, pending: int
    threads: array[MaxWorkers, Thread[void]]

var
  cl: Lock ## every link, subscription and prepared call
  cc: Cond ## with `cl`: something a waiter waits for changed
  links: ptr HLink
  cloop: Loop ## the consumer's own transport loop, started on first use
  transportWords: ptr UncheckedArray[uint64]
  transportLen: int
  depth: int
  workers: ptr Workers
  timerOn: bool ## under `cl`
  timerMade: bool ## under `cl`: `timer` was started and not yet joined
  timerStop: bool ## under `cl`: the release ends the timer and arms no other
  timer: Thread[void]

# Workers --------------------------------------------------------------------------------

proc runJob(j: Job)

proc workerMain() {.thread.} =
  markHostThread()
  while true:
    var j: Job
    try:
      j = workers.ch.recv()
    except Exception:
      break
    if j.kind == jkQuit:
      break
    withLock workers.lock:
      dec workers.idle
    runJob(j)
    withLock workers.lock:
      inc workers.idle
      dec workers.pending
      if workers.pending == 0:
        broadcast(workers.done)
  releasePerThread()

proc post(j: Job) =
  ## Any thread: one job; the pool grows while every worker is busy.
  var grow = false
  var slot = 0
  withLock workers.lock:
    inc workers.pending
    if workers.idle == 0 and workers.count < MaxWorkers:
      grow = true
      slot = workers.count
      inc workers.count
      inc workers.idle
  if grow:
    try:
      createThread(workers.threads[slot], workerMain)
    except Exception:
      carrierLost("a consumer worker cannot start")
  try:
    workers.ch.send(j)
  except Exception:
    carrierLost("the consumer's job queue failed")

proc retainLocked(l: ptr HLink) =
  inc l.refs

proc freeLink(l: ptr HLink) =
  freeText(l.route)
  freeBytes(l.schema, l.schemaLen)
  freeShared(l)

proc dropLocked(l: ptr HLink): bool =
  ## Under `cl`: one reference goes; true when it was the last, and `l` is
  ## unlinked (the caller frees it outside the lock).
  dec l.refs
  if l.refs > 0:
    return false
  var p = addr links
  while p[] != nil:
    if p[] == l:
      p[] = l.next
      break
    p = addr p[].next
  true

proc dropLink(l: ptr HLink) =
  var last: bool
  withLock cl:
    last = dropLocked(l)
  if last:
    freeLink(l)

proc findLocked(num: uint64): ptr HLink =
  var p = links
  while p != nil:
    if p.num == num:
      return p
    p = p.next
  nil

# Commands ---------------------------------------------------------------------------------

proc submitCmd(cmd: var IoCommand): SubmitResult =
  ## Waits while the loop's output budget is full; never on the I/O thread.
  if cloop == nil:
    return sbStopped
  while true:
    result = cloop.trySubmit(cmd)
    if result != sbBusy:
      return
    sleep(BusyStepMs)

proc release(l: ptr HLink, credit: int) =
  ## [SPEC TRANSPORT l.721-725] An Event's bytes are done with.
  if credit > 0 and cloop != nil:
    var cmd =
      IoCommand(conn: l.num, kind: IoCommandKind.cmdRelease, releaseBytes: credit)
    discard cloop.trySubmit(cmd)

proc closeLocked(l: ptr HLink) =
  ## Under `cl`: the connection goes, once.
  if l.phase != lpClosed and not l.closeSent and cloop != nil:
    l.closeSent = true
    var cmd = IoCommand(conn: l.num, kind: IoCommandKind.cmdClose)
    discard cloop.trySubmit(cmd)

# Outcomes ---------------------------------------------------------------------------------

proc newOutcome(): ptr Outcome =
  createShared(Outcome)

proc freeOutcome(o: ptr Outcome) =
  freeText(o.message)
  freeBytes(o.detail, o.detailLen)
  freeBytes(o.value, o.valueLen)
  freeShared(o)

proc setFailure(o: ptr Outcome, f: InvocationFailure) =
  ## [SPEC INTERFACE §5.1, §5.2] A failure as it came: its code, and its
  ## message and detail only when it has them, as a direct transported
  ## handle gives them (`transported.nim`).
  o.done = true
  o.ok = false
  o.code = f.code
  if f.message.isSome:
    o.message = sharedText(clip(f.message.get))
  if f.detail.isSome:
    o.detail = sharedBytes(f.detail.get)
    o.detailLen = f.detail.get.len

proc failLocked(o: ptr Outcome, f: InvocationFailure) =
  if o == nil or o.done:
    return
  o.setFailure(f)

proc failLocked(o: ptr Outcome, code: ErrorCode, message: string) =
  o.failLocked(InvocationFailure(code: code, message: Opt.some(message)))

proc succeedLocked(o: ptr Outcome, value: openArray[byte]) =
  if o == nil or o.done:
    return
  o.done = true
  o.ok = true
  o.value = sharedBytes(value)
  o.valueLen = value.len

proc waitFor(o: ptr Outcome) =
  withLock cl:
    while not o.done:
      wait(cc, cl)

proc failureOf(o: ptr Outcome): InvocationFailure =
  ## A copy of the failure, which the caller wipes [DECISIONS G276].
  result = InvocationFailure(code: o.code)
  if o.message != nil:
    result.message = Opt.some($o.message)
  if o.detail != nil:
    result.detail = Opt.some(bytesOf(o.detail, o.detailLen))

# The Runtime's admission ------------------------------------------------------------------

proc admit(l: ptr HLink, op: uint8, name: string): Answer =
  ## [SPEC RUNTIME §4.1, l.1343-1347] One operation through the handle, before
  ## anything goes on its connection; the connection's end not reported yet
  ## goes with it.
  var closed = Opt.none(uint8)
  withLock cl:
    if l.closedKnown:
      closed = Opt.some(uint8(ord(l.closed)))
  let id = nextId()
  request(
    toMessage(
      LcnCarrierRcLinkAdmit(
        id: id,
        link: l.num,
        op: op,
        name: (if name.len > 0: Opt.some(nameBytes(name))
        else: Opt.none(seq[byte])),
        closed: closed,
      )
    ),
    id,
  )

proc recheck(
    l: ptr HLink, bare: string, params: openArray[byte], f: InvocationFailure
): InvocationFailure =
  ## [G171 interim (TF-18); I90] A call refused NOT_READY is validated before
  ## readiness is reported, and one the session refused as INVALID_PARAMS
  ## gets its detail, under the route's selected contract.
  if f.code notin {ecNotReady, ecInvalidParams}:
    return f
  let sel = buildSelected(bytesOf(l.schema, l.schemaLen), l.root, depth)
  if sel.isErr:
    return f
  let r = checkRequest(sel.get, bare, params)
  if r.isErr:
    return r.error
  if sel.get.marked(bare).request:
    wipe(r.get) # [DECISIONS G276]
  f

# Ends ---------------------------------------------------------------------------------

proc scheduleObserverLocked(l: ptr HLink) =
  ## Under `cl`: an installed observer runs once, with the first cause.
  if l.obs == obInstalled and l.hasFirst:
    l.obs = obScheduled
    retainLocked(l)
    post(Job(kind: jkObserver, link: l))

proc decideLocked(c: ptr HAsync, f: InvocationFailure): bool =
  ## [SPEC INTERFACE l.2065-2071] The first terminal decision wins.
  if c.phase != apSubmitted:
    return false
  c.phase = apTerminal
  (addr c.o).setFailure(f)
  true

proc decideLocked(c: ptr HAsync, code: ErrorCode, message: string): bool =
  c.decideLocked(InvocationFailure(code: code, message: Opt.some(message)))

proc decideOkLocked(c: ptr HAsync, value: openArray[byte]): bool =
  if c.phase != apSubmitted:
    return false
  c.phase = apTerminal
  c.o.done = true
  c.o.ok = true
  c.o.value = sharedBytes(value)
  c.o.valueLen = value.len
  true

proc completeLater(c: ptr HAsync) =
  ## Never under `cl`.
  withLock cl:
    inc c.jobs
  post(Job(kind: jkComplete, call: c))

proc freeAsync(c: ptr HAsync) =
  freeText(c.methodName)
  freeBytes(c.params, c.paramsLen)
  freeText(c.o.message)
  freeBytes(c.o.detail, c.o.detailLen)
  freeBytes(c.o.value, c.o.valueLen)
  freeShared(c)

proc jobDone(c: ptr HAsync) =
  ## A job that held `c` ended; a released call goes with its last one, and
  ## its reference to the handle with it.
  let l = c.link
  var free = false
  var last = false
  withLock cl:
    dec c.jobs
    if c.released and c.jobs == 0:
      free = true
      last = dropLocked(l)
    broadcast(cc)
  if free:
    freeAsync(c)
  if last:
    freeLink(l)

proc endSubsLocked(l: ptr HLink, code: ErrorCode) =
  ## [SPEC INTERFACE l.1462-1465; TRANSPORT l.596-599] The handle's path
  ## ended: no handler begins from now on and undelivered Events go; a
  ## subscribe still waiting fails with `code`, an unsubscribe still waiting
  ## gets `code` and its subscription stays, inactive, until the release.
  var p = addr l.subs
  while p[] != nil:
    let s = p[]
    s.active = false
    while s.head != nil:
      let e = s.head
      s.head = e.next
      release(l, e.credit)
      freeText(e.name)
      freeBytes(e.data, e.len)
      freeShared(e)
    s.tail = nil
    if s.unsubscribing != nil:
      s.unsubscribing.failLocked(code, "the handle's path ended")
      s.unsubscribing = nil
    if s.subscribing != nil:
      s.subscribing.failLocked(code, "the handle's path ended")
      s.subscribing = nil
      p[] = s.next
      if s.draining:
        s.gone = true
      else:
        freeShared(s)
      continue
    p = addr s.next

proc routeEnded*(m: LcnCarrierRouteEnded) =
  ## Main thread: [plan §2.8 steps 1-2] a route the consumer holds ended. Its
  ## retained ticket goes; each of its handles takes the route's cause, which
  ## its subscriptions end with, and its first terminal cause; a revoked
  ## route ends the calls still running through them (G174).
  dropMaterial(m.route)
  let code = codeOf(m.code)
  var done: seq[ptr HAsync]
  withLock cl:
    for f in m.links:
      let l = findLocked(f.link)
      if l == nil:
        continue
      l.hasRouteCause = true
      l.routeCause = code
      if not l.hasFirst:
        l.hasFirst = true
        l.first = codeOf(f.first)
      endSubsLocked(l, code)
      if m.revoked:
        var c = l.asyncs
        while c != nil:
          if c.decideLocked(ecNotAuthorised, "the route was revoked"):
            done.add(c)
          c = c.next
      scheduleObserverLocked(l)
    broadcast(cc)
  for c in done:
    completeLater(c)

proc reportClosed(l: ptr HLink) =
  ## A worker: [Rev R4] the connection's end goes to the Runtime, which
  ## answers with the handle's first terminal cause.
  var code: ErrorCode
  withLock cl:
    code = l.closed
  let id = nextId()
  let a = request(
    toMessage(LcnCarrierRcLinkClosed(id: id, link: l.num, code: uint8(ord(code)))), id
  )
  withLock cl:
    if not l.hasFirst and not a.failed and a.hasCode:
      l.hasFirst = true
      l.first = codeOf(a.code8)
    scheduleObserverLocked(l)
    broadcast(cc)

# The loop's events --------------------------------------------------------------------

proc onResponse(
    l: ptr HLink,
    tag: uint64,
    o: CallOutcome,
    local: bool,
    localCode: ErrorCode,
    localMsg: string,
): ptr HAsync =
  ## Under `cl`: a call's terminal outcome; the prepared call it decided, if
  ## any. [plan §2.6 step 3; G22] A Request the session refused locally with
  ## NOT_READY gives the handle's code.
  var code = localCode
  if local and code == ecNotReady:
    code =
      if l.hasRouteCause:
        l.routeCause
      elif l.hasFirst:
        l.first
      else:
        ecTransport
  var p = addr l.calls
  while p[] != nil:
    let w = p[]
    if w.tag == tag:
      p[] = w.next
      if local:
        w.o.failLocked(code, localMsg)
        w.o.recheck = code == ecInvalidParams
      elif o.ok:
        w.o.succeedLocked(o.result)
      else:
        w.o.failLocked(o.failure)
      freeShared(w)
      return nil
    p = addr w.next
  var c = l.asyncs
  while c != nil:
    if c.sent and c.tag == tag:
      let won =
        if local:
          c.decideLocked(code, localMsg)
        elif o.ok:
          c.decideOkLocked(o.result)
        else:
          c.decideLocked(o.failure)
      if won:
        c.o.recheck = local and code == ecInvalidParams
        return c
      return nil
    c = c.next
  nil

proc onSubscription(l: ptr HLink, ev: IoEvent) =
  ## Under `cl`: [SPEC TRANSPORT §5.1; plan §2.7, Rev R6, R7] the provider's
  ## result for a Subscribe or an Unsubscribe.
  var p = addr l.subs
  while p[] != nil:
    let s = p[]
    if s.id != ev.subscriptionId:
      p = addr s.next
      continue
    let f = ev.subscriptionFailure
    if ev.subscriptionOp == MessageKind.mkSubscribe:
      let o = s.subscribing
      if o == nil:
        return
      s.subscribing = nil
      if f.isNone and not l.hasRouteCause and l.phase == lpOpen:
        # [SPEC INTERFACE l.1427-1429; Rev R7] The id is written, then the
        # subscription is active, before the subscriber returns.
        s.outId[] = LogosSubscriptionId(s.id)
        s.active = true
        o.done = true
        o.ok = true
        return
      p[] = s.next
      freeShared(s)
      if f.isSome:
        o.failLocked(f.get.code, f.get.message.get("the subscription was refused"))
      else:
        o.failLocked(
          (if l.hasRouteCause: l.routeCause else: ecTransport),
          "the handle's path ended",
        )
    else:
      let o = s.unsubscribing
      if o == nil:
        return
      s.unsubscribing = nil
      if f.isNone:
        s.active = false
        while s.head != nil:
          let e = s.head
          s.head = e.next
          release(l, e.credit)
          freeText(e.name)
          freeBytes(e.data, e.len)
          freeShared(e)
        s.tail = nil
        p[] = s.next
        s.gone = true
        s.keep = true # the unsubscriber frees it (`routeUnsubscribeOp`)
        o.done = true
        o.ok = true
        return
      s.paused = false
      o.failLocked(f.get.code, f.get.message.get("the unsubscription was refused"))
      if s.head != nil and s.active and not s.draining:
        s.draining = true
        retainLocked(l)
        post(Job(kind: jkDrain, link: l, sub: s))
    return

proc onEvent(l: ptr HLink, ev: sink IoEvent) =
  ## Under `cl`: [SPEC RUNTIME l.1184; plan §2.7] an Event, queued while its
  ## subscription is active (also while an Unsubscribe is pending, in case it
  ## fails); otherwise its bytes go back at once.
  var s = l.subs
  while s != nil and s.id != ev.eventSub:
    s = s.next
  if s == nil or not s.active or l.hasRouteCause:
    release(l, ev.credit)
    return
  let e = createShared(QEvent)
  e.name = sharedText(ev.eventName)
  e.data = sharedBytes(ev.eventData)
  e.len = ev.eventData.len
  e.credit = ev.credit
  if s.tail == nil:
    s.head = e
  else:
    s.tail.next = e
  s.tail = e
  if not s.paused and not s.draining:
    s.draining = true
    retainLocked(l)
    post(Job(kind: jkDrain, link: l, sub: s))

proc onClosed(l: ptr HLink, ev: IoEvent): seq[ptr HAsync] =
  ## Under `cl`: [plan §2.6, §2.8 step 5] the connection ended. Calls still
  ## awaiting it were answered TRANSPORT_ERROR by the loop first (T l.543).
  l.phase = lpClosed
  l.closedKnown = true
  l.closed = closedCodeOf(ev.cause, ev.code)
  while l.calls != nil:
    let w = l.calls
    l.calls = w.next
    w.o.failLocked(ecTransport, "the connection closed")
    freeShared(w)
  var c = l.asyncs
  while c != nil:
    if c.sent and c.decideLocked(ecTransport, "the connection closed"):
      result.add(c)
    c = c.next
  endSubsLocked(l, (if l.hasRouteCause: l.routeCause else: l.closed))
  if l.held:
    retainLocked(l)
    post(Job(kind: jkClosed, link: l))

proc consumerEvent(ev: sink IoEvent, ctx: pointer) {.nimcall, gcsafe, raises: [].} =
  ## I/O thread: one event of a handle's connection; never blocks.
  ## [DECISIONS G276] A Response's result is copied into its outcome: the
  ## event's is wiped, as is a failure's text.
  var ev = ev
  defer:
    wipe(ev)
  var done: seq[ptr HAsync]
  withLock cl:
    let l = findLocked(ev.conn)
    if l == nil:
      if ev.kind == IoEventKind.evEvent and cloop != nil:
        var cmd = IoCommand(
          conn: ev.conn, kind: IoCommandKind.cmdRelease, releaseBytes: ev.credit
        )
        discard cloop.trySubmit(cmd)
      return
    case ev.kind
    of IoEventKind.evConnected:
      l.connected = true
    of IoEventKind.evConnectFailed:
      l.connectFailed = true
      l.failCause = ev.failCause
      l.failCode = ev.failCode
      l.phase = lpClosed
    of IoEventKind.evResponse:
      let c = l.onResponse(ev.tag, ev.outcome, false, ecOk, "")
      if c != nil:
        done.add(c)
    of IoEventKind.evLocalFailure:
      let c = l.onResponse(ev.localTag, CallOutcome(), true, ev.localCode, ev.localMsg)
      if c != nil:
        done.add(c)
    of IoEventKind.evClosed:
      done = l.onClosed(ev)
    of IoEventKind.evSubscription:
      l.onSubscription(ev)
    of IoEventKind.evEvent:
      l.onEvent(ev)
    else:
      discard
    broadcast(cc)
  for c in done:
    completeLater(c)

# Jobs ------------------------------------------------------------------------------------

proc runDrain(l: ptr HLink, s: ptr LSub) =
  ## [G178] One subscription's Events, in order, one handler at a time.
  let me = getThreadId()
  while true:
    var e: ptr QEvent
    withLock cl:
      if s.gone or not s.active or s.paused or l.hasRouteCause or s.head == nil:
        s.draining = false
        if s.gone and not s.keep:
          freeShared(s)
        broadcast(cc)
        return
      e = s.head
      s.head = e.next
      if s.head == nil:
        s.tail = nil
      s.runner = me
    s.handler(e.name, (if e.len == 0: nil else: e.data), csize_t(e.len), s.userData)
    withLock cl:
      s.runner = 0
      broadcast(cc)
    release(l, e.credit)
    freeText(e.name)
    freeBytes(e.data, e.len)
    freeShared(e)

proc runObserver(l: ptr HLink) =
  ## [SPEC INTERFACE l.1486-1490] The handle's end handler, once, unless the
  ## release suppressed it.
  var run = false
  var code: ErrorCode
  withLock cl:
    if l.obs == obScheduled:
      l.obs = obRunning
      l.obsRunner = getThreadId()
      run = true
      code = l.first
  if run:
    l.observer(CErrorCode(ord(code)), l.observerData)
    withLock cl:
      l.obs = obDone
      l.obsRunner = 0
      broadcast(cc)

type Owned = object
  ## A completion's response, message and detail, released by its owner.
  response: ptr UncheckedArray[uint8]
  responseLen: int
  message: cstring
  detail: ptr UncheckedArray[uint8]
  detailLen: int

proc ownedRelease(state: pointer) {.cdecl.} =
  ## [DECISIONS G276] Each copy is zeroed, then freed.
  let o = cast[ptr Owned](state)
  if o == nil:
    return
  secureZero(o.response, o.responseLen)
  cFree(o.response)
  if o.message != nil:
    secureZero(o.message, o.message.len)
  cFree(o.message)
  secureZero(o.detail, o.detailLen)
  cFree(o.detail)
  cFree(o)

proc runCompletion(c: ptr HAsync) =
  ## [SPEC INTERFACE l.2053-2058, l.2089-2097] The call's one completion; its
  ## response owner frees a copy of its own.
  var go = false
  withLock cl:
    if c.phase == apTerminal:
      c.phase = apCompleting
      c.completer = getThreadId()
      go = true
  if not go:
    return
  let o = cast[ptr Owned](cMalloc(csize_t(sizeof(Owned))))
  o[] = Owned()
  var res = LogosResult()
  var response: ptr UncheckedArray[uint8] = nil
  var len: csize_t = 0
  if c.o.ok:
    o.response = cast[ptr UncheckedArray[uint8]](cMalloc(csize_t(max(c.o.valueLen, 1))))
    o.responseLen = max(c.o.valueLen, 1)
    if c.o.valueLen > 0:
      copyMem(o.response, c.o.value, c.o.valueLen)
    response = o.response
    len = csize_t(c.o.valueLen)
  else:
    # [DECISIONS G276] The failure's copies are wiped once copied out.
    var f = failureOf(addr c.o)
    if c.o.recheck:
      var params = bytesOf(c.params, c.paramsLen)
      var g = c.link.recheck($c.methodName, params, f)
      wipe(params)
      wipe(f)
      f = move g
    res.code = CErrorCode(ord(f.code))
    if f.message.isSome:
      var t = clip(f.message.get)
      o.message = cast[cstring](cMalloc(csize_t(t.len + 1)))
      for i, ch in t:
        o.message[i] = ch
      o.message[t.len] = '\0'
      res.message = o.message
      wipe(t)
    # [SPEC INTERFACE §5.1] As `status` and the Runtime's completions
    # (`asynccall.nim`): an INVALID_PARAMS detail within the bound.
    if f.code == ecInvalidParams and f.detail.isSome and f.detail.get.len > 0 and
        f.detail.get.len <= MaxDetailBytes:
      let n = f.detail.get.len
      o.detail = cast[ptr UncheckedArray[uint8]](cMalloc(csize_t(n)))
      o.detailLen = n
      copyMem(o.detail, addr f.detail.get[0], n)
      res.detail = o.detail
      res.detailLen = csize_t(n)
    wipe(f)
  c.complete(
    c.userData, res, response, len, LogosResponseOwner(state: o, release: ownedRelease)
  )
  withLock cl:
    c.phase = apDone
    c.completer = 0
    broadcast(cc)

proc runSubmit(c: ptr HAsync) =
  ## [plan §2.6; I90] A submitted call through the handle: admitted as a
  ## synchronous one, then sent; its Response decides it.
  let l = c.link
  withLock cl:
    if c.phase != apSubmitted:
      return
  let bare = $c.methodName
  var params = bytesOf(c.params, c.paramsLen)
  defer:
    wipe(params) # [DECISIONS G276]
  let a = l.admit(0, bare)
  if a.failed:
    let f = l.recheck(bare, params, failureOf(a))
    var won: bool
    withLock cl:
      won = c.decideLocked(f)
    if won:
      completeLater(c)
    return
  var cmd: IoCommand
  withLock cl:
    if c.phase != apSubmitted:
      return
    inc l.nextTag
    c.tag = l.nextTag
    c.sent = true
    cmd = IoCommand(
      conn: l.num,
      kind: IoCommandKind.cmdCall,
      tag: c.tag,
      methodName: bare,
      params: move params,
    )
  let sent = submitCmd(cmd)
  wipe(cmd) # [DECISIONS G276] not queued
  if sent != sbOk:
    var won: bool
    withLock cl:
      c.sent = false
      won = c.decideLocked(ecNotReady, "the transport is stopping")
    if won:
      completeLater(c)

proc runJob(j: Job) =
  case j.kind
  of jkDrain:
    runDrain(j.link, j.sub)
    dropLink(j.link)
  of jkObserver:
    runObserver(j.link)
    dropLink(j.link)
  of jkClosed:
    reportClosed(j.link)
    dropLink(j.link)
  of jkComplete:
    runCompletion(j.call)
    jobDone(j.call)
  of jkSubmit:
    runSubmit(j.call)
    jobDone(j.call)
  of jkQuit:
    discard

# Timeouts ----------------------------------------------------------------------------------

proc timerMain() {.thread.} =
  ## [SPEC INTERFACE l.2059-2063] Measured from submission, monotonic.
  while true:
    var done: seq[ptr HAsync]
    var cancels: seq[(uint64, uint64)]
    var any = false
    withLock cl:
      if timerStop:
        timerOn = false
        return
      let now = getMonoTime()
      var l = links
      while l != nil:
        var c = l.asyncs
        while c != nil:
          if c.phase == apSubmitted and c.hasTimeout:
            if now >= c.deadline:
              if c.decideLocked(ecTimeout, "the call timed out"):
                done.add(c)
                if c.sent and l.phase == lpOpen:
                  cancels.add((l.num, c.tag))
            else:
              any = true
          c = c.next
        l = l.next
      if not any and done.len == 0:
        timerOn = false
        return
    for (num, tag) in cancels:
      var cmd = IoCommand(conn: num, kind: IoCommandKind.cmdCancel, callTag: tag)
      discard submitCmd(cmd)
    for c in done:
      completeLater(c)
    sleep(TimerStepMs)

proc armTimerLocked() =
  if timerOn or timerStop:
    return
  if timerMade:
    # The previous timer returned once it had nothing to watch: it is joined
    # (it needs `cl` no more).
    joinThread(timer)
  timerOn = true
  timerMade = true
  try:
    createThread(timer, timerMain)
  except Exception:
    carrierLost("the consumer's timer cannot start")

# Prepared calls through a handle -----------------------------------------------------------

proc callOf(call: ptr LogosAsyncCall): ptr HAsync =
  if call == nil:
    nil
  else:
    cast[ptr HAsync](call.state)

proc submitOp(call: ptr LogosAsyncCall) {.cdecl.} =
  ## [SPEC INTERFACE l.2050-2063] Once; it only posts.
  bindingEnter()
  let c = callOf(call)
  if c == nil:
    return
  var post = false
  var decided = false
  withLock cl:
    if c.phase != apPrepared:
      return
    c.phase = apSubmitted
    if c.hasTimeout:
      let ms = int64(min(c.timeoutMs, uint64(high(int64) div 2_000_000)))
      c.deadline = getMonoTime() + initDuration(milliseconds = ms)
    if c.cancelledEarly:
      decided = c.decideLocked(ecCancelled, "the call was cancelled")
    elif c.hasTimeout and c.timeoutMs == 0:
      # [SPEC INTERFACE l.2061] Expires at once, without dispatch.
      decided = c.decideLocked(ecTimeout, "the call timed out")
    else:
      post = true
      inc c.jobs
      if c.hasTimeout:
        armTimerLocked()
  if decided:
    completeLater(c)
  elif post:
    post(Job(kind: jkSubmit, call: c))

proc cancelSent(c: ptr HAsync) =
  ## [IFC-0729; TRANSPORT §3.4] A sent call cancelled: Cancel on its link; its
  ## late Response is discarded.
  var cmd: IoCommand
  var go = false
  withLock cl:
    if c.sent and c.link.phase == lpOpen:
      cmd = IoCommand(conn: c.link.num, kind: IoCommandKind.cmdCancel, callTag: c.tag)
      go = true
  if go:
    discard submitCmd(cmd)

proc cancelOp(call: ptr LogosAsyncCall) {.cdecl.} =
  ## [SPEC INTERFACE l.2065-2071] CANCELLED unless a terminal outcome exists;
  ## before submission it is recorded.
  bindingEnter()
  let c = callOf(call)
  if c == nil:
    return
  var won = false
  withLock cl:
    case c.phase
    of apPrepared:
      c.cancelledEarly = true
    of apSubmitted:
      won = c.decideLocked(ecCancelled, "the call was cancelled")
    else:
      discard
  if won:
    cancelSent(c)
    completeLater(c)

proc releaseOp(call: ptr LogosAsyncCall) {.cdecl.} =
  ## [SPEC INTERFACE l.2079-2087] An unsubmitted call is discarded; a submitted
  ## one is cancelled if it has no terminal outcome, and its completion is
  ## waited for, except from inside it.
  bindingEnter()
  let c = callOf(call)
  if c == nil:
    return
  let me = getThreadId()
  var won = false
  withLock cl:
    case c.phase
    of apPrepared:
      c.phase = apDone
    of apSubmitted:
      won = c.decideLocked(ecCancelled, "the call was released")
    else:
      discard
  if won:
    cancelSent(c)
    completeLater(c)
  let l = c.link
  var free = false
  var last = false
  withLock cl:
    while c.phase in {apTerminal, apCompleting} and c.completer != me:
      wait(cc, cl)
    var p = addr l.asyncs
    while p[] != nil:
      if p[] == c:
        p[] = c.next
        break
      p = addr p[].next
    # [Rev R5] A released handle's connection closes once no prepared call
    # awaits its Response.
    if not l.held and l.asyncs == nil:
      closeLocked(l)
    # A job still holding it (its own completion, when released from inside
    # it, or a submission still waiting for its admission) frees it last.
    c.released = true
    if c.jobs == 0:
      free = true
      last = dropLocked(l)
  if free:
    freeAsync(c)
  if last:
    freeLink(l)

var asyncVtable = LogosAsyncCallVtable(
  abiVersion: AsyncCallAbiVersion,
  structSize: csize_t(sizeof(LogosAsyncCallVtable)),
  submit: submitOp,
  cancel: cancelOp,
  release: releaseOp,
)

# The route handle's vtable ------------------------------------------------------------------

proc linkOf(route: ptr LogosRouteHandle): ptr HLink =
  if route == nil:
    nil
  else:
    cast[ptr HLink](route.state)

proc nullRoute(): LogosResult =
  ## [IMPL] Direct code reads a null handle's state; here it is refused.
  status(ecInvalidParams, "a null route handle")

proc routeCallOp(
    route: ptr LogosRouteHandle,
    `method`: cstring,
    params: ptr UncheckedArray[uint8],
    paramsLen: csize_t,
    outBuf: ptr ptr UncheckedArray[uint8],
    outLen: ptr csize_t,
): LogosResult {.cdecl.} =
  ## [SPEC INTERFACE §5.2; RUNTIME §4.1 l.1732; plan §2.6] As
  ## `bindings.routeCallOp` and `transported.linkCall`: admitted by the
  ## Runtime, sent on the handle's connection, answered by its Response.
  bindingEnter()
  if outBuf == nil or outLen == nil:
    return status(ecInvalidParams, "null response outputs")
  outBuf[] = nil
  outLen[] = 0
  if `method` == nil or params == nil or paramsLen == 0:
    return status(ecInvalidParams, "null method or empty request")
  let l = linkOf(route)
  if l == nil:
    return nullRoute()
  let bare = $`method`
  # [DECISIONS G276] The request copies, the response copy and a failure's
  # text are zeroed once handed on, on every exit.
  var bytes = view(params, paramsLen)
  defer:
    wipe(bytes)
  let a = l.admit(0, bare)
  if a.failed:
    return status(l.recheck(bare, bytes, failureOf(a)))
  let o = newOutcome()
  let w = createShared(CallWait)
  w.o = o
  var cmd: IoCommand
  withLock cl:
    inc l.nextTag
    w.tag = l.nextTag
    w.next = l.calls
    l.calls = w
    cmd = IoCommand(
      conn: l.num,
      kind: IoCommandKind.cmdCall,
      tag: w.tag,
      methodName: bare,
      params: bytes,
    )
  let sent = submitCmd(cmd)
  wipe(cmd)
  if sent != sbOk:
    withLock cl:
      var p = addr l.calls
      while p[] != nil:
        if p[] == w:
          p[] = w.next
          freeShared(w)
          break
        p = addr p[].next
      o.failLocked(ecNotReady, "the transport is stopping")
  waitFor(o)
  if o.ok:
    var value = bytesOf(o.value, o.valueLen)
    result = give(value, outBuf, outLen)
    wipe(value)
  else:
    var f = failureOf(o)
    if o.recheck:
      var g = l.recheck(bare, bytes, f)
      wipe(f)
      f = move g
    result = status(f)
    wipe(f)
  freeOutcome(o)

proc routeReleaseResponseOp(
    route: ptr LogosRouteHandle, response: ptr UncheckedArray[uint8], len: csize_t
) {.cdecl.} =
  releaseGiven(response) # [DECISIONS G276]

proc routeSubscribeOp(
    route: ptr LogosRouteHandle,
    eventName: cstring,
    handler: LogosEventHandler,
    userData: pointer,
    outId: ptr LogosSubscriptionId,
): LogosResult {.cdecl.} =
  ## [SPEC INTERFACE §2.5 l.1417-1432; RUNTIME l.1018-1024; plan §2.7] As
  ## `events.linkSubscribe`: LOGOS_OK only after the provider's successful
  ## SubscriptionResult, with `*outId` written and the subscription active.
  bindingEnter()
  if handler.isNil or outId == nil:
    return status(ecInvalidParams, "a null handler or subscription output")
  let name = checkEventName(eventName).valueOr:
    return status(error)
  let l = linkOf(route)
  if l == nil:
    return nullRoute()
  let a = l.admit(1, name)
  if a.failed:
    return status(failureOf(a))
  let o = newOutcome()
  let s = createShared(LSub)
  s.handler = handler
  s.userData = userData
  s.outId = outId
  s.subscribing = o
  var cmd: IoCommand
  withLock cl:
    inc l.nextSub
    s.id = l.nextSub
    s.next = l.subs
    l.subs = s
    cmd = IoCommand(
      conn: l.num, kind: IoCommandKind.cmdSubscribe, subId: s.id, subEvent: name
    )
  if submitCmd(cmd) != sbOk:
    withLock cl:
      if s.subscribing != nil:
        var p = addr l.subs
        while p[] != nil:
          if p[] == s:
            p[] = s.next
            freeShared(s)
            break
          p = addr p[].next
        o.failLocked(ecNotReady, "the transport is stopping")
  waitFor(o)
  result = (if o.ok: LogosResult() else: status(failureOf(o)))
  freeOutcome(o)

proc routeUnsubscribeOp(
    route: ptr LogosRouteHandle, id: LogosSubscriptionId
): LogosResult {.cdecl.} =
  ## [SPEC INTERFACE §2.5 l.1446-1459; plan §2.7] As `events.linkUnsubscribe`:
  ## LOGOS_OK once the provider confirmed it, the subscription is inactive and
  ## no handler of it runs on another thread.
  bindingEnter()
  let l = linkOf(route)
  if l == nil:
    return nullRoute()
  let a = l.admit(2, "")
  if a.failed:
    return status(failureOf(a))
  let o = newOutcome()
  var s: ptr LSub
  withLock cl:
    var p = l.subs
    while p != nil:
      if p.id == uint64(id) and p.active and not p.paused:
        s = p
        break
      p = p.next
    if s != nil:
      s.paused = true
      s.unsubscribing = o
  if s == nil:
    freeOutcome(o)
    return status(ecInvalidParams, "no active subscription of this handle has that id")
  var cmd = IoCommand(conn: l.num, kind: IoCommandKind.cmdUnsubscribe, subId: s.id)
  if submitCmd(cmd) != sbOk:
    withLock cl:
      if s.unsubscribing == o:
        s.unsubscribing = nil
        s.paused = false
        o.failLocked(ecNotReady, "the transport is stopping")
  waitFor(o)
  if o.ok:
    # Gone from the handle: no handler of it runs on another thread when this
    # returns; one running on this thread keeps it until it returns.
    let me = getThreadId()
    var free = false
    withLock cl:
      while s.runner != 0 and s.runner != me:
        wait(cc, cl)
      if s.runner == me:
        s.keep = false # its drain frees it once this handler returned
      else:
        while s.draining:
          wait(cc, cl)
        free = true
    if free:
      freeShared(s)
    result = LogosResult()
  else:
    result = status(failureOf(o))
  freeOutcome(o)

proc routePrepareCallOp(
    route: ptr LogosRouteHandle,
    `method`: cstring,
    params: ptr UncheckedArray[uint8],
    paramsLen: csize_t,
    options: ptr LogosAsyncOptions,
    callbacks: ptr LogosAsyncCallbacks,
    outCall: ptr LogosAsyncCall,
): LogosResult {.cdecl.} =
  ## [SPEC INTERFACE §2.9.1 l.2035-2048, §5.2 l.3901-3911] As
  ## `asynccall.prepare`: copies what the call keeps and runs nothing; the
  ## admission is at submission. [Rev R5] It keeps the handle's connection.
  bindingEnter()
  if outCall == nil:
    return status(ecInvalidParams, "a null call output")
  if `method` == nil:
    return status(ecInvalidParams, "a null method")
  if params == nil or paramsLen == 0:
    return status(ecInvalidParams, "a null or empty request")
  checkAsyncOptions(options).isOkOr:
    return status(error)
  checkAsyncCallbacks(callbacks).isOkOr:
    return status(error)
  let l = linkOf(route)
  if l == nil:
    return nullRoute()
  let c = createShared(HAsync)
  c.link = l
  c.methodName = sharedText($`method`)
  c.params = sharedBytes(params.toOpenArray(0, int(paramsLen) - 1))
  c.paramsLen = int(paramsLen)
  c.hasTimeout = options.hasTimeout
  c.timeoutMs = options.timeoutMs
  c.complete = callbacks.complete
  c.userData = callbacks.userData
  withLock cl:
    retainLocked(l)
    c.next = l.asyncs
    l.asyncs = c
  outCall.vtable = addr asyncVtable
  outCall.state = c
  LogosResult()

proc routeObserveEndOp(
    route: ptr LogosRouteHandle, handler: LogosRouteEndHandler, userData: pointer
): LogosResult {.cdecl.} =
  ## [SPEC INTERFACE §2.5 l.1474-1497] Installed in order with termination by
  ## the Runtime, which keeps the registration's capacity (I86); an already
  ## terminal handle returns its first cause and installs nothing.
  bindingEnter()
  if handler.isNil:
    return status(ecInvalidParams, "a null handler")
  let l = linkOf(route)
  if l == nil:
    return nullRoute()
  # The Runtime refuses a terminal handle with its first cause before a
  # second observer (INVALID_PARAMS), as for a direct handle.
  let a = l.admit(3, "")
  if a.failed:
    return status(failureOf(a))
  withLock cl:
    l.observer = handler
    l.observerData = userData
    l.obs = obInstalled
    # A cause the Runtime gave after it installed this one, which reached
    # this host before its answer did.
    scheduleObserverLocked(l)
  LogosResult()

proc routeReleaseOp(route: ptr LogosRouteHandle) {.cdecl.} =
  ## [SPEC INTERFACE §2.5 l.1461-1468, l.1503-1506, §5.2 l.3895-3897] As
  ## `bindings.routeReleaseOp`: subscriptions abandoned, no callback begins
  ## after the release, one running on another thread is waited for; the
  ## logical route and the calls prepared through the handle stay.
  bindingEnter()
  let l = linkOf(route)
  if l == nil:
    return
  let me = getThreadId()
  var abandon: seq[uint64]
  var gone: seq[ptr LSub]
  withLock cl:
    if not l.held:
      return
    l.held = false
    if l.obs == obScheduled or l.obs == obInstalled:
      l.obs = obSuppressed
    while l.obs == obRunning and l.obsRunner != me:
      wait(cc, cl)
    while l.subs != nil:
      let s = l.subs
      l.subs = s.next
      if s.active and l.phase == lpOpen:
        abandon.add(s.id)
      s.active = false
      while s.head != nil:
        let e = s.head
        s.head = e.next
        release(l, e.credit)
        freeText(e.name)
        freeBytes(e.data, e.len)
        freeShared(e)
      s.tail = nil
      if s.subscribing != nil:
        s.subscribing.failLocked(ecNotReady, "the handle was released")
        s.subscribing = nil
      if s.unsubscribing != nil:
        s.unsubscribing.failLocked(ecNotReady, "the handle was released")
        s.unsubscribing = nil
      gone.add(s)
    broadcast(cc)
  for id in abandon:
    var cmd =
      IoCommand(conn: l.num, kind: IoCommandKind.cmdAbandonSubscription, subId: id)
    discard submitCmd(cmd)
  withLock cl:
    for s in gone:
      while s.runner != 0 and s.runner != me:
        wait(cc, cl)
      if s.draining:
        s.gone = true
      else:
        freeShared(s)
  let id = nextId()
  discard request(toMessage(LcnCarrierRcLinkReleased(id: id, link: l.num)), id)
  var last = false
  withLock cl:
    if l.asyncs == nil:
      closeLocked(l)
    last = dropLocked(l)
  if last:
    freeLink(l)

var routeVtable = LogosRouteVtable(
  abiVersion: RouteVtableAbiVersion,
  structSize: csize_t(sizeof(LogosRouteVtable)),
  call: routeCallOp,
  releaseResponse: routeReleaseResponseOp,
  subscribe: routeSubscribeOp,
  unsubscribe: routeUnsubscribeOp,
  release: routeReleaseOp,
  prepareCall: routePrepareCallOp,
  observeEnd: routeObserveEndOp,
)

# Materialization ------------------------------------------------------------------------------

proc ensureLoop(): Result[void, string] =
  ## Under `cl`: the consumer's own loop, with the Runtime's Transport limits.
  if cloop != nil:
    return ok()
  if transportLen == 0:
    return err("the host has no Transport limits")
  var words = newSeq[uint64](transportLen)
  for i in 0 ..< transportLen:
    words[i] = transportWords[i]
  let config = ?transportOf(words)
  cloop = ?startTransport(config, consumerEvent, nil)
  ok()

proc materialize*(
    routeId: cstring,
    expectedRoot: ptr ContractRoot,
    schema: ptr UncheckedArray[uint8],
    schemaLen: csize_t,
    outRoute: ptr LogosRouteHandle,
): LogosResult =
  ## [SPEC INTERFACE §5.2 l.3880-3911; RUNTIME §4.1] The direct binding's
  ## local checks (`bindings.rcMaterializeOp`), the Runtime's §4.1 checks,
  ## then this host's connection (module comment).
  if outRoute == nil:
    return status(ecInvalidParams, "null route output")
  outRoute.vtable = nil
  outRoute.state = nil
  checkMaterializeInput(routeId, expectedRoot, schema, schemaLen).isOkOr:
    return status(error)
  let id = $routeId
  if id.len == 0 or id.len > 128 or not isValidUtf8(id):
    return status(ecInvalidParams, "a route id has 1 to 128 UTF-8 bytes")
  let root: Digest = expectedRoot[]
  # [SPEC INTERFACE §5.2 l.3904-3906] Malformed or invalid construction input
  # is INVALID_PARAMS without detail.
  let input = view(schema, schemaLen)
  let set = acceptSchemaResponse(input, AcceptOptions(system: true)).valueOr:
    return status(ecInvalidParams, "invalid construction input: " & error)
  when not ChannelsMove:
    # [DECISIONS G277] A refc host carries no marked payload: a route whose
    # selected contract marks one fails here, before the Runtime is asked,
    # as the Runtime's own refusal would (`engine.erases`).
    if set.marksPayloads:
      return status(ecModule, MarkedUnsupported)
  let m = takeMaterial(id)
  let rid = nextId()
  let a = request(
    toMessage(
      LcnCarrierRcMaterialize(
        id: rid, route: id, expected_root: @root, schema: @input, material: m != nil
      )
    ),
    rid,
  )
  if a.failed:
    if m != nil:
      putBack(m)
    return status(failureOf(a))
  if m == nil or not a.hasLink:
    carrierLost("a materialization the Runtime admitted without material")
  let l = createShared(HLink)
  l.num = a.link
  l.route = sharedText(id)
  l.root = root
  l.schema = sharedBytes(input)
  l.schemaLen = input.len
  l.refs = 1
  var cmd: IoCommand
  var started: Result[void, string]
  withLock cl:
    started = ensureLoop()
    if started.isOk:
      l.next = links
      links = l
      # [plan §2.8; R18] The ticket exists only transiently: wiped here and in
      # the command once it is queued.
      cmd = IoCommand(
        conn: l.num,
        kind: IoCommandKind.cmdConnect,
        path: $m.path,
        expected: PeerIdentity(uid: a.uid),
        module: a.module,
        ticket: m.ticket,
        selected: ContractInput(root: root, schema: input, system: true),
        firstId: 0,
      )
  burn(m)
  var sent = sbStopped
  if started.isOk:
    sent = cloop.trySubmit(cmd)
    # A queued command was moved, and reset with its ticket; one the loop did
    # not take still holds it.
    if cmd.kind == IoCommandKind.cmdConnect:
      zeroMem(addr cmd.ticket[0], cmd.ticket.len)
  var report = LcnCarrierRcLinkResult(id: nextId(), link: l.num)
  if started.isErr or sent != sbOk:
    report.cause = Opt.some(uint8(ord(cfShutdown)))
    report.code = Opt.some(uint8(ord(ecNotReady)))
    withLock cl:
      l.phase = lpClosed
  else:
    withLock cl:
      while not l.connected and not l.connectFailed:
        wait(cc, cl)
      if l.connected:
        l.phase = lpOpen
      else:
        report.cause = Opt.some(uint8(ord(l.failCause)))
        report.code = Opt.some(uint8(ord(l.failCode)))
  let b = request(toMessage(report), report.id)
  if b.failed:
    var last = false
    withLock cl:
      closeLocked(l)
      last = dropLocked(l)
    if last:
      freeLink(l)
    return status(failureOf(b))
  withLock cl:
    l.held = true
    # The connection may have ended before the handle was returned.
    if l.closedKnown:
      retainLocked(l)
      post(Job(kind: jkClosed, link: l))
  if set.primary.root == root:
    discard # [IMPL] the selected contract is rebuilt on demand (`recheck`)
  outRoute.vtable = addr routeVtable
  outRoute.state = l
  LogosResult()

# Startup and release ---------------------------------------------------------------------------

proc initConsumer*() =
  ## Main thread, at startup.
  initLock(matLock)
  initLock(cl)
  initCond(cc)
  workers = createShared(Workers)
  workers.ch.open()
  initLock(workers.lock)
  initCond(workers.done)

proc setConsumerTransport*(transport: openArray[uint64], payloadDepth: int) =
  ## Lifecycle thread, before `_MODULE_init`: the Runtime's Transport limits,
  ## which the consumer's loop starts with on first use, and the payload depth
  ## its rechecks use.
  withLock cl:
    depth = payloadDepth
    if transport.len > 0 and transportWords == nil:
      transportWords =
        cast[ptr UncheckedArray[uint64]](allocShared(transport.len * sizeof(uint64)))
      for i, w in transport:
        transportWords[i] = w
      transportLen = transport.len

proc zeroOutcome(o: ptr Outcome) =
  if o == nil:
    return
  if o.message != nil:
    secureZero(o.message, o.message.len)
  secureZero(o.detail, o.detailLen)
  secureZero(o.value, o.valueLen)

proc stopConsumerTimer*() =
  ## Lifecycle thread, at the release, after `_MODULE_destroy` [DECISIONS I92]:
  ## the timer ends at its next look and is joined outside `cl`, which it
  ## takes to look. A timer that returned was joined only by the next arm, so
  ## the last one would outlive the release unjoined.
  var made = false
  withLock cl:
    timerStop = true
    made = timerMade
    timerMade = false
  if made:
    joinThread(timer)

proc wipeConsumer*() =
  ## Lifecycle thread, at the release, after `_MODULE_destroy` and before the
  ## exit [DECISIONS G276]: what the module will never release (prepared
  ## calls, their outcomes, waits never answered) is zeroed in place; the
  ## process ends next.
  withLock cl:
    var l = links
    while l != nil:
      var c = l.asyncs
      while c != nil:
        secureZero(c.params, c.paramsLen)
        zeroOutcome(addr c.o)
        c = c.next
      var w = l.calls
      while w != nil:
        zeroOutcome(w.o)
        w = w.next
      l = l.next

proc awaitConsumer*() =
  ## Lifecycle thread, at the release, before `_MODULE_destroy`: every handler,
  ## observer and completion handed over has returned.
  if workers == nil:
    return
  withLock workers.lock:
    while workers.pending > 0:
      wait(workers.done, workers.lock)
