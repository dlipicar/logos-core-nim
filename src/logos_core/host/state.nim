## The Module Host's process-wide state (Tier 4b step 4b-3; DECISIONS G264,
## G266; plan §2.1, §2.2) [IMPL]. One host serves one realization, so this is
## one object in shared memory, made at startup.
##
## - **The carrier.** The main thread is its only reader; any thread writes a
##   whole frame under the writer's lock. Losing it ends the process with
##   status 70 at once, without destroying the context (RUNTIME l.976).
## - **Waiting.** A thread that sends a request waits on a slot of its own
##   (one `Channel` of plain answers); the main thread decodes the reply and
##   hands it over, so no generated case object crosses threads. Slots are
##   reused, never closed: a sender signals a channel after releasing its
##   lock (Nim 2.2.14 `channels_builtin.sendImpl`), so a slot closed and
##   freed once its answer was read could still be signalled (the Runtime's
##   reply slots, `plumbing.ReplySlot`, for the same reason).
## - **Host threads.** The threads the host runs module code on (the
##   lifecycle thread and the callback workers) mark themselves; a Runtime
##   Control call from one tells the Runtime so (RUNTIME l.4083), as a direct
##   module's call from a Runtime-owned thread does.

{.push raises: [], gcsafe.}

import std/[atomics, locks, posix]
import results
import ../iface/outcome
import ../runtime/carrier

export carrier

const
  ExitNotStartedByLoader* = 2 ## [plan §2.2 step 3] fd 3 is not a carrier
  ExitCarrierLost* = 70
    ## [plan §2.9; RUN-0812] the carrier failed or broke the protocol
  ExitWipeAudit* = 97
    ## [DECISIONS I92] test builds only: an armed audit host found a pattern
    ## in a released block, and ended gracefully otherwise

type
  Answer* = object
    ## A reply as plain values: `failed` with `code`, `message` and `detail`,
    ## or a success with `value`, `sub`, `targets` or `admitted` (lane 1) or
    ## `ready` and `tag` (a scoped step, lane 2).
    failed*: bool
    code*: uint8
    hasMessage*: bool
    message*: string
    hasDetail*: bool
    detail*: seq[byte]
    value*: seq[byte]
    sub*: uint64
    targets*: seq[(uint64, seq[byte])] ## an `rc_publish`'s sessions and contracts
    admitted*: seq[uint64] ## an `rc_deliver`'s sessions
    ready*: bool
    hasTag*: bool
    tag*: uint64
    hasLink*: bool ## an `rc_materialize`'s handle: `link`, `uid`, `module`
    link*: uint64
    uid*: uint32
    module*: string
    hasCode*: bool ## an `rc_link_closed`'s first terminal cause
    code8*: uint8

  SlotObj = object
    id: uint64
    ch: Channel[Answer]
    next: ptr SlotObj ## in `slots` while a request waits, in `free` after

  Slot* = ptr SlotObj

  HostShared* = object
    fd*: cint ## the carrier, moved above 64
    writer*: CarrierWriter
    nextId: Atomic[uint64]
    lock: Lock
    slots: ptr SlotObj ## waiting requests, under `lock`
    free: ptr SlotObj ## slots no request uses, under `lock`
    stopping*: Atomic[bool] ## the release completed: the carrier's end is expected

var hs*: ptr HostShared
var hostOwned {.threadvar.}: bool

proc initHostShared*(fd: cint) =
  hs = createShared(HostShared)
  hs.fd = fd
  hs.writer.initWriter(fd)
  initLock(hs.lock)

proc markHostThread*() =
  hostOwned = true

proc onHostThread*(): bool =
  hostOwned

proc carrierLost*(why: string) {.noreturn.} =
  ## [SPEC RUNTIME RUN-0812, l.976] Terminal: no destroy, no exit handlers.
  try:
    stderr.writeLine("logos-module-host: " & why)
  except IOError:
    discard
  exitnow(ExitCarrierLost)

proc nextId*(): uint64 =
  hs.nextId.fetchAdd(1) + 1

proc send*(m: LcnCarrierMessage) =
  ## One message to the Runtime; a carrier that cannot take it is lost.
  hs.writer.send(m).isOkOr:
    if hs.stopping.load:
      return
    carrierLost("the carrier failed: " & error)

proc openSlot*(id: uint64): Slot =
  withLock hs.lock:
    result = hs.free
    if result != nil:
      hs.free = result.next
    else:
      result = createShared(SlotObj)
      result.ch.open()
    result.id = id
    result.next = hs.slots
    hs.slots = result

proc await*(s: Slot): Answer =
  ## The answer to the slot's request; the slot is free for another after.
  try:
    result = s.ch.recv()
  except Exception:
    carrierLost("a reply slot failed")
  withLock hs.lock:
    s.next = hs.free
    hs.free = s

proc request*(m: LcnCarrierMessage, id: uint64): Answer =
  ## Sends `m` (whose request id is `id`) and waits for its reply.
  let s = openSlot(id)
  send(m)
  s.await()

proc answered*(id: uint64, a: sink Answer) =
  ## Main thread: the reply to request `id`. One no request waits for is a
  ## protocol violation.
  var s: Slot
  withLock hs.lock:
    var p = addr hs.slots
    while p[] != nil:
      if p[].id == id:
        # Out of `slots` now: a second reply to `id` answers no request.
        s = p[]
        p[] = s.next
        s.next = nil
        break
      p = addr p[].next
  if s == nil:
    carrierLost("a reply to no request (" & $id & ")")
  try:
    s.ch.send(a)
  except Exception:
    carrierLost("a reply slot failed")

func answerOf*(r: LcnCarrierRcReply): Answer =
  if r.failure.isSome:
    let f = r.failure.get
    result.failed = true
    result.code = f.code
    if f.message.isSome:
      result.hasMessage = true
      result.message = f.message.get
    if f.detail.isSome:
      result.hasDetail = true
      result.detail = f.detail.get
  else:
    result.value = r.value.get(@[])
    result.sub = r.sub.get(0)
    for t in r.targets.get(@[]):
      result.targets.add((t.conn, t.contract))
    result.admitted = r.admitted.get(@[])
    if r.link.isSome:
      result.hasLink = true
      result.link = r.link.get
      result.uid = r.uid.get(0)
      result.module = r.module.get("")
    if r.code.isSome:
      result.hasCode = true
      result.code8 = r.code.get

func answerOf*(f: LcnCarrierFailure): Answer =
  answerOf(LcnCarrierRcReply(failure: Opt.some(f)))

func answerOf*(r: LcnCarrierScopedResult): Answer =
  if r.failure.isSome:
    return answerOf(r.failure.get)
  result.ready = r.ready.get(false)
  if r.tag.isSome:
    result.hasTag = true
    result.tag = r.tag.get

func failureOf*(a: Answer): InvocationFailure =
  ## A failed answer's status, as the module reads it.
  result = InvocationFailure(code: ecModule)
  if a.code > 0 and a.code <= uint8(high(ErrorCode)):
    result.code = ErrorCode(a.code)
  if a.hasMessage:
    result.message = Opt.some(a.message)
  if a.hasDetail:
    result.detail = Opt.some(a.detail)
