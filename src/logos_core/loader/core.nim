## The Module Loader's state, on one thread (Tier 4b step 4b-1; DECISIONS I89)
## [IMPL].
##
## One thread per Loader context owns the Loader's `Realizer` (its static
## registrations, bindings and live realizations). It runs no module code: the
## kit handlers (`provider.nim`) run on the calling thread, ask this thread for
## each phase and run the target's code themselves (`runBind`, `_MODULE_init`,
## `_MODULE_destroy`, `_MODULE_apply_configuration`).
##
## - **Threading.** Requests and replies are plain values over channels, so no
##   garbage-collected memory crosses threads under ORC or refc. The init input
##   stays in this thread's `InitHandoff` until `_MODULE_init` returns; only its
##   address and the init function go to the caller.
## - **Order** (LOADER §11). Per module instance, mutations (`realize`,
##   `release`, `apply_configuration`) run one at a time in arrival order: a
##   second one waits until the first completes (l.643-644). Different
##   instances proceed concurrently (l.654). `get_status` and
##   `list_capabilities` do not wait: each answers from one consistent state
##   (l.648-651).
## - **Private handoffs** (D14). The outbound handoff of a realization is
##   written to the side table before the reply that makes it active, and
##   withdrawn once its `_MODULE_destroy` has returned. An error that came from
##   `_MODULE_init` marks the attempt's inbound entry `fpInit` (G250).
## - **Closing.** `closeCore` refuses new requests, answers the queued ones and
##   joins the thread. A realization still live then is left as it is: the
##   Runtime releases every realization the Loader owns before it destroys the
##   Loader (RUNTIME l.3863; G247).

{.push raises: [], gcsafe.}

import std/[atomics, deques, locks, tables]
import results
import ../abi/[checks, types]
import ../runtime/[bell, config, realizer, sidetable]

export realizer, sidetable

type
  CoreConfig* = object
    ## What the Loader's thread starts from (the protected wiring,
    ## `provider.nim`), as plain values.
    statics*: seq[StaticRegistration]
    workDir*: string
    stateRoot*: Opt[string]
    side*: SideTable

  InitCall* = object
    ## The one `_MODULE_init(input, &context)` call the caller runs. `input`
    ## stays valid until `initDone` or `abandon`.
    init*: ModuleInitFn
    input*: ptr LogosModuleInitInput

  PhaseKind* = enum
    pkDone ## the realize is complete: `outcome`
    pkBind ## run `runBind(spec)`, then `bound`
    pkInit ## run `call`, then `initDone`

  PhaseReply* = object
    outcome*: Result[RealizationRecord, LoaderError]
      ## `pkDone`'s
      ## [IMPL] outside the case, so the first kind carries no fields: see
      ## `ReqKind`
    case kind*: PhaseKind
    of pkDone:
      discard
    of pkBind:
      spec*: BindSpec
    of pkInit:
      call*: InitCall

  InitReply* = object
    outcome*: Result[RealizationRecord, LoaderError]
    orphan*: Opt[Teardown]
      ## [IMPL] LOGOS_OK with a context and an invalid status: the context the
      ## caller destroys once, before the error returns

  ReqKind = enum
    ## [IMPL] The first kind carries no fields in `Request` or `Reply`. Nim
    ## 2.2.14's `=wasMoved` for a case object resets the active branch, sets
    ## the discriminator to its first value and then resets that branch too,
    ## reading the discriminators of case objects nested in it from bytes
    ## another branch wrote (`MsgKind` in `runtime/plumbing.nim`). UBSan
    ## caught it here when `Channel.send` reset a `pkInit` reply while
    ## `pkDone`, which held a `Result`, was the first kind.
    rkAbandon
    rkCapabilities
    rkStatus
    rkBegin
    rkBound
    rkInitDone
    rkBeginRelease
    rkReleaseDone
    rkBeginApply
    rkApplyDone

  Request = object
    slot: ptr ReplySlot
    instance: string
    case kind: ReqKind
    of rkStatus:
      statusId: Opt[string]
    of rkBegin:
      realize: RealizeRequest
      handoff: bool ## the side table held the attempt's inbound handoff
    of rkBound:
      bound: BindResult
    of rkInitDone:
      initOutcome: AbiCheck
      returnedOk: bool
      context: ptr LogosModuleContext
    of rkBeginRelease:
      releaseId: string
      force: bool
    of rkBeginApply:
      applyId: string
    of rkApplyDone:
      applyStatus: AbiCheck
    of rkCapabilities, rkAbandon, rkReleaseDone:
      discard

  Reply = object
    case kind: ReqKind
    of rkCapabilities:
      caps: Capabilities
    of rkStatus:
      record: Result[RealizationRecord, LoaderError]
    of rkBegin, rkBound:
      step: PhaseReply
    of rkInitDone:
      init: InitReply
    of rkBeginRelease:
      teardown: Result[Opt[Teardown], LoaderError]
    of rkBeginApply:
      hook: Result[ApplyHook, LoaderError]
    of rkApplyDone:
      applied: Result[void, LoaderError]
    of rkAbandon, rkReleaseDone:
      discard

  ReplySlot = object
    ## One reply channel, reused call after call and freed only after the
    ## thread is joined: the thread rings the bell after it sends, so a slot
    ## freed as soon as its reply was read could be rung after it is gone.
    ch: Channel[Reply]
    bell: Bell
    nextFree: ptr ReplySlot
    nextAll: ptr ReplySlot

  CoreShared = object
    inbox: Channel[Request]
    bell: Bell
    admitLock: Lock
    closed: bool ## under `admitLock`
    slotLock: Lock
    freeSlots: ptr ReplySlot
    allSlots: ptr ReplySlot
    thread: Thread[ptr CoreShared]
    start: Channel[CoreConfig]
    started: Channel[string]
    live: Atomic[int] ## live realizations, for tests

  LoaderCore* = ptr CoreShared

  RecordResult = Result[RealizationRecord, LoaderError]
  TeardownResult = Result[Opt[Teardown], LoaderError]
  HookResult = Result[ApplyHook, LoaderError]
  VoidResult = Result[void, LoaderError]

  Attempt = object ## A realize between its begin and its end.
    request: RealizeRequest
    handoff: InitHandoff ## set once the init input is prepared

  Core = object
    sh: ptr CoreShared
    r: Realizer
    side: SideTable
    busy: Table[string, Deque[Request]]
      ## instances with a mutation running, and the mutations waiting for it
    attempts: Table[string, Attempt]
    releasing: Table[string, string] ## instance: the realization being released

const ClosingText* = "the Module Loader is closing"

# Replies ------------------------------------------------------------------------------

proc answer(slot: ptr ReplySlot, r: sink Reply) =
  try:
    slot.ch.send(r)
  except Exception:
    discard
  slot.bell.ring()

proc dropInput(req: RealizeRequest) =
  ## The configuration input the caller handed over with the request.
  if req.configuration.isSome:
    drop(req.configuration.get.input)

proc refuse(q: Request) =
  ## The reply to a request the thread will not process: it is closing.
  let e = loaderError(lecRealizationFailed, ClosingText)
  case q.kind
  of rkCapabilities:
    q.slot.answer(Reply(kind: rkCapabilities))
  of rkStatus:
    q.slot.answer(Reply(kind: rkStatus, record: RecordResult.err(e)))
  of rkBegin:
    dropInput(q.realize)
    q.slot.answer(
      Reply(kind: rkBegin, step: PhaseReply(kind: pkDone, outcome: RecordResult.err(e)))
    )
  of rkBound:
    q.slot.answer(
      Reply(kind: rkBound, step: PhaseReply(kind: pkDone, outcome: RecordResult.err(e)))
    )
  of rkInitDone:
    q.slot.answer(
      Reply(kind: rkInitDone, init: InitReply(outcome: RecordResult.err(e)))
    )
  of rkBeginRelease:
    q.slot.answer(Reply(kind: rkBeginRelease, teardown: TeardownResult.err(e)))
  of rkBeginApply:
    q.slot.answer(Reply(kind: rkBeginApply, hook: HookResult.err(e)))
  of rkApplyDone:
    q.slot.answer(Reply(kind: rkApplyDone, applied: VoidResult.err(e)))
  of rkAbandon, rkReleaseDone:
    q.slot.answer(Reply(kind: q.kind))

# The thread ---------------------------------------------------------------------------

proc countLive(c: var Core) =
  c.sh.live.store(c.r.liveCount, moRelease)

proc start(c: var Core, q: sink Request)

proc finish(c: var Core, instance: string) =
  ## The instance's running mutation is complete: start the next one waiting,
  ## if any. A mutation that completes at once finishes in turn, which starts
  ## the one after it.
  c.countLive()
  var next: Request
  try:
    if c.busy[instance].len == 0:
      c.busy.del(instance)
      return
    next = c.busy[instance].popFirst()
  except KeyError:
    return
  c.start(next)

proc endAttempt(c: var Core, instance: string) =
  var a: Attempt
  if c.attempts.pop(instance, a):
    dropInput(a.request)
  c.finish(instance)

proc phaseReply(kind: ReqKind, p: sink PhaseReply): Reply =
  ## The reply of a `realize` phase: to its begin or to its bind.
  if kind == rkBound:
    Reply(kind: rkBound, step: p)
  else:
    Reply(kind: rkBegin, step: p)

proc doneStep(
    c: var Core, q: Request, outcome: sink Result[RealizationRecord, LoaderError]
) =
  let slot = q.slot
  let kind = q.kind
  c.endAttempt(q.instance)
  slot.answer(phaseReply(kind, PhaseReply(kind: pkDone, outcome: outcome)))

proc prepare(c: var Core, q: Request, b: ref NativeBinding) =
  ## [SPEC LOADER §6 steps 4-7] The state directory and the init input.
  var a: Attempt
  try:
    a = c.attempts[q.instance]
  except KeyError:
    c.doneStep(
      q, RecordResult.err(loaderError(lecRealizationFailed, "no attempt in progress"))
    )
    return
  let h = c.r.prepareInit(a.request, b).valueOr:
    c.doneStep(q, RecordResult.err(error))
    return
  try:
    c.attempts[q.instance].handoff = h
  except KeyError:
    discard
  q.slot.answer(
    phaseReply(
      q.kind,
      PhaseReply(kind: pkInit, call: InitCall(init: b.init, input: addr h.input)),
    )
  )

proc beginRealize(c: var Core, q: Request) =
  ## [SPEC LOADER §6] Admission, then the instance's current realization, a
  ## cached binding, or the binding work still to do.
  c.r.admissible(q.realize).isOkOr:
    dropInput(q.realize)
    q.slot.answer(
      Reply(
        kind: rkBegin, step: PhaseReply(kind: pkDone, outcome: RecordResult.err(error))
      )
    )
    c.finish(q.instance)
    return
  if not q.handoff:
    # [SPEC LOADER l.427 (LDR-0088)] No private handoff came from the
    # Runtime for this instance.
    dropInput(q.realize)
    q.slot.answer(
      Reply(
        kind: rkBegin,
        step: PhaseReply(
          kind: pkDone,
          outcome: RecordResult.err(
            loaderError(
              lecInvalidRequest, "no private handoff came for the module instance"
            )
          ),
        ),
      )
    )
    c.finish(q.instance)
    return
  c.attempts[q.instance] = Attempt(request: q.realize)
  let step = c.r.begin(q.realize).valueOr:
    c.doneStep(q, RecordResult.err(error))
    return
  case step.kind
  of skLive:
    c.doneStep(q, RecordResult.ok(step.realization.record))
  of skBind:
    q.slot.answer(Reply(kind: rkBegin, step: PhaseReply(kind: pkBind, spec: step.spec)))
  of skInit:
    c.prepare(q, step.binding)

proc start(c: var Core, q: sink Request) =
  ## A mutation whose turn has come.
  case q.kind
  of rkBegin:
    c.beginRealize(q)
  of rkBeginRelease:
    let t = c.r.beginRelease(q.releaseId, q.instance, q.force)
    if t.isOk and t.get.isSome:
      # `_MODULE_destroy` is out: the instance stays busy until it returns.
      c.releasing[q.instance] = q.releaseId
      q.slot.answer(Reply(kind: rkBeginRelease, teardown: t))
      return
    if t.isOk:
      # Nothing to destroy: the record (if any) is gone now.
      c.r.finishRelease(q.instance)
      c.side.withdrawOutbound(q.releaseId)
    q.slot.answer(Reply(kind: rkBeginRelease, teardown: t))
    c.finish(q.instance)
  of rkBeginApply:
    let h = c.r.beginApply(q.applyId, q.instance)
    q.slot.answer(Reply(kind: rkBeginApply, hook: h))
    if h.isErr:
      c.finish(q.instance)
  else:
    q.refuse()

proc handle(c: var Core, q: sink Request) =
  case q.kind
  of rkCapabilities:
    q.slot.answer(Reply(kind: rkCapabilities, caps: c.r.capabilities))
  of rkStatus:
    q.slot.answer(Reply(kind: rkStatus, record: c.r.getStatus(q.instance, q.statusId)))
  of rkBegin, rkBeginRelease, rkBeginApply:
    if q.instance in c.busy:
      try:
        c.busy[q.instance].addLast(q)
      except KeyError:
        discard
      return
    c.busy[q.instance] = initDeque[Request]()
    c.start(q)
  of rkBound:
    let b = c.r.storeBinding(q.bound).valueOr:
      c.doneStep(q, RecordResult.err(error))
      return
    c.prepare(q, b)
  of rkInitDone:
    var a: Attempt
    if not c.attempts.pop(q.instance, a) or a.handoff.isNil:
      q.slot.answer(
        Reply(
          kind: rkInitDone,
          init: InitReply(
            outcome: RecordResult.err(
              loaderError(lecRealizationFailed, "no attempt in progress")
            )
          ),
        )
      )
      return
    var orphan: ptr LogosModuleContext
    let x =
      c.r.completeInitChecked(a.handoff, q.initOutcome, q.returnedOk, q.context, orphan)
    dropInput(a.request)
    var reply = InitReply()
    if x.isErr:
      # [IMPL-DECISION G250] `_MODULE_init` failed, rejected its input or
      # broke its result contract: the attempt's phase is init.
      c.side.setFailedPhase(q.instance, fpInit)
      reply.outcome = RecordResult.err(x.error)
      if orphan != nil:
        reply.orphan =
          Opt.some(Teardown(destroy: a.handoff.binding.destroy, context: orphan))
    else:
      let b = a.handoff.binding
      # A realization id is never issued twice, so the handoff is new.
      discard c.side.putOutbound(
        x.get.id,
        OutboundHandoff(
          dispatch: b.dispatch,
          free: b.free,
          asyncApi: b.asyncApi,
          context: q.context,
          declaresEvents: b.declaresEvents,
        ),
      )
      reply.outcome = RecordResult.ok(x.get.record)
    q.slot.answer(Reply(kind: rkInitDone, init: reply))
    c.finish(q.instance)
  of rkAbandon:
    c.endAttempt(q.instance)
    q.slot.answer(Reply(kind: rkAbandon))
  of rkReleaseDone:
    c.r.finishRelease(q.instance)
    var id: string
    if c.releasing.pop(q.instance, id):
      c.side.withdrawOutbound(id)
    q.slot.answer(Reply(kind: rkReleaseDone))
    c.finish(q.instance)
  of rkApplyDone:
    let r = c.r.completeApplyChecked(q.instance, q.applyStatus)
    q.slot.answer(Reply(kind: rkApplyDone, applied: r))
    c.finish(q.instance)

proc tryTake(ch: var Channel[Request]): Opt[Request] =
  try:
    let (ok, q) = ch.tryRecv()
    if ok:
      return Opt.some(q)
  except Exception:
    discard
  Opt.none(Request)

proc run(c: var Core) =
  let sh = c.sh
  while true:
    while true:
      let q = sh.inbox.tryTake()
      if q.isNone:
        break
      c.handle(q.get)
    var closing: bool
    withLock sh.admitLock:
      closing = sh.closed
    if closing:
      # Nothing is admitted any more: answer what is queued and what waits.
      while true:
        let q = sh.inbox.tryTake()
        if q.isNone:
          break
        c.handle(q.get)
      for _, waiting in c.busy.mpairs:
        while waiting.len > 0:
          waiting.popFirst().refuse()
      break
    sh.bell.wait()

proc coreMain(sh: ptr CoreShared) {.thread.} =
  var cfg: CoreConfig
  try:
    cfg = sh.start.recv()
  except Exception:
    return
  var c = Core(sh: sh, side: cfg.side, r: newRealizer(cfg.workDir, cfg.stateRoot))
  for reg in cfg.statics:
    # [SPEC RUNTIME §13.3] A duplicate binding identifier leaves the first
    # registration unchanged, as the engine's own realizer did before I89.
    discard c.r.registerStatic(reg)
  try:
    sh.started.send("") # started
  except Exception:
    discard
  c.run()
  c.r = nil

# The API ------------------------------------------------------------------------------

proc drainClose[T](ch: var Channel[T]) =
  ## [IMPL] Closes `ch` once whatever is still queued in it is destroyed: under
  ## ORC `send` moves a value into the channel's buffer and `close` frees that
  ## buffer without destroying it.
  while true:
    try:
      let (ok, _) = ch.tryRecv()
      if not ok:
        break
    except Exception:
      break
  ch.close()

proc freeShared(c: LoaderCore) =
  var slot = c.allSlots
  while slot != nil:
    let next = slot.nextAll
    slot.ch.drainClose()
    freeBell(slot.bell)
    deallocShared(slot)
    slot = next
  c.inbox.drainClose()
  c.start.drainClose()
  c.started.drainClose()
  freeBell(c.bell)
  deinitLock(c.admitLock)
  deinitLock(c.slotLock)
  deallocShared(c)

proc openCore*(cfg: CoreConfig): Result[LoaderCore, string] =
  ## Starts the Loader's thread with `cfg`'s static registrations.
  if cfg.side == nil:
    return err("the Module Loader has no side table")
  let c = cast[LoaderCore](allocShared0(sizeof(CoreShared)))
  c.inbox.open()
  c.start.open()
  c.started.open()
  c.bell = newBell()
  initLock(c.admitLock)
  initLock(c.slotLock)
  var started: string
  try:
    c.start.send(cfg)
    createThread(c.thread, coreMain, c)
    started = c.started.recv()
  except Exception as e:
    started = "cannot start the Module Loader's thread: " & e.msg
  if started.len > 0:
    try:
      joinThread(c.thread)
    except Exception:
      discard
    c.freeShared()
    return err(started)
  ok(c)

proc closeCore*(c: LoaderCore) =
  ## Refuses new requests, answers the queued ones and joins the thread.
  withLock c.admitLock:
    c.closed = true
  c.bell.ring()
  try:
    joinThread(c.thread)
  except Exception:
    discard
  c.freeShared()

proc takeSlot(c: LoaderCore): ptr ReplySlot =
  withLock c.slotLock:
    result = c.freeSlots
    if result != nil:
      c.freeSlots = result.nextFree
    else:
      result = createShared(ReplySlot)
      result.ch.open()
      result.bell = newBell()
      result.nextAll = c.allSlots
      c.allSlots = result

proc giveSlot(c: LoaderCore, slot: ptr ReplySlot) =
  withLock c.slotLock:
    slot.nextFree = c.freeSlots
    c.freeSlots = slot

proc submit(c: LoaderCore, q: sink Request): Opt[Reply] =
  ## Sends `q` and waits for its reply; none when the Loader is closed. A
  ## request the thread admitted is always answered.
  let slot = c.takeSlot()
  q.slot = slot
  var admitted = false
  withLock c.admitLock:
    if not c.closed:
      try:
        c.inbox.send(q)
        admitted = true
      except Exception:
        admitted = false
  if not admitted:
    c.giveSlot(slot)
    return Opt.none(Reply)
  c.bell.ring()
  while true:
    try:
      let (ok, r) = slot.ch.tryRecv()
      if ok:
        c.giveSlot(slot)
        return Opt.some(r)
    except Exception:
      discard
    slot.bell.wait()

func closing(): LoaderError =
  loaderError(lecRealizationFailed, ClosingText)

proc capabilities*(c: LoaderCore): Opt[Capabilities] =
  let r = c.submit(Request(kind: rkCapabilities))
  if r.isNone:
    return Opt.none(Capabilities)
  Opt.some(r.get.caps)

proc status*(
    c: LoaderCore, instance: string, realization: Opt[string]
): Result[RealizationRecord, LoaderError] =
  ## [SPEC LOADER §7] One consistent snapshot; never waits for a mutation.
  let r = c.submit(Request(kind: rkStatus, instance: instance, statusId: realization))
  if r.isNone:
    return err(closing())
  r.get.record

proc beginRealize*(c: LoaderCore, req: sink RealizeRequest, handoff: bool): PhaseReply =
  ## The first phase of `realize`, once the instance's earlier mutations are
  ## complete. Takes the request's configuration input: the thread drops it
  ## when the attempt ends.
  let instance = req.moduleInstance
  let input = if req.configuration.isSome: req.configuration.get.input else: nil
  let r =
    c.submit(Request(kind: rkBegin, instance: instance, realize: req, handoff: handoff))
  if r.isNone:
    drop(input)
    return PhaseReply(kind: pkDone, outcome: RecordResult.err(closing()))
  r.get.step

proc bound*(c: LoaderCore, instance: string, res: sink BindResult): PhaseReply =
  ## `runBind` has returned: the binding is stored and the init input prepared.
  let r = c.submit(Request(kind: rkBound, instance: instance, bound: res))
  if r.isNone:
    return PhaseReply(kind: pkDone, outcome: RecordResult.err(closing()))
  r.get.step

proc initDone*(
    c: LoaderCore,
    instance: string,
    outcome: AbiCheck,
    returnedOk: bool,
    context: ptr LogosModuleContext,
): InitReply =
  ## `_MODULE_init` has returned what `checkInit` read.
  let r = c.submit(
    Request(
      kind: rkInitDone,
      instance: instance,
      initOutcome: outcome,
      returnedOk: returnedOk,
      context: context,
    )
  )
  if r.isNone:
    return InitReply(outcome: RecordResult.err(closing()))
  r.get.init

proc abandon*(c: LoaderCore, instance: string) =
  ## The realize was cancelled before `_MODULE_init`: nothing was created.
  discard c.submit(Request(kind: rkAbandon, instance: instance))

proc beginRelease*(
    c: LoaderCore, realization, instance: string, force: bool
): Result[Opt[Teardown], LoaderError] =
  ## [SPEC LOADER §9] The context to destroy, if any; `releaseDone` follows a
  ## teardown.
  let r = c.submit(
    Request(
      kind: rkBeginRelease, instance: instance, releaseId: realization, force: force
    )
  )
  if r.isNone:
    return err(closing())
  r.get.teardown

proc releaseDone*(c: LoaderCore, instance: string) =
  ## `_MODULE_destroy` has returned.
  discard c.submit(Request(kind: rkReleaseDone, instance: instance))

proc beginApply*(
    c: LoaderCore, realization, instance: string
): Result[ApplyHook, LoaderError] =
  ## [SPEC LOADER §8] The hook to call once; `applyDone` follows it.
  let r =
    c.submit(Request(kind: rkBeginApply, instance: instance, applyId: realization))
  if r.isNone:
    return err(closing())
  r.get.hook

proc applyDone*(
    c: LoaderCore, instance: string, status: AbiCheck
): Result[void, LoaderError] =
  ## The hook has returned the status `readStatus` read.
  let r = c.submit(Request(kind: rkApplyDone, instance: instance, applyStatus: status))
  if r.isNone:
    return err(closing())
  r.get.applied

proc liveCount*(c: LoaderCore): int =
  ## The realizations the Loader holds, for tests.
  c.live.load(moAcquire)
