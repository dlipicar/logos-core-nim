## The lcn_call instance (Tier 5 step N-2; DECISIONS G343, G344;
## BOOTSTRAP l.389-395, l.524-526). docs/DAEMON.md §7a.
##
## A consumer-only `hosted_dynamic` module: its instance serves the owner's
## launcher socket and makes each command's calls through its own binding, as
## the consumer (RUNTIME l.173-175). Payloads pass between this process and
## the provider's; never through logosd. Nothing from the socket stands for
## the consumer: no binding, ticket or route crosses it.
##
## - **Init.** Reads its settings (`lcn_call.settings`, provisioned by
##   logosd), binds the socket (0600, backlog 64; a stale socket of this uid at
##   the path is removed, anything else refused), starts the accept thread, the
##   workers and the route reaper, then sets `serving` as its last step: a
##   command admitted earlier waits for it (BCP l.393).
## - **Admission** (G344). The peer's uid must be this process's effective
##   uid; another is closed with no byte written and logged, at most one line
##   a second. Uid and pid are kept as provenance in the log line only.
## - **Slots.** `workers` one-shot commands and `streams` streams at once. A
##   connection is taken while a thread is free; once its request is read, a
##   command whose kind has no free slot is refused `busy`.
## - **One command per connection** (G344): the request and its descriptors,
##   `accepted`, the command, the descriptors closed, then `done`. The
##   launcher's half-close cancels the command (130).
## - **Destroy.** Sets `closing`, unlinks the socket, shuts down the read side
##   of every connection (its command sees the cancel; a stream ends with 6,
##   since lcn_call ended it), joins every thread, then releases every route
##   handle and closes every route (IF l.3927).

{.push raises: [], gcsafe.}

import std/[atomics, locks, monotimes, times]
import results
import logos_sdk/abi/types
import logos_sdk/base/[perthread, testhooks, wipe]
import logos_sdk/codegen/kitrt
from logos_sdk/codegen/nimrt import wipeTyped
import logos_sdk/iface/outcome
from logos_sdk/kit/rcclient import checkBinding, `$`
import ../runtime/bell
import ../transport/io/[peercred, sock]
import ../daemon/logging
import
  ./[
    cli_types, commands, lcn_call_configuration_types, lcn_call_kit, routes, streams,
    wire,
  ]

when defined(posix):
  import std/posix except Stat

export results

testHooksMarker("lcn_call")

const
  Backlog = 64
  SocketMode = 0o600
  RefusalLogEveryMs = 1_000
  ReapEveryMs = 1_000
  MaxWorkers* = 32 ## [G344] `cli.workers`
  MaxStreams* = 64 ## [G344] `cli.streams`

type SharedBuf = object
  data: ptr UncheckedArray[byte]
  len: int

proc share(s: string): SharedBuf =
  if s.len > 0:
    result.data = cast[ptr UncheckedArray[byte]](allocShared(s.len))
    copyMem(result.data, unsafeAddr s[0], s.len)
    result.len = s.len

proc textOf(b: SharedBuf): string =
  result = newString(b.len)
  if b.len > 0:
    copyMem(addr result[0], b.data, b.len)

proc free(b: var SharedBuf) =
  if b.data != nil:
    deallocShared(b.data)
  b = SharedBuf()

# Test hooks -------------------------------------------------------------------------

var credFn: Atomic[pointer] ## a `CredFn`; nil: `peerOf`

when defined(lcnTestHooks):
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
    env: Env
    listenFd, wakeR, wakeW: cint
    dev, ino: uint64 ## the bound socket's identity, for the unlink
    path: SharedBuf
    idleTimeoutMs, workers, streams, threads: int
    queue: ptr UncheckedArray[Conn]
    qHead, qLen, inService: int
    oneShots, streaming: int ## commands in service, by kind
    active: ptr UncheckedArray[cint] ## per thread: its connection, or -1
    serving, closing: bool
    stopping: Atomic[bool] ## set before the cancel `stop` gives every command
    acceptThread: Thread[ptr Server]
    reaperThread: Thread[ptr Server]
    reaperBell: Bell
    workerThreads: ptr UncheckedArray[Thread[(ptr Server, int)]]
    started: int ## worker threads started
    acceptStarted, reaperStarted: bool
    lastRefusal: MonoTime
    quiet: int ## refusals not logged since the last line

  CallServer* = ref object ## The module instance.
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
    logWarn("lcn_call: " & line)

proc reply(s: ptr Server, fd: cint, r: LcnCliReply) =
  discard writeReply(fd, r, s.idleTimeoutMs)

func isStream(m: LcnCliMessage): bool =
  ## [G503] `package watch` is a stream too.
  case m.command.kind
  of LcnCliCommandKind.lcn_Cli_subscribe_command,
      LcnCliCommandKind.lcn_Cli_events_command:
    true
  of LcnCliCommandKind.lcn_Cli_package_command:
    m.command.arm_lcn_Cli_package_command.action.kind == LcnCliPackageActionKind.Watch
  else:
    false

proc take(s: ptr Server, stream: bool): int =
  ## A slot for a command of this kind: 0 taken, 1 busy, 2 closing.
  withLock s.lock:
    if s.closing:
      return 2
    if stream:
      if s.streaming >= s.streams:
        return 1
      inc s.streaming
    else:
      if s.oneShots >= s.workers:
        return 1
      inc s.oneShots
  0

proc give(s: ptr Server, stream: bool) =
  withLock s.lock:
    if stream:
      dec s.streaming
    else:
      dec s.oneShots

proc serve(s: ptr Server, worker: int, c: Conn) =
  ## [G344] One command on one connection.
  var req = readRequest(c.fd, s.idleTimeoutMs, MaxRequestBytes)
  if req.isErr:
    if req.error.kind == feTooLarge:
      s.logRefusal("refused a request from uid " & $c.uid & ": " & req.error.message)
      s.reply(
        c.fd, refusedReply(LcnCliRefusedReasonChoiceKind.Too_large, req.error.message)
      )
    elif req.error.kind notin {feEof, feTimeout}:
      s.logRefusal("refused a request from uid " & $c.uid & ": " & req.error.message)
      s.reply(
        c.fd, refusedReply(LcnCliRefusedReasonChoiceKind.Protocol, req.error.message)
      )
    return
  var fds = req.get.fds
  # [BCP l.393] No command before `_MODULE_init` returned.
  withLock s.lock:
    while not s.serving and not s.closing:
      wait(s.cond, s.lock)
  # [N-2d; SPEC INTERFACE l.361, l.385] The frame and the message may hold an
  # argument's value, and which method is marked is known only later: both are
  # wiped for every request, the frame once decoded, the message on every
  # return.
  var m = decodeMessage(req.get.bytes)
  wipe(req.value.bytes)
  var job = Job(fds: fds, cancelFd: c.fd)
  if m.isOk:
    job.msg = move m.value
  defer:
    wipeTyped(job.msg)
  let checked =
    if m.isOk:
      checkMessage(job.msg, fds.len)
    else:
      Result[void, string].err(m.error)
  if checked.isErr:
    closeAll(fds)
    s.logRefusal(
      "refused a request from uid " & $c.uid & " pid " & pidText(c.pid) & ": " &
        checked.error
    )
    s.reply(c.fd, refusedReply(LcnCliRefusedReasonChoiceKind.Protocol, checked.error))
    return
  let stream = job.msg.isStream
  case s.take(stream)
  of 1:
    closeAll(fds)
    s.reply(c.fd, refusedReply(LcnCliRefusedReasonChoiceKind.Busy))
    return
  of 2:
    closeAll(fds)
    s.reply(c.fd, refusedReply(LcnCliRefusedReasonChoiceKind.Closing))
    return
  else:
    discard
  if writeReply(c.fd, acceptedReply(), s.idleTimeoutMs).isErr:
    closeAll(fds)
    s.give(stream)
    return
  let d = commands.run(s.env, job)
  closeAll(fds) # [G344] before `done`: a reader of a pipe sees its end
  s.give(stream)
  logInfo(
    "lcn_call: " & d.what & " node " & targetOf(job.msg) & " from uid " & $c.uid &
      " pid " & pidText(c.pid) & ": exit " & $d.exit &
      (if d.code.len > 0: " " & d.code else: "")
  )
  s.reply(c.fd, doneReply(d.exit))

proc workerMain(arg: (ptr Server, int)) {.thread.} =
  let (s, worker) = arg
  while true:
    var c = Conn(fd: -1)
    withLock s.lock:
      while s.qLen == 0 and not s.closing:
        wait(s.cond, s.lock)
      if s.qLen > 0 and not s.closing:
        c = s.queue[s.qHead]
        s.qHead = (s.qHead + 1) mod s.threads
        dec s.qLen
        inc s.inService
        s.active[worker] = c.fd
    if c.fd < 0:
      break
    serve(s, worker, c)
    withLock s.lock:
      dec s.inService
      s.active[worker] = -1
    discard fdClose(c.fd)
  releasePerThread()

proc admit(s: ptr Server, fd: cint) =
  ## [G344; BCP l.390, l.394] The owner's uid, or closed with nothing written.
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
    elif s.qLen + s.inService >= s.threads:
      verdict = 1
    else:
      s.queue[(s.qHead + s.qLen) mod s.threads] =
        Conn(fd: fd, uid: peer.get.uid, pid: peer.get.pid.get(-1))
      inc s.qLen
      signal(s.cond)
  if verdict == 0:
    return
  let reason =
    if verdict == 1:
      LcnCliRefusedReasonChoiceKind.Busy
    else:
      LcnCliRefusedReasonChoiceKind.Closing
  s.reply(fd, refusedReply(reason))
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
        logError("lcn_call: poll: " & $strerror(errno))
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

proc reaperMain(s: ptr Server) {.thread.} =
  ## [G348] Idle and ended routes closed, retired handles released.
  while not s.isClosing:
    s.reaperBell.wait(
      Opt.some(getMonoTime() + initDuration(milliseconds = ReapEveryMs))
    )
    if s.isClosing:
      break
    s.env.routes.reap()
  releasePerThread()

# Init and destroy -------------------------------------------------------------------

proc fail(message: string): Result[CallServer, InvocationFailure] =
  logError("lcn_call: cannot start: " & message)
  err(failure(ecModule, message))

proc bindSocket(path: string): Result[(cint, uint64, uint64), string] =
  ## [G344] The socket at `path`, 0600, listening. A socket of this uid left
  ## there by an earlier realization of this instance is removed; anything
  ## else is refused, never followed or removed.
  when defined(posix):
    if not fitsSunPath(path):
      return err(path & " does not fit sun_path (" & $(sunPathMax() - 1) & " bytes)")
    var st: StatInfo
    if lstatPath(cstring(path), addr st) == 0:
      if not st.isSocket or st.uid != effectiveUid():
        return err(path & " exists and is not a socket of this user")
      if unlink(cstring(path)) != 0:
        return err(path & ": unlink: " & $strerror(errno))
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
    err("lcn_call's socket is not supported on this platform")

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
  if s.queue != nil:
    deallocShared(s.queue)
  if s.active != nil:
    deallocShared(s.active)
  if s.workerThreads != nil:
    deallocShared(s.workerThreads)
  if s.reaperBell != nil:
    freeBell(s.reaperBell)
  deinitCond(s.cond)
  deinitLock(s.lock)
  deallocShared(s)

proc stop(s: ptr Server) =
  ## Ends every thread the server started; see the module's doc.
  s.stopping.store(true) # a stream reads it at the cancel below: exit 6, not 130
  withLock s.lock:
    s.closing = true
    for i in 0 ..< s.threads:
      if s.active[i] >= 0:
        when defined(posix):
          discard shutdown(SocketHandle(s.active[i]), SHUT_RD)
    broadcast(s.cond)
  unlinkOwn(s)
  when defined(posix):
    var one = [byte(1)]
    discard write(s.wakeW, addr one[0], 1)
  s.reaperBell.ring()
  if s.acceptStarted:
    joinThread(s.acceptThread)
  for i in 0 ..< s.started:
    joinThread(s.workerThreads[i])
  if s.reaperStarted:
    joinThread(s.reaperThread)
  withLock s.lock:
    while s.qLen > 0:
      let fd = s.queue[s.qHead].fd
      s.reply(fd, refusedReply(LcnCliRefusedReasonChoiceKind.Closing))
      discard fdClose(fd)
      s.qHead = (s.qHead + 1) mod s.threads
      dec s.qLen
  discard fdClose(s.listenFd)
  discard fdClose(s.wakeR)
  discard fdClose(s.wakeW)

proc initModule(
    _: type CallServer, init: ModuleInit, config: LcnCallSettings
): Result[CallServer, InvocationFailure] =
  ## [G343, G344] The socket, the threads, then `serving`.
  checkBinding(init.services.runtimeControl).isOkOr:
    return fail("the Runtime Control binding: " & $error)
  # [N-2c; IF l.1476-1477] The binding's one subscription-end registration,
  # before any subscription; the hub outlives the context (`streams.nim`).
  let hub = newHub(init.services.runtimeControl)
  let reg = hub.register()
  if int64(reg.code) != 0:
    return fail(
      "the Runtime Control binding's observe_subscription_end: code " & $int64(reg.code)
    )
  let workers = int(config.workers)
  let streams = int(config.streams)
  if workers < 1 or workers > MaxWorkers:
    return fail("workers is 1 to " & $MaxWorkers)
  if streams < 1 or streams > MaxStreams:
    return fail("streams is 1 to " & $MaxStreams)
  if config.idle_timeout_ms == 0 or config.route_idle_ms == 0:
    return fail("idle_timeout_ms and route_idle_ms are at least 1")
  let (fd, dev, ino) = bindSocket(config.socket).valueOr:
    return fail(error)
  var pipeFds: array[2, cint]
  when defined(posix):
    if pipe(pipeFds) != 0:
      let e = $strerror(errno)
      discard unlink(cstring(config.socket))
      discard fdClose(fd)
      return fail("pipe: " & e)
    for f in pipeFds:
      discard fcntl(f, F_SETFD, FD_CLOEXEC)
  let threads = workers + streams
  let s = cast[ptr Server](allocShared0(sizeof(Server)))
  initLock(s.lock)
  initCond(s.cond)
  s.env = Env(
    rc: init.services.runtimeControl,
    routes: newRouteTable(init.services.runtimeControl, int(config.route_idle_ms)),
    hub: hub,
    # [G503] Never freed, as the hub: a worker may hold it until the last command ends.
    pm: cast[ptr PmGate](allocShared0(sizeof(PmGate))),
    stopping: addr s.stopping,
    production: config.deployment.kind == LcnCallSettingsDeploymentChoiceKind.Production,
  )
  s.env.routes.setEndHook(routeEnd, hub)
  s.listenFd = fd
  s.dev = dev
  s.ino = ino
  s.wakeR = pipeFds[0]
  s.wakeW = pipeFds[1]
  s.path = share(config.socket)
  s.idleTimeoutMs = int(config.idle_timeout_ms)
  s.workers = workers
  s.streams = streams
  s.threads = threads
  s.queue = cast[ptr UncheckedArray[Conn]](allocShared0(sizeof(Conn) * threads))
  s.active = cast[ptr UncheckedArray[cint]](allocShared0(sizeof(cint) * threads))
  for i in 0 ..< threads:
    s.active[i] = -1
  s.workerThreads = cast[ptr UncheckedArray[Thread[(ptr Server, int)]]](allocShared0(
    sizeof(Thread[(ptr Server, int)]) * threads
  ))
  s.reaperBell = newBell()
  s.lastRefusal = getMonoTime() - initDuration(seconds = 2)
  try:
    createThread(s.acceptThread, acceptMain, s)
    s.acceptStarted = true
    for i in 0 ..< threads:
      createThread(s.workerThreads[i], workerMain, (s, i))
      inc s.started
    createThread(s.reaperThread, reaperMain, s)
    s.reaperStarted = true
  except ResourceExhaustedError as e:
    stop(s)
    closeTable(s.env.routes)
    freeServer(s)
    return fail("cannot start a thread: " & e.msg)
  withLock s.lock:
    s.serving = true # [BCP l.393] init's last step
    broadcast(s.cond)
  logInfo("lcn_call: serving " & config.socket)
  ok(CallServer(s: s))

proc destroyModule(m: CallServer) =
  if m.s != nil:
    stop(m.s)
    closeTable(m.s.env.routes) # [IF l.3927] after every worker has ended
    freeServer(m.s)
    m.s = nil

exportLcnCall(CallServer)

{.pop.}
