## The logosctl module (Tier 4b step 4b-6; DECISIONS G296; D13(a); G83 redo;
## K20; BOOTSTRAP l.384-390). docs/DAEMON.md §7.
##
## A consumer-only `direct_static` module (`logosctl`, binding `logosctl`):
## its instance serves the owner's socket and makes each command's Runtime
## Control call through its own binding (RUNTIME l.182-184, l.1604). Nothing
## from the socket stands for the consumer: no binding, ticket or invocation
## material crosses it, and no method payload or event is relayed.
##
## - **Presentation handoff.** Before `runtimeStart`, logosd calls
##   `setPresentation`: the socket path, the worker count and idle timeout,
##   the deployment designation, the trust revision, the version and the start
##   time, in a process-global under a lock. It creates no participant and
##   changes no Runtime-owned semantics; without it `_MODULE_init` fails, so
##   the binding does nothing in any host but logosd.
## - **Init.** Binds the socket (0600, backlog 64), starts the accept thread
##   and the workers, then sets `serving` as its last step: a connection
##   admitted earlier waits for it, so no command runs before `_MODULE_init`
##   returned (BCP l.388).
## - **Admission** (K20). The peer's uid must be this process's effective
##   uid; another is closed with no byte written and logged, at most one line
##   a second. Uid and pid are kept as provenance in the log lines only.
## - **Workers.** At most `workers` connections are admitted at once; another
##   is answered `busy`. A worker serves one connection's requests in
##   sequence until EOF or `idle_timeout_ms` without a complete request.
## - **Dispatch.** `daemon-info` makes one `get_self` call. `rc` makes exactly
##   one call of the named method with the given bytes, its deadline the
##   command's (at most 60 s), and returns the response bytes verbatim, or the
##   error channel's code, message and detail. The module neither decodes nor
##   checks `params`: the Runtime does, as for any consumer.
## - **Destroy.** Sets `closing`, unlinks the socket, shuts down each
##   connection waiting for a request, cancels calls in flight, and joins
##   every thread. A worker writing an answer finishes it first, so a
##   `shutdown_runtime` command gets its answer.

{.push raises: [], gcsafe.}

import std/[atomics, locks, monotimes, os, times]
import results
import ../abi/[checks, types]
import ../base/[perthread, testhooks]
import ../iface/outcome
from ../kit/rcclient import checkBinding, `$`
import ../runtime/[bell, rc_types]
import ../transport/io/[peercred, sock]
import ./[ctlwire, logging, logosctl_kit]

when defined(posix):
  import std/posix except Stat

export results

testHooksMarker("ctlmodule")

const
  Backlog = 64
  MaxDeadlineMs* = 60_000 ## [IMPL] a command's Runtime Control call, at most
  SocketMode = 0o600
  RefusalLogEveryMs = 1_000
  WakeSliceMs = 50

# Shared memory ----------------------------------------------------------------------

type SharedBuf = object ## Bytes in shared memory: any thread may read them.
  data: ptr UncheckedArray[byte]
  len: int

proc shareRaw(p: pointer, len: int): SharedBuf =
  if len > 0:
    result.data = cast[ptr UncheckedArray[byte]](allocShared(len))
    copyMem(result.data, p, len)
    result.len = len

proc share(b: openArray[byte]): SharedBuf =
  if b.len > 0:
    shareRaw(unsafeAddr b[0], b.len)
  else:
    SharedBuf()

proc share(s: string): SharedBuf =
  if s.len > 0:
    shareRaw(unsafeAddr s[0], s.len)
  else:
    SharedBuf()

proc bytesOf(b: SharedBuf): seq[byte] =
  result = newSeq[byte](b.len)
  if b.len > 0:
    copyMem(addr result[0], b.data, b.len)

proc textOf(b: SharedBuf): string =
  result = newString(b.len)
  if b.len > 0:
    copyMem(addr result[0], b.data, b.len)

proc free(b: var SharedBuf) =
  if b.data != nil:
    deallocShared(b.data)
  b = SharedBuf()

# The presentation handoff -----------------------------------------------------------

type Presentation* = object ## [G296] What logosd hands the module before start.
  socketPath*: string
  workers*: int
  idleTimeoutMs*: int
  production*: bool ## the deployment designation (D27's switch off)
  trustRevision*: uint64
  version*: string
  startedAtMs*: uint64

type Handoff = object
  present: bool
  socketPath, version: SharedBuf
  workers, idleTimeoutMs: int
  production: bool
  trustRevision, startedAtMs: uint64

var
  handoffLock: Lock
  handoff: Handoff

initLock(handoffLock)

proc clearPresentation*() =
  withLock handoffLock:
    free(handoff.socketPath)
    free(handoff.version)
    handoff = Handoff()

proc setPresentation*(p: Presentation) =
  ## [G296] logosd's handoff, before `runtimeStart`.
  clearPresentation()
  withLock handoffLock:
    handoff = Handoff(
      present: true,
      socketPath: share(p.socketPath),
      version: share(p.version),
      workers: p.workers,
      idleTimeoutMs: p.idleTimeoutMs,
      production: p.production,
      trustRevision: p.trustRevision,
      startedAtMs: p.startedAtMs,
    )

proc presentation*(): Opt[Presentation] =
  withLock handoffLock:
    if not handoff.present:
      return Opt.none(Presentation)
    return Opt.some(
      Presentation(
        socketPath: textOf(handoff.socketPath),
        version: textOf(handoff.version),
        workers: handoff.workers,
        idleTimeoutMs: handoff.idleTimeoutMs,
        production: handoff.production,
        trustRevision: handoff.trustRevision,
        startedAtMs: handoff.startedAtMs,
      )
    )

# Test hooks -------------------------------------------------------------------------

var credFn: Atomic[pointer] ## a `CredFn`; nil: `peerOf`

when defined(lcnTestHooks):
  var
    commandDelayMs: Atomic[int]
    initHeld: Atomic[bool]
    initWaiting: Atomic[bool]

  proc setCommandDelayForTests*(ms: int) =
    ## [G300] `test_hooks.ctl_command_delay_ms`: each command waits this long
    ## before its call.
    commandDelayMs.store(ms)

  proc holdInitForTests*(held: bool) =
    ## Holds `_MODULE_init` after its threads started and before `serving`.
    initHeld.store(held)

  proc initWaitingForTests*(): bool =
    initWaiting.load

  proc setCredOfForTests*(f: CredFn) =
    ## The peer credentials the accept thread reads; nil restores `peerOf`.
    credFn.store(cast[pointer](f))

proc credOf(fd: cint): Result[Peer, string] =
  let f = credFn.load
  if f.isNil:
    peerOf(fd)
  else:
    cast[CredFn](f)(fd)

# The server -------------------------------------------------------------------------

type
  Conn = object
    fd: cint
    uid: uint32
    pid: int32 ## -1: unknown

  Server = object
    lock: Lock
    cond: Cond
    rc: ptr LogosRuntimeControlBinding
    listenFd, wakeR, wakeW: cint
    dev, ino: uint64 ## the bound socket's identity, for the unlink
    path, version: SharedBuf
    production: bool
    trustRevision, startedAtMs: uint64
    idleTimeoutMs, workers: int
    queue: ptr UncheckedArray[Conn]
    qHead, qLen, inService: int
    reading: ptr UncheckedArray[cint]
      ## per worker: a connection awaiting a request, or -1
    serving, closing: bool
    acceptThread: Thread[ptr Server]
    workerThreads: ptr UncheckedArray[Thread[(ptr Server, int)]]
    started: int ## worker threads started
    acceptStarted: bool
    lastRefusal: MonoTime
    quiet: int ## refusals not logged since the last line

  CtlServer* = ref object ## The module instance.
    s: ptr Server

proc isClosing(s: ptr Server): bool =
  withLock s.lock:
    result = s.closing

proc pidText(pid: int32): string =
  if pid >= 0:
    $pid
  else:
    "unknown"

proc logRefusal(s: ptr Server, text: string) =
  ## At most one line a second; the count of those skipped goes in the next.
  var line = ""
  withLock s.lock:
    let now = getMonoTime()
    if inMilliseconds(now - s.lastRefusal) >= RefusalLogEveryMs:
      line = text
      if s.quiet > 0:
        line.add(" (" & $s.quiet & " more not logged)")
      s.quiet = 0
      s.lastRefusal = now
    else:
      inc s.quiet
  if line.len > 0:
    logWarn("logosctl: " & line)

proc send(s: ptr Server, fd: cint, r: LcnCtlReply): Result[void, string] =
  let bytes = ?r.encode
  writeFrame(fd, bytes, s.idleTimeoutMs)

# Runtime Control calls --------------------------------------------------------------

type
  CallSlot = object
    bell: Bell
    lock: Lock
    done: bool
    code: ErrorCode
    response, message, detail: SharedBuf
    hasMessage, hasDetail: bool

  Outcome = object
    code: ErrorCode
    response: seq[byte]
    message: Opt[string]
    detail: Opt[seq[byte]]

proc newSlot(): ptr CallSlot =
  result = cast[ptr CallSlot](allocShared0(sizeof(CallSlot)))
  initLock(result.lock)
  result.bell = newBell()

proc freeSlot(slot: ptr CallSlot) =
  free(slot.response)
  free(slot.message)
  free(slot.detail)
  freeBell(slot.bell)
  deinitLock(slot.lock)
  deallocShared(slot)

proc onComplete(
    userData: pointer,
    status: LogosResult,
    response: ptr UncheckedArray[uint8],
    responseLen: csize_t,
    owner: LogosResponseOwner,
) {.cdecl, gcsafe, raises: [].} =
  ## [SPEC INTERFACE §2.9.1, §2.9.2] Copies the outcome into shared memory
  ## and releases the owner; nothing the collector owns outlives it, so it
  ## may run on any Runtime thread.
  let slot = cast[ptr CallSlot](userData)
  var code = ecOk
  var resp, msg, det: SharedBuf
  var hasM, hasD = false
  let st = checkOutcome(status, completionShape(response, responseLen, owner))
  if st.isErr:
    code = st.error.code
    if st.error.message.isSome:
      msg = share(st.error.message.get)
      hasM = true
    if st.error.detail.isSome:
      det = share(st.error.detail.get)
      hasD = true
  elif response != nil and responseLen > 0:
    resp = shareRaw(response, int(responseLen))
  if ownerValid(owner) and owner.release != nil:
    owner.release(owner.state)
  withLock slot.lock:
    slot.code = code
    slot.response = resp
    slot.message = msg
    slot.detail = det
    slot.hasMessage = hasM
    slot.hasDetail = hasD
    slot.done = true
  slot.bell.ring()

func failed(f: AbiFailure): Outcome =
  Outcome(code: f.code, message: f.message, detail: f.detail)

proc rcCall(s: ptr Server, bare: string, params: seq[byte], deadlineMs: int): Outcome =
  ## One asynchronous call through the module's own binding, waited for. A
  ## call in flight when the module starts closing is cancelled.
  let slot = newSlot()
  var call = LogosAsyncCall()
  var options = LogosAsyncOptions(
    abiVersion: AsyncCallAbiVersion,
    structSize: csize_t(sizeof(LogosAsyncOptions)),
    hasTimeout: true,
    timeoutMs: uint64(deadlineMs),
  )
  var callbacks = LogosAsyncCallbacks(
    abiVersion: AsyncCallAbiVersion,
    structSize: csize_t(sizeof(LogosAsyncCallbacks)),
    complete: onComplete,
    userData: slot,
  )
  let p =
    if params.len == 0:
      nil
    else:
      cast[ptr UncheckedArray[uint8]](unsafeAddr params[0])
  let r = s.rc.vtable.prepareCall(
    s.rc, cstring(bare), p, csize_t(params.len), addr options, addr callbacks, addr call
  )
  let shaped = checkOutcome(r, handleShape(call.vtable, call.state))
  if shaped.isErr:
    if int64(r.code) == 0 and call.vtable != nil and call.state != nil and
        checkAsyncCall(addr call).isOk:
      call.vtable.release(addr call)
    freeSlot(slot)
    return failed(shaped.error)
  let checked = checkAsyncCall(addr call)
  if checked.isErr:
    freeSlot(slot)
    return failed(checked.error)
  call.vtable.submit(addr call)
  var cancelled = false
  while true:
    var done = false
    withLock slot.lock:
      done = slot.done
    if done:
      break
    if not cancelled and s.isClosing:
      call.vtable.cancel(addr call)
      cancelled = true
    slot.bell.wait(Opt.some(getMonoTime() + initDuration(milliseconds = WakeSliceMs)))
  call.vtable.release(addr call)
  result = Outcome(code: slot.code, response: bytesOf(slot.response))
  if slot.hasMessage:
    result.message = Opt.some(textOf(slot.message))
  if slot.hasDetail:
    result.detail = Opt.some(bytesOf(slot.detail))
  freeSlot(slot)

proc replyOf(s: ptr Server, o: Outcome): LcnCtlReply =
  if o.code == ecOk:
    okReply(
      s.production,
      if o.response.len > 0:
        Opt.some(o.response)
      else:
        Opt.none(seq[byte]),
    )
  else:
    rcErrorReply(s.production, uint8(ord(o.code)), o.message, o.detail)

proc daemonInfo(s: ptr Server): (LcnCtlReply, string) =
  let params = LogosNSRuntimeControlGetSelfRequest().encode.valueOr:
    return (
      rcErrorReply(
        s.production, uint8(ord(ecModule)), Opt.some(error), Opt.none(seq[byte])
      ),
      $ecModule,
    )
  let o = rcCall(s, "get_self", params, MaxDeadlineMs)
  if o.code != ecOk:
    return (replyOf(s, o), $o.code)
  let me = LogosNSRuntimeControlGetSelfResponse.decode(o.response).valueOr:
    let m = "the get_self response does not decode: " & error
    return (
      rcErrorReply(s.production, uint8(ord(ecModule)), Opt.some(m), Opt.none(seq[byte])),
      $ecModule,
    )
  let info = LcnCtlDaemonInfo(
    version: textOf(s.version),
    runtime_instance_id: me.consumer.runtime_instance_id,
    trust_revision: s.trustRevision,
    started_at_ms: s.startedAtMs,
    socket: textOf(s.path),
  )
  let bytes = info.encode.valueOr:
    return (
      rcErrorReply(
        s.production, uint8(ord(ecModule)), Opt.some(error), Opt.none(seq[byte])
      ),
      $ecModule,
    )
  (okReply(s.production, Opt.some(bytes)), "ok")

proc delay() =
  when defined(lcnTestHooks):
    let ms = commandDelayMs.load
    if ms > 0:
      let until = getMonoTime() + initDuration(milliseconds = ms)
      while getMonoTime() < until:
        let left = min(WakeSliceMs, int(inMilliseconds(until - getMonoTime())))
        if left > 0:
          sleep(left)

proc dispatch(s: ptr Server, m: LcnCtlMessage, c: Conn): LcnCtlReply =
  ## [G296; BCP l.392] One command, one call; the request bytes are the
  ## shell's, the call the module's own.
  delay()
  var what, outcome: string
  case m.command.kind
  of LcnCtlCommandKind.lcn_Ctl_info_command:
    what = "daemon-info"
    (result, outcome) = daemonInfo(s)
  of LcnCtlCommandKind.lcn_Ctl_rc_command:
    let rc = m.command.arm_lcn_Ctl_rc_command
    what = methodName(rc.`method`.kind)
    let deadline =
      clamp(int(rc.deadline_ms.get(uint32(MaxDeadlineMs))), 1, MaxDeadlineMs)
    let o = rcCall(s, what, rc.params, deadline)
    result = replyOf(s, o)
    outcome = $o.code
  logInfo(
    "logosctl: " & what & " from uid " & $c.uid & " pid " & pidText(c.pid) & ": " &
      outcome
  )

proc serve(s: ptr Server, worker: int, c: Conn) =
  var first = true
  while true:
    var closing = false
    withLock s.lock:
      closing = s.closing
      if not closing:
        s.reading[worker] = c.fd
    if closing:
      discard
        s.send(c.fd, refusedReply(s.production, LcnCtlRefusedReasonChoiceKind.Closing))
      return
    let frame = readFrame(c.fd, s.idleTimeoutMs)
    withLock s.lock:
      s.reading[worker] = -1
    if frame.isErr:
      if frame.error.kind == feTooLarge:
        logWarn(
          "logosctl: refused a frame from uid " & $c.uid & ": " & frame.error.message
        )
        discard s.send(
          c.fd,
          refusedReply(
            s.production, LcnCtlRefusedReasonChoiceKind.Too_large, frame.error.message
          ),
        )
      return
    if first:
      # [BCP l.388] No command before `_MODULE_init` returned.
      withLock s.lock:
        while not s.serving and not s.closing:
          wait(s.cond, s.lock)
      first = false
    let m = decodeMessage(frame.get).valueOr:
      logWarn(
        "logosctl: refused a frame from uid " & $c.uid & " pid " & pidText(c.pid) & ": " &
          reasonOf(error.reason)
      )
      discard s.send(c.fd, refusedReply(s.production, error.reason, error.message))
      return
    let reply = dispatch(s, m, c)
    if s.send(c.fd, reply).isErr:
      return

proc workerMain(arg: (ptr Server, int)) {.thread.} =
  let (s, worker) = arg
  while true:
    var c = Conn(fd: -1)
    withLock s.lock:
      while s.qLen == 0 and not s.closing:
        wait(s.cond, s.lock)
      if s.qLen > 0:
        c = s.queue[s.qHead]
        s.qHead = (s.qHead + 1) mod s.workers
        dec s.qLen
        inc s.inService
    if c.fd < 0:
      break
    serve(s, worker, c)
    withLock s.lock:
      dec s.inService
    discard fdClose(c.fd)
  releasePerThread()

proc admit(s: ptr Server, fd: cint) =
  ## [K20; BCP l.385, l.389] The owner's uid, or closed with nothing written.
  let peer = credOf(fd)
  if peer.isErr or peer.get.uid != effectiveUid():
    let who =
      if peer.isErr:
        "a connection whose credentials are unreadable (" & peer.error & ")"
      else:
        "a connection from uid " & $peer.get.uid & " pid " &
          pidText(peer.get.pid.get(-1))
    discard fdClose(fd)
    s.logRefusal("refused " & who)
    return
  var verdict = 0 # 0 admitted, 1 busy, 2 closing
  withLock s.lock:
    if s.closing:
      verdict = 2
    elif s.qLen + s.inService >= s.workers:
      verdict = 1
    else:
      s.queue[(s.qHead + s.qLen) mod s.workers] =
        Conn(fd: fd, uid: peer.get.uid, pid: peer.get.pid.get(-1))
      inc s.qLen
      signal(s.cond)
  if verdict == 0:
    return
  let reason =
    if verdict == 1:
      LcnCtlRefusedReasonChoiceKind.Busy
    else:
      LcnCtlRefusedReasonChoiceKind.Closing
  discard s.send(fd, refusedReply(s.production, reason))
  discard fdClose(fd)

proc acceptMain(s: ptr Server) {.thread.} =
  when defined(posix):
    while true:
      var fds =
        [TPollfd(fd: s.listenFd, events: POLLIN), TPollfd(fd: s.wakeR, events: POLLIN)]
      let n = poll(addr fds[0], 2, -1)
      if n < 0:
        if errno == EINTR:
          continue
        logError("logosctl: poll: " & $strerror(errno))
        break
      if fds[1].revents != 0 or s.isClosing:
        break
      let fd = sockAccept(s.listenFd)
      if fd < 0:
        if not wouldBlock(fd):
          s.logRefusal("accept: " & $strerror(cint(-fd)))
        continue
      admit(s, fd)
  releasePerThread()

# Init and destroy -------------------------------------------------------------------

proc fail(message: string): Result[CtlServer, InvocationFailure] =
  logError("logosctl: cannot start: " & message)
  err(failure(ecModule, message))

proc bindSocket(path: string): Result[(cint, uint64, uint64), string] =
  ## [IMPL] The socket at `path`, 0600, listening. Anything already there is
  ## refused, never followed or removed: `run/` was emptied at start.
  when defined(posix):
    if not fitsSunPath(path):
      return err(path & " does not fit sun_path (" & $(sunPathMax() - 1) & " bytes)")
    var st: StatInfo
    if lstatPath(cstring(path), addr st) == 0:
      return err(path & " already exists")
    let fd = unixSocket()
    if fd < 0:
      return err("socket: " & $strerror(cint(-fd)))
    let b = sockBind(fd, cstring(path))
    if b < 0:
      discard fdClose(fd)
      return err(path & ": bind: " & $strerror(cint(-b)))
    if chmod(cstring(path), Mode(SocketMode)) != 0:
      let e = $strerror(errno)
      discard unlink(cstring(path))
      discard fdClose(fd)
      return err(path & ": chmod: " & e)
    if lstatPath(cstring(path), addr st) != 0 or not st.isSocket:
      discard fdClose(fd)
      return err(path & " is not the socket just bound")
    let l = sockListen(fd, Backlog)
    if l < 0:
      discard unlink(cstring(path))
      discard fdClose(fd)
      return err(path & ": listen: " & $strerror(cint(-l)))
    ok((fd, st.dev, st.ino))
  else:
    err("logosctl's socket is not supported on this platform")

proc unlinkOwn(s: ptr Server) =
  ## Removes the socket if it is still the one bound.
  when defined(posix):
    let path = textOf(s.path)
    var st: StatInfo
    if lstatPath(cstring(path), addr st) == 0 and st.isSocket and st.dev == s.dev and
        st.ino == s.ino:
      discard unlink(cstring(path))

proc freeServer(s: ptr Server) =
  free(s.path)
  free(s.version)
  if s.queue != nil:
    deallocShared(s.queue)
  if s.reading != nil:
    deallocShared(s.reading)
  if s.workerThreads != nil:
    deallocShared(s.workerThreads)
  deinitCond(s.cond)
  deinitLock(s.lock)
  deallocShared(s)

proc stop(s: ptr Server) =
  ## Ends every thread the server started; see the module's doc.
  withLock s.lock:
    s.closing = true
    for i in 0 ..< s.workers:
      if s.reading[i] >= 0:
        when defined(posix):
          discard shutdown(SocketHandle(s.reading[i]), SHUT_RDWR)
    broadcast(s.cond)
  unlinkOwn(s)
  when defined(posix):
    var one = [byte(1)]
    discard write(s.wakeW, addr one[0], 1)
  if s.acceptStarted:
    joinThread(s.acceptThread)
  for i in 0 ..< s.started:
    joinThread(s.workerThreads[i])
  withLock s.lock:
    while s.qLen > 0:
      discard fdClose(s.queue[s.qHead].fd)
      s.qHead = (s.qHead + 1) mod s.workers
      dec s.qLen
  discard fdClose(s.listenFd)
  discard fdClose(s.wakeR)
  discard fdClose(s.wakeW)

proc initModule(
    _: type CtlServer, init: ModuleInit
): Result[CtlServer, InvocationFailure] =
  let p = presentation().valueOr:
    return fail("no presentation: the logosctl module runs only under logosd")
  checkBinding(init.services.runtimeControl).isOkOr:
    return fail("the Runtime Control binding: " & $error)
  if p.workers < 1:
    return fail("no workers")
  let (fd, dev, ino) = bindSocket(p.socketPath).valueOr:
    return fail(error)
  var pipeFds: array[2, cint]
  when defined(posix):
    if pipe(pipeFds) != 0:
      let e = $strerror(errno)
      discard unlink(cstring(p.socketPath))
      discard fdClose(fd)
      return fail("pipe: " & e)
    for f in pipeFds:
      discard fcntl(f, F_SETFD, FD_CLOEXEC)
  let s = cast[ptr Server](allocShared0(sizeof(Server)))
  initLock(s.lock)
  initCond(s.cond)
  s.rc = init.services.runtimeControl
  s.listenFd = fd
  s.dev = dev
  s.ino = ino
  s.wakeR = pipeFds[0]
  s.wakeW = pipeFds[1]
  s.path = share(p.socketPath)
  s.version = share(p.version)
  s.production = p.production
  s.trustRevision = p.trustRevision
  s.startedAtMs = p.startedAtMs
  s.idleTimeoutMs = p.idleTimeoutMs
  s.workers = p.workers
  s.queue = cast[ptr UncheckedArray[Conn]](allocShared0(sizeof(Conn) * p.workers))
  s.reading = cast[ptr UncheckedArray[cint]](allocShared0(sizeof(cint) * p.workers))
  for i in 0 ..< p.workers:
    s.reading[i] = -1
  s.workerThreads = cast[ptr UncheckedArray[Thread[(ptr Server, int)]]](allocShared0(
    sizeof(Thread[(ptr Server, int)]) * p.workers
  ))
  s.lastRefusal = getMonoTime() - initDuration(seconds = 2)
  try:
    createThread(s.acceptThread, acceptMain, s)
    s.acceptStarted = true
    for i in 0 ..< p.workers:
      createThread(s.workerThreads[i], workerMain, (s, i))
      inc s.started
  except ResourceExhaustedError as e:
    stop(s)
    freeServer(s)
    return fail("cannot start a thread: " & e.msg)
  when defined(lcnTestHooks):
    while initHeld.load:
      initWaiting.store(true)
      sleep(5)
    initWaiting.store(false)
  withLock s.lock:
    s.serving = true # [BCP l.388] init's last step
    broadcast(s.cond)
  logInfo("logosctl: serving " & p.socketPath)
  ok(CtlServer(s: s))

proc destroyModule(m: CtlServer) =
  if m.s != nil:
    stop(m.s)
    freeServer(m.s)
    m.s = nil

exportLogosctl(CtlServer)

proc ctlStaticSymbols*(): seq[(string, pointer)] =
  ## The `logosctl` binding's symbols, for `runtimeRegisterBinding`.
  logosctlStaticSymbols()

{.pop.}
