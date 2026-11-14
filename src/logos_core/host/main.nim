## The Module Host program (Tier 4b step 4b-3; DECISIONS G264, G266; plan
## §2.1, §2.2) [IMPL]: one process per hosted realization, started by the
## Runtime's supervision for the Module Loader (`runtime/hostsup.nim`). It
## initializes one module instance in its own address space and owns its
## context until the release destroys it, exactly once (LDR-0119).
##
## - **Startup** (plan §2.2): SIGPIPE ignored; on Linux the host dies with the
##   daemon (`PR_SET_PDEATHSIG`); fd 3 must be a connected stream socket of
##   the local family, or the host was not started by a Loader and exits 2;
##   fd 4 (a provider's listener, 4b-3.2) and fd 5 (the restart lock, 4b-3.1b)
##   are kept and never inherited by module children. Nothing per instance
##   comes from `argv` or the environment.
## - **The main thread** reads the carrier and never runs module code. Lane-0
##   requests go to the lifecycle thread in order, lane-1 replies to the
##   thread that waits for them, deliveries and completions to their workers.
##   Anything else, a frame that does not decode or one out of order, breaks
##   the protocol: the host exits 70 at once without destroying the context
##   (RUNTIME RUN-0812, l.976).
## - **The lifecycle thread** runs the module's lifecycle entries with the
##   realizer's own phases (`mapStaged`, `probeCode`, `completeProbe`,
##   `checkLive`, `initInputFor`, `initModule`, `checkInit`), so a hosted
##   realization makes the direct one's checks with the direct one's errors
##   (LOADER l.388-403). After `released` the host exits 0.
## - **A provider's endpoint** (4b-3.2; `endpoint.nim`): with `init.endpoint`
##   the loop serves fd 4 before `initialized` is sent; the Runtime's lane-2
##   orders and verdicts go to it from the main thread, in order, and the
##   release stops it before the context is destroyed.
## - **The release** waits, in the host itself, for the Runtime Control
##   callbacks in flight (event deliveries and completions) and, by running
##   on the lifecycle thread, any `apply` hook, before `_MODULE_destroy`
##   (G267).

{.push raises: [], gcsafe.}

import std/[atomics, posix]
import results
import ../abi/[checks, types]
import ../base/perthread
import ../runtime/realizer
import ../transport/io/sock
import ./[endpoint, rcbinding, state]

when defined(linux):
  proc prctl(
    option: cint, arg2: culong, arg3, arg4, arg5: culong = 0
  ): cint {.importc, header: "<sys/prctl.h>", varargs.}

  const PrSetPdeathsig = cint(1)

const
  CarrierFd = cint(3)
  ListenerFd* = cint(4)
  LockFd* = cint(5)
  FirstHighFd = cint(64)

type
  Phase = enum
    phWaiting ## no `init` yet
    phActive ## the context exists
    phFailed ## the initialization failed: only the end is left
    phReleased

  Lifecycle = object
    phase: Phase
    binding: ref NativeBinding
    context: ptr LogosModuleContext
    live: bool ## the startup handoff declared live reconfiguration

var
  lifeCh: ptr Channel[seq[byte]]
  lifeThread: Thread[void]
  maxPayloadDepth: int ## [plan §2.7] what `init` carried, for the endpoint's checks

# Lane 0: the lifecycle thread ------------------------------------------------------------

func initFailed(
    id: uint64, e: LoaderError, phase: LcnCarrierInitFailedPhaseChoiceKind
): LcnCarrierMessage =
  type C = LcnCarrierInitFailedCodeChoiceKind
  let code =
    case e.code
    of lecAbiInvalid: C.Abi_invalid
    of lecArtifactUnavailable: C.Artifact_unavailable
    else: C.Realization_failed
  var f = LcnCarrierInitFailed(
    id: id,
    code: LcnCarrierInitFailedCodeChoice(kind: code),
    message: e.message,
    phase: LcnCarrierInitFailedPhaseChoice(kind: phase),
  )
  if e.cause.isSome:
    f.cause = Opt.some(toCarrier(e.cause.get))
  toMessage(f)

proc initialize(life: var Lifecycle, m: LcnCarrierInit) =
  ## [SPEC LOADER §6 steps 5-8; plan §2.5 step 8] Bind, then the one
  ## `_MODULE_init` call. The host is ended by the Runtime after a failure.
  type P = LcnCarrierInitFailedPhaseChoiceKind
  life.phase = phFailed
  template refuse(e: LoaderError, phase: P) =
    # Terminal: the Runtime ends the host; the carrier's end is expected.
    hs.stopping.store(true)
    send(initFailed(m.id, e, phase))
    return

  maxPayloadDepth = int(min(m.max_payload_depth, uint64(high(int32))))
  let code = mapStaged(m.artifact_path).valueOr:
    refuse(error, P.Bind)
  let b = completeProbe(code, probeCode(code, m.module), false).valueOr:
    refuse(error, P.Bind)
  checkLive(m.live, b[]).isOkOr:
    refuse(error, P.Bind)
  let (rc, publish, publishUserData, access) = hostServices()
  let services = InitServices(
    runtimeControl: rc,
    publish: publish,
    publishUserData: publishUserData,
    invocationAccess: access,
  )
  # The state directory and the configuration stay here until init returns.
  let stateDir = m.state_dir.get("")
  var configuration = m.configuration.get(@[])
  if m.configuration.isSome and configuration.len == 0:
    configuration.add(0) # [IMPL] present but empty: a non-null pointer, length 0
  var input = initInputFor(
    services,
    (if m.state_dir.isSome: cstring(stateDir) else: nil),
    (
      if m.configuration.isSome:
        cast[ptr UncheckedArray[uint8]](addr configuration[0])
      else:
        nil
    ),
    m.configuration.get(@[]).len,
    b.declaresEvents,
  ).valueOr:
    refuse(error, P.Bind)
  let (res, ctx) = initModule(b.init, addr input)
  let (outcome, returnedOk) = checkInit(res, ctx)
  if outcome.isErr:
    if returnedOk and ctx != nil:
      # [IMPL; realizer `completeInitChecked`] LOGOS_OK with an invalid
      # status: the instance exists and is destroyed exactly once.
      b.destroy(ctx)
    refuse(initFailure(outcome.error), P.Init)
  if m.endpoint.isSome:
    # [SPEC LOADER §5.3; RUN-0200, TRN-0184-TRN-0186] The provider's endpoint
    # is served from the listener the Runtime made before `initialized`; one
    # that cannot be served ends the realization, its context destroyed.
    let served =
      if not b.provider:
        Result[void, string].err("the module provides no contract to serve")
      elif m.transport.isNone or m.runtime_id.isNone:
        Result[void, string].err("the endpoint's transport limits are missing")
      else:
        serveEndpoint(
          b, ctx, access.state, m.module, m.endpoint.get, m.runtime_id.get,
          m.transport.get, ListenerFd, maxPayloadDepth,
        )
    if served.isErr:
      b.destroy(ctx)
      refuse(
        loaderError(
          lecRealizationFailed, "the endpoint cannot be served: " & served.error
        ),
        P.Bind,
      )
  life.binding = b
  life.context = ctx
  life.live = m.live
  life.phase = phActive
  var done = LcnCarrierInitialized(id: m.id)
  if b.provider:
    done.call_surface = Opt.some(b.callSurface)
  send(toMessage(done))

proc apply(life: var Lifecycle, m: LcnCarrierApply) =
  ## [SPEC LOADER §8; CONFIG §6] The hook once on the context; its status as
  ## the Loader reads it (`readStatus`).
  let p =
    if m.configuration.len == 0:
      nil
    else:
      cast[ptr UncheckedArray[uint8]](unsafeAddr m.configuration[0])
  let res =
    life.binding.applyConfiguration(life.context, p, csize_t(m.configuration.len))
  var a = LcnCarrierApplied(id: m.id)
  readStatus(res).isOkOr:
    a.failure = Opt.some(toCarrier(error))
  send(toMessage(a))

proc release(life: var Lifecycle, m: LcnCarrierRelease) =
  ## [SPEC LOADER §9 (LDR-0119)] `_MODULE_destroy` exactly once, then
  ## `released` and a clean exit.
  if life.phase == phActive:
    # [IMPL-DECISION G267] The host itself waits before `_MODULE_destroy`,
    # whatever the Runtime already waited for: the dispatched calls
    # (`stopServing`) and its Runtime Control callbacks (`awaitCallbacks`). A
    # pending `apply` hook ran on this thread before the release was read.
    stopServing()
    awaitCallbacks()
    life.binding.destroy(life.context)
    life.context = nil
  life.phase = phReleased
  hs.stopping.store(true)
  send(toMessage(LcnCarrierReleased(id: m.id)))
  exitnow(0)

proc lifecycleLoop() =
  markHostThread()
  var life = Lifecycle()
  type K = LcnCarrierMessageKind
  while true:
    var f: seq[byte]
    try:
      f = lifeCh[].recv()
    except Exception:
      carrierLost("the lifecycle queue failed")
    let m = decodeMessage(f).valueOr:
      carrierLost("a lane-0 frame does not decode")
    case m.kind
    of K.lcn_Carrier_init:
      if life.phase != phWaiting:
        carrierLost("a second init")
      life.initialize(m.arm_lcn_Carrier_init)
    of K.lcn_Carrier_apply:
      # [SPEC LOADER l.533 (LDR-0113)] The Loader refuses an apply for a
      # startup-only realization: one here calls no hook.
      if life.phase != phActive or not life.live:
        carrierLost("an apply with no live instance")
      life.apply(m.arm_lcn_Carrier_apply)
    of K.lcn_Carrier_release:
      if life.phase notin {phActive, phFailed}:
        carrierLost("a release with no realization")
      life.release(m.arm_lcn_Carrier_release)
    else:
      carrierLost("an unexpected lane-0 message")

proc lifecycleMain() {.thread.} =
  lifecycleLoop()
  releasePerThread()

# The carrier loop ------------------------------------------------------------------------

proc route(f: seq[byte]) =
  ## Main thread: one frame to whoever handles its kind.
  let m = decodeMessage(f).valueOr:
    # [SPEC INTERFACE l.395] Not the codec's text: its path may hold a value
    # from the frame.
    carrierLost("a frame does not decode")
  type K = LcnCarrierMessageKind
  case m.kind
  of K.lcn_Carrier_init, K.lcn_Carrier_apply, K.lcn_Carrier_release:
    try:
      lifeCh[].send(f)
    except Exception:
      carrierLost("the lifecycle queue failed")
  of K.lcn_Carrier_rc_reply:
    let r = m.arm_lcn_Carrier_rc_reply
    answered(r.id, answerOf(r))
  of K.lcn_Carrier_rc_delivery:
    delivered(f)
  of K.lcn_Carrier_async_done:
    completed(f)
  of K.lcn_Carrier_scoped_result:
    let r = m.arm_lcn_Carrier_scoped_result
    answered(r.id, answerOf(r))
  of K.lcn_Carrier_io_admit_established, K.lcn_Carrier_io_admit_failed,
      K.lcn_Carrier_io_admit_unavailable, K.lcn_Carrier_io_respond,
      K.lcn_Carrier_io_close, K.lcn_Carrier_io_terminate, K.lcn_Carrier_io_work_ended,
      K.lcn_Carrier_io_subscription_result, K.lcn_Carrier_io_stop_serving,
      K.lcn_Carrier_admit_verdict, K.lcn_Carrier_call_cancel:
    # [K38 interim] In the order the Runtime gave, on one thread: a verdict,
    # a cancellation and a session order apply as they came.
    order(f)
  else:
    carrierLost("an unexpected message: " & $m.kind)

proc carrierLoop() {.noreturn.} =
  var reader = newCarrierReader()
  var frames: seq[seq[byte]]
  while true:
    var p = TPollfd(fd: hs.fd, events: POLLIN)
    discard posix.poll(addr p, 1, -1)
    let (outcome, why) = readFrames(hs.fd, reader, frames)
    for f in frames:
      route(f)
    frames.setLen(0)
    case outcome
    of roFrames:
      discard
    of roClosed:
      if hs.stopping.load:
        exitnow(0)
      carrierLost(why)
    of roFailed:
      carrierLost(why)

# Startup ---------------------------------------------------------------------------------

proc notStarted(why: string) {.noreturn.} =
  try:
    stderr.writeLine("logos-module-host: " & why & "; it is started by a Module Loader")
  except IOError:
    discard
  exitnow(ExitNotStartedByLoader)

proc carrierFd(): cint =
  ## [plan §2.2 step 3] fd 3, a connected local stream socket, moved to a
  ## close-on-exec descriptor above 64.
  var typ, domain, listening: cint
  if sockInfo(CarrierFd, addr typ, addr domain, addr listening) != 0:
    notStarted("fd 3 is not a socket")
  if typ != sock.SockStream or domain != sock.AfUnix or listening != 0:
    notStarted("fd 3 is not a connected local stream socket")
  result = fcntl(CarrierFd, F_DUPFD_CLOEXEC, FirstHighFd)
  if result < 0:
    notStarted("fd 3 cannot be moved")
  discard posix.close(CarrierFd)
  if setNonblock(result) < 0:
    notStarted("the carrier cannot be made non-blocking")

proc keepPrivate(fd: cint) =
  ## [plan §2.2 steps 4-5] Kept, and not inherited by a module's children. A
  ## number the Runtime left closed is held on /dev/null, so no descriptor the
  ## host opens later takes it and is served as the listener or kept as the
  ## lock [IMPL].
  if fcntl(fd, F_GETFD) >= 0:
    discard fcntl(fd, F_SETFD, FD_CLOEXEC)
    return
  let n = posix.open("/dev/null", O_RDONLY or O_CLOEXEC)
  if n < 0:
    notStarted("fd " & $fd & " cannot be held")
  if n != fd:
    let d = dup2(n, fd)
    discard posix.close(n)
    if d < 0:
      notStarted("fd " & $fd & " cannot be held")
    discard fcntl(fd, F_SETFD, FD_CLOEXEC)

proc runHost*() {.noreturn.} =
  ## The whole program.
  discard signal(SIGPIPE, SIG_IGN)
  when defined(linux):
    let parent = getppid()
    discard prctl(PrSetPdeathsig, culong(SIGKILL))
    if getppid() != parent:
      exitnow(ExitCarrierLost) # [IMPL] the daemon ended before the signal was set
  keepPrivate(ListenerFd)
  keepPrivate(LockFd)
  let fd = carrierFd()
  initHostShared(fd)
  initBinding()
  lifeCh = createShared(Channel[seq[byte]])
  lifeCh[].open()
  try:
    createThread(lifeThread, lifecycleMain)
  except Exception:
    carrierLost("the lifecycle thread cannot start")
  carrierLoop()
