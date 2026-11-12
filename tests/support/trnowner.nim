## The test owner of a transport I/O loop, used in-process by
## `test_transport_io` and inside `trnpeer`: its own ticket store, admission and
## dispatch policies, and every event it saw. The sink only forwards events to
## a channel; the owner handles them on its own thread, so the ticket store has
## exactly one thread, as the Runtime's does.
##
## Policies (fields of `Owner`): admission, answering dispatched Requests (and
## ending their work), accepting subscriptions, releasing Event credits, and a
## session end for admitted sessions. `gate` makes the sink wait on the I/O
## thread, so a test can hold that thread still.

import std/[atomics, monotimes, os, tables]
import results
import ../../src/logos_core/cbor
import ../../src/logos_core/hash/hashinput
import ../../src/logos_core/iface/[accept, surface]
import ../../src/logos_core/transport/[hello, ticket]
import ../../src/logos_core/transport/io
import ./specdata

export io, hello, ticket

type
  AdmitMode* = enum
    amAccept ## run `acceptHello` and answer with its verdict
    amUnavailable ## answer `avUnavailable` without evaluating the Hello
    amIgnore ## never answer

  SinkBox = object
    chan: Channel[IoEvent]
    gate: Atomic[bool] ## while true, the sink waits (on the I/O thread)
    waiting: Atomic[bool] ## the sink is waiting at the gate

  Owner* = ref object
    loop*: Loop
    box: ptr SinkBox
    store*: TicketStore[RouteBinding]
    served*: Table[EndpointId, CalleeEndpoint]
    admit*: AdmitMode
    respond*: bool ## answer every dispatched Request with `answer`
    endWork*: bool ## with `respond`, the work ends with the Response
    answer*: CborValue ## the result map dispatched Requests get
    acceptSubs*: bool ## answer every evSubscribe and evUnsubscribe with success
    autoRelease*: bool ## release every evEvent's credit at once
    endsIn*: Opt[int64] ## admitted sessions end this long after admission
    log*: seq[IoEvent] ## every event, in order
    cursor*: int ## `expect` looks after this position

const
  Ms* = 1_000_000'i64
  Provider* = "storage_module"

let
  storageSet* = acceptContractSet(mirror("IFC/1.8.module.cddl")).get
  storageRoot* = storageSet.primary.root

proc storageInput*(): ContractInput =
  ContractInput(
    root: storageRoot,
    schema: encodeCbor(schemaResponse(storageSet, storageRoot).get),
    system: false,
  )

const Slow* =
  when defined(tsan):
    10
  elif defined(asan) or defined(msan):
    3
  else:
    1
  ## [IMPL] How much slower a sanitizer build moves multi-MiB payloads (the
  ## Nim code copies and checks them byte by byte, instrumented). A deadline
  ## that only bounds how long a test waits, or how long a flush may take, is
  ## multiplied by it; a deadline a test is about is not.

proc fastConfig*(): TransportConfig =
  ## Small deadlines for tests (`test_transport_io` §5.1 of the plan).
  var c = defaultTransportConfig()
  c.helloTimeout = 300 * Ms
  c.admissionTimeout = 300 * Ms
  c.closeLinger = 100 * Ms * Slow
  c.writeStallTimeout = 500 * Ms * Slow
  c

proc now*(): Nanos =
  getMonoTime().ticks

proc toChannel(ev: sink IoEvent, ctx: pointer) {.nimcall, gcsafe, raises: [].} =
  let box = cast[ptr SinkBox](ctx)
  if box.gate.load:
    box.waiting.store(true)
    while box.gate.load:
      sleep(1)
    box.waiting.store(false)
  box.chan.send(ev)

proc newOwner*(config = fastConfig()): Owner =
  let box = createShared(SinkBox)
  box.chan.open()
  let loop = startTransport(config, toChannel, box)
  doAssert loop.isOk, loop.error
  Owner(
    loop: loop.get,
    box: box,
    respond: true,
    endWork: true,
    answer: cborMap((cbor("exists"), cbor(true))),
    acceptSubs: true,
    autoRelease: true,
  )

proc closeGate*(o: Owner) =
  ## The next event the I/O thread emits waits in the sink until `openGate`.
  o.box.gate.store(true)

proc openGate*(o: Owner) =
  o.box.gate.store(false)

proc gate*(o: Owner): ptr Atomic[bool] =
  ## For a thread that opens the gate while the test thread waits.
  addr o.box.gate

proc atGate*(o: Owner): bool =
  ## Whether the I/O thread is waiting at the gate.
  o.box.waiting.load

proc send*(o: Owner, cmd: sink IoCommand) =
  doAssert o.loop.submit(cmd) == sbOk

proc handle(o: Owner, ev: IoEvent) =
  case ev.kind
  of evHello:
    case o.admit
    of amIgnore:
      discard
    of amUnavailable:
      o.send(
        IoCommand(
          conn: ev.conn, kind: cmdAdmit, verdict: AdmitVerdict(kind: avUnavailable)
        )
      )
    of amAccept:
      let ep = o.served.getOrDefault(ev.helloEndpoint)
      let r = acceptHello(ep, o.store, ev.frame, now())
      let v =
        if r.isOk:
          AdmitVerdict(
            kind: avEstablished,
            response: r.get.response,
            binding: r.get.binding,
            endsIn: o.endsIn,
          )
        else:
          AdmitVerdict(kind: avFailed, code: r.error.code, peer: r.error.peer)
      o.send(IoCommand(conn: ev.conn, kind: cmdAdmit, verdict: v))
  of evDispatch:
    if o.respond:
      o.send(
        IoCommand(
          conn: ev.conn,
          kind: cmdRespond,
          requestId: ev.requestId,
          outcome: CallOutcome(ok: true, result: encodeCbor(o.answer)),
          workEnded: o.endWork,
        )
      )
  of evSubscribe, evUnsubscribe:
    if o.acceptSubs:
      o.send(
        IoCommand(conn: ev.conn, kind: cmdSubscriptionResult, subId: ev.subscribeId)
      )
  of evEvent:
    if o.autoRelease:
      o.send(IoCommand(conn: ev.conn, kind: cmdRelease, releaseBytes: ev.credit))
  else:
    discard

proc pump*(o: Owner, waitMs = 0): bool =
  ## Handles the events available, waiting up to `waitMs` for the first.
  var waited = 0
  while true:
    let (got, ev) = o.box.chan.tryRecv()
    if got:
      o.log.add(ev)
      o.handle(ev)
      result = true
      continue
    if result or waited >= waitMs:
      return
    sleep(1)
    inc waited

proc expect*(o: Owner, pred: proc(ev: IoEvent): bool, timeoutMs = 5000): Opt[IoEvent] =
  ## The first event after the cursor that matches; the cursor moves past it.
  var waited = 0
  while true:
    for i in o.cursor ..< o.log.len:
      if pred(o.log[i]):
        o.cursor = i + 1
        return Opt.some(o.log[i])
    if waited >= timeoutMs:
      return Opt.none(IoEvent)
    discard o.pump(10)
    waited += 10

proc expectKind*(
    o: Owner, kind: IoEventKind, conn = high(uint64), timeoutMs = 5000
): Opt[IoEvent] =
  o.expect(
    proc(ev: IoEvent): bool =
      ev.kind == kind and (conn == high(uint64) or ev.conn == conn),
    timeoutMs,
  )

proc settle*(o: Owner, ms: int) =
  ## Keeps handling events for `ms` milliseconds.
  var waited = 0
  while waited < ms:
    discard o.pump(10)
    waited += 10

proc stop*(o: Owner) =
  ## Stops the loop; the events it reported meanwhile end up in `log`.
  o.openGate()
  o.loop.stopTransport()
  while true:
    let (got, ev) = o.box.chan.tryRecv()
    if not got:
      break
    o.log.add(ev)
  o.box.chan.close()
  deallocShared(o.box)

proc binding*(
    consumer = "app",
    endpoint = "ep-1",
    provider = Provider,
    route = "route-1",
    access = RouteAccess(),
    decision = "decision-1",
    contract = storageRoot,
): RouteBinding =
  RouteBinding(
    consumer: consumer,
    provider: provider,
    contract: contract,
    endpoint: endpoint,
    route: route,
    access: access,
    decision: decision,
  )

proc issue*(o: Owner, b = binding()): RouteTicket =
  o.store.issue(b, now(), now() + 60_000 * Ms).get

proc live*(o: Owner, t: RouteTicket): bool =
  ## The non-consuming check (F1): the record is still there.
  o.store.validate(t, now()).isOk

proc serve*(
    o: Owner,
    id: EndpointId,
    listener: cint,
    endpoint = "ep-1",
    provider = Provider,
    contract = storageInput(),
    contracts = @[storageRoot],
): bool =
  ## Serves `listener` (the loop owns it from here on).
  let served =
    CalleeEndpoint(endpoint: endpoint, provider: provider, contracts: contracts)
  o.served[id] = served
  o.send(
    IoCommand(
      kind: cmdServe,
      endpoint: id,
      listener: listener,
      served: served,
      contract: contract,
    )
  )
  o
    .expect(
      proc(ev: IoEvent): bool =
        (ev.kind == evListening and ev.listening == id) or
          (ev.kind == evServeFailed and ev.failedEndpoint == id)
    )
    .map(
      proc(ev: IoEvent): bool =
        ev.kind == evListening
    )
    .get(false)

proc connect*(
    o: Owner,
    conn: ConnId,
    path: string,
    t: RouteTicket,
    uid = effectiveUid(),
    module = Provider,
    firstId = 0'u64,
    selected = storageInput(),
) =
  o.send(
    IoCommand(
      conn: conn,
      kind: cmdConnect,
      path: path,
      expected: PeerIdentity(uid: uid),
      module: module,
      ticket: t,
      selected: selected,
      firstId: firstId,
    )
  )

proc callExists*(o: Owner, conn: ConnId, tag: uint64, cid = "bafy") =
  o.send(
    IoCommand(
      conn: conn,
      kind: cmdCall,
      tag: tag,
      methodName: "exists",
      params: encodeCbor(cborMap((cbor("cid"), cbor(cid)))),
    )
  )

proc call*(
    o: Owner, conn: ConnId, tag: uint64, methodName: string, params = cborMap()
) =
  o.send(
    IoCommand(
      conn: conn,
      kind: cmdCall,
      tag: tag,
      methodName: methodName,
      params: encodeCbor(params),
    )
  )

proc cancel*(o: Owner, conn: ConnId, tag: uint64) =
  o.send(IoCommand(conn: conn, kind: cmdCancel, callTag: tag))

proc respondTo*(o: Owner, conn: ConnId, id: uint64, endWork = true) =
  o.send(
    IoCommand(
      conn: conn,
      kind: cmdRespond,
      requestId: id,
      outcome: CallOutcome(ok: true, result: encodeCbor(o.answer)),
      workEnded: endWork,
    )
  )

proc workEnded*(o: Owner, conn: ConnId, id: uint64) =
  o.send(IoCommand(conn: conn, kind: cmdWorkEnded, endedId: id))

proc subscribe*(o: Owner, conn: ConnId, id: uint64, event: string) =
  o.send(IoCommand(conn: conn, kind: cmdSubscribe, subId: id, subEvent: event))

proc unsubscribe*(o: Owner, conn: ConnId, id: uint64) =
  o.send(IoCommand(conn: conn, kind: cmdUnsubscribe, subId: id))

proc release*(o: Owner, conn: ConnId, n: int) =
  o.send(IoCommand(conn: conn, kind: cmdRelease, releaseBytes: n))

proc terminate*(o: Owner, conn: ConnId) =
  o.send(IoCommand(conn: conn, kind: cmdTerminate))

proc publishCmd*(
    endpoint: EndpointId, event: string, data: CborValue, tooLarge = tlReport
): IoCommand =
  IoCommand(
    kind: cmdPublish,
    pubEndpoint: endpoint,
    event: event,
    data: encodeCbor(data),
    tooLarge: tooLarge,
  )

proc publish*(
    o: Owner, endpoint: EndpointId, event: string, data: CborValue, tooLarge = tlReport
) =
  o.send(publishCmd(endpoint, event, data, tooLarge))

proc publishScoped*(
    o: Owner,
    conn: ConnId,
    request: uint64,
    event: string,
    data: CborValue,
    tooLarge = tlReport,
) =
  o.send(
    IoCommand(
      conn: conn,
      kind: cmdPublishScoped,
      pubRequest: request,
      event: event,
      data: encodeCbor(data),
      tooLarge: tooLarge,
    )
  )

proc progress*(n: uint64, session = "s"): CborValue =
  ## `storage.upload_progress_event` data; `session` sets its size.
  cborMap(
    (cbor("session"), cbor(session)),
    (cbor("bytes_sent"), cbor(n)),
    (cbor("bytes_total"), cbor(n + 1)),
  )
