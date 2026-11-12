## The test owner of a transport I/O loop, used in-process by
## `test_transport_io` and inside `trnpeer`: its own ticket store, admission and
## dispatch policies, and every event it saw. The sink only forwards events to
## a channel; the owner handles them on its own thread, so the ticket store has
## exactly one thread, as the Runtime's does.

import std/[monotimes, os, tables]
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

  Owner* = ref object
    loop*: Loop
    chan: ptr Channel[IoEvent]
    store*: TicketStore[RouteBinding]
    served*: Table[EndpointId, CalleeEndpoint]
    admit*: AdmitMode
    respond*: bool ## answer every dispatched Request with `{exists: true}`
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

proc fastConfig*(): TransportConfig =
  ## Small deadlines for tests (`test_transport_io` §5.1 of the plan).
  var c = defaultTransportConfig()
  c.helloTimeout = 300 * Ms
  c.admissionTimeout = 300 * Ms
  c.closeLinger = 100 * Ms
  c.writeStallTimeout = 500 * Ms
  c

proc now*(): Nanos =
  getMonoTime().ticks

proc toChannel(ev: sink IoEvent, ctx: pointer) {.nimcall, gcsafe, raises: [].} =
  cast[ptr Channel[IoEvent]](ctx)[].send(ev)

proc newOwner*(config = fastConfig()): Owner =
  let chan = createShared(Channel[IoEvent])
  chan[].open()
  let loop = startTransport(config, toChannel, chan)
  doAssert loop.isOk, loop.error
  Owner(loop: loop.get, chan: chan, respond: true)

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
            kind: avEstablished, response: r.get.response, binding: r.get.binding
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
          outcome: CallOutcome(
            ok: true, result: encodeCbor(cborMap((cbor("exists"), cbor(true))))
          ),
        )
      )
  else:
    discard

proc pump*(o: Owner, waitMs = 0): bool =
  ## Handles the events available, waiting up to `waitMs` for the first.
  var waited = 0
  while true:
    let (got, ev) = o.chan[].tryRecv()
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
  o.loop.stopTransport()
  while true:
    let (got, ev) = o.chan[].tryRecv()
    if not got:
      break
    o.log.add(ev)
  o.chan[].close()
  deallocShared(o.chan)

proc binding*(
    consumer = "app", endpoint = "ep-1", provider = Provider, route = "route-1"
): RouteBinding =
  RouteBinding(
    consumer: consumer,
    provider: provider,
    contract: storageRoot,
    endpoint: endpoint,
    route: route,
  )

proc issue*(o: Owner, b = binding()): RouteTicket =
  o.store.issue(b, now(), now() + 60_000 * Ms).get

proc live*(o: Owner, t: RouteTicket): bool =
  ## The non-consuming check (F1): the record is still there.
  o.store.validate(t, now()).isOk

proc serve*(
    o: Owner, id: EndpointId, listener: cint, endpoint = "ep-1", provider = Provider
): bool =
  ## Serves `listener` (the loop owns it from here on).
  let served =
    CalleeEndpoint(endpoint: endpoint, provider: provider, contracts: @[storageRoot])
  o.served[id] = served
  o.send(
    IoCommand(
      kind: cmdServe,
      endpoint: id,
      listener: listener,
      served: served,
      contract: storageInput(),
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
) =
  o.send(
    IoCommand(
      conn: conn,
      kind: cmdConnect,
      path: path,
      expected: PeerIdentity(uid: uid),
      module: module,
      ticket: t,
      selected: storageInput(),
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
