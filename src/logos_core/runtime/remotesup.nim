## Remote process supervision (Tier 5 step 5-7a-2; DECISIONS G411, G412;
## 5-7a plan §3.1, §3.8) [IMPL]: the Runtime's side of `logos_remote`. One
## `RemoteSupervisor` per engine, made when `runtime.remote_program` is
## configured and the in-process host (logosd) gave the remote hooks
## (`host.runtimeSetRemoteHooks`): the TLS certificate and the signer.
##
## - **The spawning thread.** Every remote process is spawned by one thread,
##   the supervision thread, made with the supervisor and ended only after
##   every process it spawned is reaped: on Linux the parent-death signal
##   follows the thread that spawned the child (G265's rule, plan §3.1). A
##   start asked for on any other thread (the host's start, a Runtime Control
##   worker enabling a listener) is queued to it and waited for.
## - **A listener** is one process per enabled listener record. The thread
##   binds the TCP address itself (close-on-exec), takes the restart lock
##   `<work_dir>/remote/listener-<hash>.lock` (G275's mechanism), and spawns
##   the program with fd 3 its control channel, fd 4 the listener and fd 5
##   the lock, then sends the snapshot, the test key (process-copy only) and
##   `listen`. The start succeeds once the process answers `listening`
##   (RUNTIME l.3291-3292), or fails TRANSPORT_ERROR: a bind failure, a lock
##   held, a spawn failure, an exit or 10 s without `listening` [IMPL]. The
##   bound socket stays with the supervisor while the record is enabled, so a
##   restart rebinds nothing.
## - **Restarts.** A listener process that ends while its record is enabled is
##   started again after 1 s, doubling to 30 s at most [IMPL]; each end is
##   noted (`RemoteHooks.note`).
## - **Stops.** Disabling a listener sends `stop`, closes the socket so no new
##   connection arrives at the address (RUNTIME l.3303), and kills the
##   process group 2 s later if it has not exited [IMPL]. Closing the
##   supervisor closes every control channel at once (each process exits on
##   EOF), kills each group after 2 s and reaps them all before it returns
##   (plan §3.1 item 5), so every lock is free when the Runtime ends.
## - **Signing (G410).** A process's `sign` is answered by the host's signer
##   on the supervisor's sign thread, as a TLS server, so a slow signer never
##   holds the supervision loop.
## - **Hello and Runtime Control** (G413) go to the inbound side
##   (`RemoteInbound`, `remoterc.nim`) as they come, on this thread, which
##   must not block; its answers come back through `post`, each to the one
##   process run it is for, so a restarted process never gets an answer meant
##   for its predecessor's connection. Without an inbound side every Hello is
##   refused and the connection closed.
##
## On Windows no supervisor is made (`newRemoteSupervisor` gives nil): logosd
## does not start there (TRANSPORT l.1133).

{.push raises: [], gcsafe.}

import std/[atomics, locks, monotimes, strutils, tables, times, typedthreads]
import results
import logos_sdk/base/parentwatch
import logos_sdk/base/utf8clip
import logos_sdk/crypto/blake3
import logos_sdk/iface/outcome
import ../remote/carrier
import ../transport/tls/params
import ./plumbing except Request
from ./hostsup import nil # compiles hostspawn.c, whose spawn this module calls

when defined(posix):
  import std/posix
  from std/os import `/`, createDir, setFilePermissions, FilePermission, getEnv
  # [DECISIONS I147] hostsup's declaration, the only one.
  from ./hostsup import lcnHostSpawn

  proc flock(fd: cint, op: cint): cint {.importc, header: "<sys/file.h>".}

const
  RemoteProgramName* = "logos_remote"
  TickMs = 50 ## [IMPL] the supervision loop's longest wait
  ListenDeadline = times.initDuration(seconds = 10)
    ## [IMPL] from the spawn to `listening`
  StopGrace = times.initDuration(seconds = 2)
    ## [IMPL; plan §3.1 item 5] from `stop` or the channel's close to SIGKILL
  FirstBackoffMs = 1000
  MaxBackoffMs = 30_000
  TestVarPrefix = "LCN_REMOTE_TEST_"
    ## [lcnTestHooks builds] the variables a test passes to the program
  SanitizerVars = ["ASAN_OPTIONS", "UBSAN_OPTIONS", "TSAN_OPTIONS", "LSAN_OPTIONS"]

const ReplyMessageMax* = 512 ## [IMPL] a start's message is cut there (`cutMessage`)

type
  RemoteSign* = proc(
    data: pointer, process: uint64, role: TlsRole, alg: uint16, input: seq[byte]
  ): SignResult {.nimcall, gcsafe, raises: [].}
    ## [G410] Signs one CertificateVerify input of the process numbered
    ## `process` as `role`, blocking; runs on the supervisor's one sign
    ## thread. The host applies its checks and its limit per process.

  RemoteSignEnd* = proc(data: pointer) {.nimcall, gcsafe, raises: [].}
    ## The sign thread's last call, before it exits: what `sign` made on that
    ## thread is freed there, since under refc no thread frees memory another
    ## thread's heap made.

  RemoteNote* = proc(data: pointer, text: string) {.nimcall, gcsafe, raises: [].}
    ## One line for the host's log (a process's end, a restart).

  RemoteInbound* = object
    ## [G413] Who takes what a listener process relays (`remoterc.nim`).
    ## `frame` and `ended` run on the supervision thread and must not block;
    ## answers go back through `post`.
    data*: pointer
    frame*: proc(data: pointer, key: seq[byte], run: uint64, body: seq[byte]) {.
      nimcall, gcsafe, raises: []
    .}
      ## one `hello_judge`, `rc_in` or `conn_closed` body from the process run
      ## `run` of the listener at `key`
    ended*:
      proc(data: pointer, key: seq[byte], run: uint64) {.nimcall, gcsafe, raises: [].}
      ## that process run ended: every connection it had is gone
    close*: proc(data: pointer, tokens: seq[string]) {.nimcall, gcsafe, raises: [].}
      ## the engine ended these admitted connections (`RemoteDriver.close`);
      ## on the calling thread, at once

  Post = object
    run: uint64
    frames: seq[seq[byte]]

  RemoteHooks* = object
    ## What the in-process host gives (`host.runtimeSetRemoteHooks`).
    certificate*: seq[byte] ## the Runtime's TLS certificate, DER
    sign*: RemoteSign
    signData*: pointer
    signEnd*: RemoteSignEnd ## nil: `sign` keeps nothing between calls
    persist*: RemotePersist ## [Q4] nil: nothing is recorded across a restart
    persistData*: pointer
    note*: RemoteNote
    noteData*: pointer
    testKey*: seq[byte]
      ## [B1: tests only] process-copy: the key each process signs with
      ## itself; empty otherwise

  JobKind = enum
    jkStart
    jkStop

  StartReply = object
    ## A start's answer, which the supervision thread writes and the caller
    ## reads and frees. [refc] No GC'd field: under refc no thread may free
    ## memory another thread's heap made, so the message is copied into the
    ## reply's own bytes (`answer`), cut on a code point (`cutMessage`).
    done: Atomic[bool] ## set last, with release; read with acquire
    code: ErrorCode
    messageLen: int
    message: array[ReplyMessageMax, char]

  Job = object
    kind: JobKind
    key: seq[byte]
    host: string
    port: uint16
    reply: ptr StartReply

  SignJob = object
    stop: bool
    procId: uint64
    id: uint64
    alg: uint16
    input: seq[byte]

  SignDone = object
    procId: uint64
    frame: seq[byte]

  ProcState = enum
    psStarting ## spawned, `listening` not yet answered
    psListening
    psStopping ## asked to end: no restart
    psWaiting ## ended while wanted: a restart is due at `restartAt`

  RemoteProc = ref object
    ## One listener record's process; the supervision thread's only.
    id: uint64 ## this supervisor's own number for the process's run
    key: seq[byte]
    name: string ## `host:port`, for notes
    host: string
    port: uint16
    listenFd: cint ## the bound socket, kept while the record is enabled
    ctl: cint ## the supervisor's end of the control channel; -1 once closed
    pid: cint
    state: ProcState
    reader: FrameReader
    outq: seq[byte]
    waiter: ptr StartReply ## the start waiting for `listening`; nil: none
    deadline: MonoTime ## psStarting: `listening` by then
    killAt: MonoTime ## psStopping: SIGKILL the group then
    backoffMs: int
    restartAt: MonoTime

  RemoteSupervisorObj = object
    lock: Lock
    cond: Cond
    thread: Thread[ptr RemoteSupervisorObj]
    signThread: Thread[ptr RemoteSupervisorObj]
    closing: Atomic[bool]
    wakeR, wakeW: cint
    jobs: Channel[Job]
    signJobs: Channel[SignJob]
    signed: Channel[SignDone]
    program: string
    workDir: string
    snapshot: seq[byte] ## one encoded `lcn.rch_snapshot`
    tls: TlsConfig
    hooks: RemoteHooks
    inbound: RemoteInbound
    posts: Channel[Post]

  RemoteSupervisor* = ptr RemoteSupervisorObj

func cutMessage*(message: string, max = ReplyMessageMax): string =
  ## [IMPL] A start's message as its reply holds it: at most `max` bytes, cut
  ## back to the last complete code point, so that text reaching a tstr (an
  ## error reply, a log, a Runtime Control answer) stays valid UTF-8, which
  ## the strict decoder requires.
  clipUtf8(message, max)

proc wake(s: RemoteSupervisor) =
  when defined(posix):
    var b = 1'u8
    discard posix.write(s.wakeW, addr b, 1)

func lockFileName*(key: openArray[byte]): string =
  ## [G275's mechanism; plan §3.1 item 3] A fixed-length name for the
  ## listener at the address whose deterministic-CBOR bytes are `key`.
  let d = blake3(key)
  result = "listener-"
  for i in 0 ..< 16:
    result.add(toHex(int(d[i]), 2).toLowerAscii)
  result.add(".lock")

func remoteLockDir*(workDir: string): string =
  when defined(posix):
    workDir / "remote"
  else:
    workDir

proc note(s: RemoteSupervisor, text: string) =
  if s.hooks.note != nil:
    s.hooks.note(s.hooks.noteData, "remote: " & text)

# The sign thread ---------------------------------------------------------------------

proc signMain(s: RemoteSupervisor) {.thread.} =
  while true:
    let j = s.signJobs.recv()
    if j.stop:
      if s.hooks.signEnd != nil:
        s.hooks.signEnd(s.hooks.signData)
      return
    let r =
      if s.hooks.sign == nil:
        unavailable()
      else:
        s.hooks.sign(s.hooks.signData, j.procId, tlsServer, j.alg, j.input)
    let f = frameOf(signAnswer(j.id, r)).get(newSeq[byte]())
    s.signed.send(SignDone(procId: j.procId, frame: f))
    s.wake()

# The supervision thread -----------------------------------------------------------------

when defined(posix):
  proc cloexec(fd: cint) =
    discard fcntl(fd, F_SETFD, FD_CLOEXEC)

  proc nonblocking(fd: cint) =
    let f = fcntl(fd, F_GETFL)
    if f >= 0:
      discard fcntl(fd, F_SETFL, f or O_NONBLOCK)

  proc bindListener(host: string, port: uint16): Result[cint, string] =
    ## [SPEC RUNTIME l.3291, l.3299] The address bound and listening.
    var hints: AddrInfo
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    hints.ai_flags = AI_PASSIVE
    var res: ptr AddrInfo
    let service = $port
    let g = getaddrinfo(cstring(host), cstring(service), addr hints, res)
    if g != 0:
      return err("cannot resolve " & host & ": " & $gai_strerror(g))
    defer:
      freeAddrInfo(res)
    var why = "no address"
    var ai = res
    while ai != nil:
      let fd = cint(socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol))
      if fd >= 0:
        cloexec(fd)
        var one: cint = 1
        discard setsockopt(
          SocketHandle(fd), SOL_SOCKET, SO_REUSEADDR, addr one, SockLen(sizeof(one))
        )
        if bindSocket(SocketHandle(fd), ai.ai_addr, ai.ai_addrlen) == 0 and
            listen(SocketHandle(fd), 128) == 0:
          return ok(fd)
        why = $strerror(errno)
        discard posix.close(fd)
      else:
        why = $strerror(errno)
      ai = ai.ai_next
    err("cannot listen at " & host & ":" & $port & ": " & why)

  proc takeLock(s: RemoteSupervisor, key: openArray[byte]): Result[cint, string] =
    let dir = remoteLockDir(s.workDir)
    try:
      createDir(dir)
      setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
    except OSError, IOError:
      return err("cannot make " & dir)
    let path = dir / lockFileName(key)
    let fd = posix.open(cstring(path), O_RDWR or O_CREAT or O_CLOEXEC, 0o600)
    if fd < 0:
      return err("cannot open " & path & ": " & $strerror(errno))
    if flock(fd, 2 or 4) != 0: # LOCK_EX | LOCK_NB
      discard posix.close(fd)
      return err(
        "the restart lock " & path & " is held: a process of an earlier run is alive"
      )
    ok(fd)

  proc childEnv(): seq[string] =
    for name in SanitizerVars:
      let v = getEnv(name)
      if v.len > 0:
        result.add(name & "=" & v)
    when defined(lcnTestHooks):
      for name in ["LCN_REMOTE_TEST_WEDGE_MS"]:
        let v = getEnv(name)
        if v.len > 0:
          result.add(name & "=" & v)
    discard TestVarPrefix

  proc queue(p: RemoteProc, m: LcnRchMessage) =
    let f = frameOf(m)
    if f.isOk:
      p.outq.add(f.get)

  proc answer(r: ptr StartReply, code: ErrorCode, message: string) =
    ## On the supervision thread: the waiting caller's answer.
    r.code = code
    let m = cutMessage(message, r.message.len)
    if m.len > 0:
      copyMem(addr r.message[0], unsafeAddr m[0], m.len)
    r.messageLen = m.len
    r.done.store(true, moRelease)

  proc reply(p: RemoteProc, code: ErrorCode, message: string) =
    if p.waiter != nil:
      p.waiter.answer(code, message)
      p.waiter = nil

  proc spawnProc(
      s: RemoteSupervisor, p: RemoteProc, nextId: var uint64
  ): Result[void, string] =
    ## One run of `p`'s process on its bound socket.
    let lockFd = ?s.takeLock(p.key)
    var pair: array[2, cint]
    if socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0:
      discard posix.close(lockFd)
      return err("no socket pair: " & $strerror(errno))
    cloexec(pair[0])
    cloexec(pair[1])
    let parent = ParentFlag & $getpid()
    var argv = [cstring(RemoteProgramName), cstring("listener"), cstring(parent), nil]
    let env = childEnv()
    var envp = newSeq[cstring](env.len + 1)
    for i, v in env:
      envp[i] = cstring(v)
    var pid: cint = -1
    let r = lcnHostSpawn(
      cstring(s.program),
      cast[cstringArray](addr argv[0]),
      cast[cstringArray](addr envp[0]),
      pair[1],
      p.listenFd,
      lockFd,
      -1, # no system endpoint: that is a Module Host's (G492)
      addr pid,
    )
    discard posix.close(pair[1])
    discard posix.close(lockFd)
    if r != 0:
      discard posix.close(pair[0])
      return err("cannot start " & s.program & ": " & $strerror(abs(r)))
    nonblocking(pair[0])
    inc nextId
    p.id = nextId
    p.ctl = pair[0]
    p.pid = pid
    p.reader = newRchReader()
    p.outq.setLen(0)
    p.state = psStarting
    p.deadline = getMonoTime() + ListenDeadline
    let snap = LcnRchMessage.decode(s.snapshot)
    if snap.isOk:
      p.outq.add(frameOf(snap.get).get(newSeq[byte]()))
    if s.hooks.testKey.len > 0:
      p.queue(toMessage(LcnRchTestKey(pkcs8: s.hooks.testKey)))
    p.queue(
      toMessage(LcnRchListen(certificate: s.hooks.certificate, limits: limitsOf(s.tls)))
    )
    ok()

  proc closeCtl(p: RemoteProc) =
    if p.ctl >= 0:
      discard posix.close(p.ctl)
      p.ctl = -1

  proc beginStop(p: RemoteProc, closeNow: bool) =
    ## [SPEC RUNTIME l.3303] No new connection at the address: the socket
    ## closes now; the process ends in order, or is killed after the grace.
    if p.listenFd >= 0:
      discard posix.close(p.listenFd)
      p.listenFd = -1
    if p.pid > 0:
      if closeNow:
        p.closeCtl()
      else:
        p.queue(toMessage(LcnRchStop()))
      p.killAt = getMonoTime() + StopGrace
    p.state = psStopping
    p.reply(ecTransport, "the listener was stopped before it listened")

  proc flush(p: RemoteProc): bool =
    ## Writes what is queued; false when the channel failed.
    while p.outq.len > 0 and p.ctl >= 0:
      let n = posix.write(p.ctl, addr p.outq[0], p.outq.len)
      if n < 0:
        if errno == EAGAIN or errno == EWOULDBLOCK or errno == EINTR:
          return true
        return false
      p.outq.delete(0 ..< n)
    true

  proc handleFrame(s: RemoteSupervisor, p: RemoteProc, body: seq[byte]): bool =
    ## One message from the process; false for one it may not send, which
    ## ends it.
    let m = decodeMessage(body).valueOr:
      return false
    type K = LcnRchMessageKind
    case m.kind
    of K.lcn_Rch_listening:
      if p.state != psStarting:
        return false
      p.state = psListening
      p.backoffMs = 0
      p.reply(ecOk, "")
    of K.lcn_Rch_sign:
      let x = m.arm_lcn_Rch_sign
      s.signJobs.send(SignJob(procId: p.id, id: x.id, alg: x.alg, input: x.input))
    of K.lcn_Rch_hello_judge, K.lcn_Rch_rc_in, K.lcn_Rch_conn_closed:
      if p.state != psListening:
        return true # stopping: what it still reports is moot
      if s.inbound.frame != nil:
        s.inbound.frame(s.inbound.data, p.key, p.id, body)
      elif m.kind == K.lcn_Rch_hello_judge:
        p.queue(
          toMessage(LcnRchHelloRefuse(id: m.arm_lcn_Rch_hello_judge.id, response: @[]))
        )
    else:
      return false
    true

  proc readFrom(s: RemoteSupervisor, p: RemoteProc): bool =
    ## Reads what the process sent; false at EOF or a fault.
    var buf: array[16 * 1024, byte]
    while p.ctl >= 0:
      let n = posix.read(p.ctl, addr buf[0], buf.len)
      if n < 0:
        if errno == EAGAIN or errno == EWOULDBLOCK or errno == EINTR:
          return true
        return false
      if n == 0:
        return false
      let frames = p.reader.feed(buf.toOpenArray(0, n - 1)).valueOr:
        return false
      for body in frames:
        if not s.handleFrame(p, body):
          return false
    true

  proc ended(s: RemoteSupervisor, p: RemoteProc, status: cint) =
    ## The process was reaped.
    p.closeCtl()
    p.pid = -1
    if s.inbound.ended != nil:
      s.inbound.ended(s.inbound.data, p.key, p.id)
    let how =
      if WIFEXITED(status):
        "exited with status " & $WEXITSTATUS(status)
      elif WIFSIGNALED(status):
        "ended by signal " & $WTERMSIG(status)
      else:
        "ended"
    case p.state
    of psStarting:
      s.note("the listener at " & p.name & " " & how & " before it listened")
      p.reply(ecTransport, "the listener process " & how & " before it listened")
      if p.listenFd >= 0:
        discard posix.close(p.listenFd)
        p.listenFd = -1
      p.state = psStopping
    of psListening:
      p.backoffMs =
        if p.backoffMs == 0:
          FirstBackoffMs
        else:
          min(p.backoffMs * 2, MaxBackoffMs)
      p.restartAt = getMonoTime() + times.initDuration(milliseconds = p.backoffMs)
      p.state = psWaiting
      s.note(
        "the listener at " & p.name & " " & how & "; started again in " & $p.backoffMs &
          " ms"
      )
    of psStopping, psWaiting:
      discard

  proc superviseMain(s: RemoteSupervisor) {.thread.} =
    var procs: Table[seq[byte], RemoteProc]
    var nextId = 0'u64
    var shutting = false
    while true:
      # Jobs.
      while true:
        let (got, j) = s.jobs.tryRecv()
        if not got:
          break
        case j.kind
        of jkStart:
          var p = procs.getOrDefault(j.key)
          if p != nil and p.state in {psStarting, psListening}:
            j.reply.answer(ecOk, "")
            continue
          if shutting:
            j.reply.answer(ecNotReady, "the Runtime is closing")
            continue
          if p != nil and p.state == psWaiting:
            # Ended while enabled and waiting for its restart: now.
            let spawned = s.spawnProc(p, nextId)
            if spawned.isErr:
              j.reply.answer(ecTransport, spawned.error)
            else:
              p.waiter = j.reply
            continue
          if p != nil and p.pid > 0:
            # Still ending from a stop: the address is free, but its lock
            # is held until the process is reaped.
            j.reply.answer(
              ecTransport, "the listener's previous process is still ending"
            )
            continue
          let fd = bindListener(j.host, j.port)
          if fd.isErr:
            j.reply.answer(ecTransport, fd.error)
            continue
          p = RemoteProc(
            key: j.key,
            name: j.host & ":" & $j.port,
            host: j.host,
            port: j.port,
            listenFd: fd.get,
            ctl: -1,
            pid: -1,
          )
          let spawned = s.spawnProc(p, nextId)
          if spawned.isErr:
            discard posix.close(p.listenFd)
            j.reply.answer(ecTransport, spawned.error)
            continue
          p.waiter = j.reply
          procs[j.key] = p
        of jkStop:
          let p = procs.getOrDefault(j.key)
          if p != nil and p.state != psStopping:
            p.beginStop(closeNow = false)
      if s.closing.load and not shutting:
        shutting = true
        for p in procs.values:
          if p.state != psStopping:
            p.beginStop(closeNow = true)
          else:
            p.closeCtl()
      # Answers from the sign thread.
      while true:
        let (got, d) = s.signed.tryRecv()
        if not got:
          break
        for p in procs.values:
          if p.id == d.procId and p.ctl >= 0:
            p.outq.add(d.frame)
      # [G413] Answers from the inbound side, to the process run they are for.
      while true:
        let (got, d) = s.posts.tryRecv()
        if not got:
          break
        for p in procs.values:
          if p.id == d.run and p.ctl >= 0 and p.state == psListening:
            for f in d.frames:
              p.outq.add(f)
      # Wait.
      var fds = @[TPollfd(fd: s.wakeR, events: POLLIN)]
      var order: seq[RemoteProc]
      for p in procs.values:
        if p.ctl >= 0:
          var ev = POLLIN
          if p.outq.len > 0:
            ev = ev or POLLOUT
          fds.add(TPollfd(fd: p.ctl, events: ev))
          order.add(p)
      discard poll(addr fds[0], Tnfds(fds.len), TickMs)
      if (fds[0].revents and POLLIN) != 0:
        var drain: array[64, byte]
        while posix.read(s.wakeR, addr drain[0], drain.len) > 0:
          discard
      for i, p in order:
        let ev = fds[i + 1].revents
        if ev == 0:
          continue
        var ok = true
        if (ev and (POLLIN or POLLHUP or POLLERR)) != 0:
          ok = s.readFrom(p)
        if ok and (ev and POLLOUT) != 0:
          ok = p.flush()
        if not ok:
          # A fault or the channel's end: the process is ended.
          p.closeCtl()
          if p.pid > 0:
            discard kill(Pid(-p.pid), SIGKILL)
      for p in procs.values:
        if p.outq.len > 0 and p.ctl >= 0:
          if not p.flush():
            p.closeCtl()
            if p.pid > 0:
              discard kill(Pid(-p.pid), SIGKILL)
      # Reaping, deadlines and restarts.
      let now = getMonoTime()
      var gone: seq[seq[byte]]
      for key, p in procs.mpairs:
        if p.pid > 0:
          var status: cint
          let r = waitpid(Pid(p.pid), status, WNOHANG)
          if r == Pid(p.pid):
            discard kill(Pid(-p.pid), SIGKILL) # [R3] what it left in its group
            s.ended(p, status)
          elif p.state == psStarting and now >= p.deadline:
            s.note("the listener at " & p.name & " did not listen within 10 s")
            p.reply(ecTransport, "the listener process did not listen in time")
            discard kill(Pid(-p.pid), SIGKILL)
            p.closeCtl()
            if p.listenFd >= 0:
              discard posix.close(p.listenFd)
              p.listenFd = -1
            p.state = psStopping
            p.killAt = now
          elif p.state == psStopping and now >= p.killAt:
            discard kill(Pid(-p.pid), SIGKILL)
        if p.pid <= 0:
          if p.state == psStopping:
            gone.add(key)
          elif p.state == psWaiting and now >= p.restartAt and not shutting:
            let spawned = s.spawnProc(p, nextId)
            if spawned.isErr:
              p.backoffMs = min(max(p.backoffMs, FirstBackoffMs) * 2, MaxBackoffMs)
              p.restartAt = now + times.initDuration(milliseconds = p.backoffMs)
              s.note("the listener at " & p.name & " cannot start: " & spawned.error)
          elif p.state == psWaiting and shutting:
            p.state = psStopping
            gone.add(key)
      for key in gone:
        let p = procs.getOrDefault(key)
        if p != nil and p.listenFd >= 0:
          discard posix.close(p.listenFd)
        procs.del(key)
      withLock s.lock:
        broadcast(s.cond)
      if shutting and procs.len == 0:
        return

# The handle ------------------------------------------------------------------------------

proc newRemoteSupervisor*(
    program, workDir: string, snapshot: seq[byte], hooks: RemoteHooks
): RemoteSupervisor =
  ## Starts the supervision thread, which spawns every remote process. Nil on
  ## Windows, or when the threads cannot start.
  when defined(posix):
    var pipeFds: array[2, cint]
    if pipe(pipeFds) != 0:
      return nil
    for fd in pipeFds:
      cloexec(fd)
      nonblocking(fd)
    let s = createShared(RemoteSupervisorObj)
    initLock(s.lock)
    initCond(s.cond)
    s.wakeR = pipeFds[0]
    s.wakeW = pipeFds[1]
    s.jobs.open()
    s.signJobs.open()
    s.signed.open()
    s.posts.open()
    s.program = program
    s.workDir = workDir
    s.snapshot = snapshot
    s.tls = defaultTlsConfig()
    s.hooks = hooks
    try:
      createThread(s.thread, superviseMain, s)
      createThread(s.signThread, signMain, s)
    except ResourceExhaustedError:
      return nil
    s
  else:
    nil

proc setInbound*(s: RemoteSupervisor, inbound: RemoteInbound) =
  ## [G413] Before the first start.
  if s != nil:
    s.inbound = inbound

proc post*(s: RemoteSupervisor, run: uint64, msgs: openArray[LcnRchMessage]) =
  ## [G413] Control-channel messages for the process run `run`, sent after
  ## every earlier one; dropped once that run has ended. Any thread.
  if s == nil:
    return
  var frames: seq[seq[byte]]
  for m in msgs:
    let f = frameOf(m)
    if f.isOk:
      frames.add(f.get)
  if frames.len > 0:
    s.posts.send(Post(run: run, frames: frames))
    s.wake()

proc startListener*(
    s: RemoteSupervisor, key: seq[byte], host: string, port: uint16
): Result[void, EngineError] =
  ## [SPEC RUNTIME l.3291-3292, l.3299] Queued to the supervision thread and
  ## waited for: OK once the process listens.
  if s == nil:
    return
      err(engineError(ecModule, "remote transport is not supported by this Runtime"))
  let r = createShared(StartReply)
  s.jobs.send(Job(kind: jkStart, key: key, host: host, port: port, reply: r))
  s.wake()
  acquire(s.lock)
  while not r.done.load(moAcquire):
    wait(s.cond, s.lock)
  release(s.lock)
  let code = r.code
  var message = newString(r.messageLen)
  if r.messageLen > 0:
    copyMem(addr message[0], addr r.message[0], r.messageLen)
  freeShared(r)
  if code != ecOk:
    return err(engineError(code, message))
  ok()

proc stopListener*(s: RemoteSupervisor, key: seq[byte]) =
  ## [SPEC RUNTIME l.3303] Returns at once; the process ends on the
  ## supervision thread.
  if s != nil:
    s.jobs.send(Job(kind: jkStop, key: key))
    s.wake()

proc driverStart(
    data: pointer, key: seq[byte], host: string, port: uint16
): Result[void, EngineError] {.nimcall, gcsafe, raises: [].} =
  cast[RemoteSupervisor](data).startListener(key, host, port)

proc driverStop(data: pointer, key: seq[byte]) {.nimcall, gcsafe, raises: [].} =
  cast[RemoteSupervisor](data).stopListener(key)

proc driverClose(data: pointer, tokens: seq[string]) {.nimcall, gcsafe, raises: [].} =
  let s = cast[RemoteSupervisor](data)
  if s.inbound.close != nil:
    s.inbound.close(s.inbound.data, tokens)

proc driverPersist(
    data: pointer,
    listener: seq[byte],
    provider: string,
    off: set[ExposureField],
    consumer: string,
): Result[void, string] {.nimcall, gcsafe, raises: [].} =
  let s = cast[RemoteSupervisor](data)
  if s.hooks.persist == nil:
    return ok()
  s.hooks.persist(s.hooks.persistData, listener, provider, off, consumer)

proc driver*(s: RemoteSupervisor): RemoteDriver =
  ## The engine's way to this supervisor (`EngineConfig.remote`).
  if s == nil:
    return RemoteDriver()
  RemoteDriver(
    data: s,
    start: driverStart,
    stop: driverStop,
    persist: (if s.hooks.persist == nil: nil else: driverPersist),
    close: driverClose,
  )

proc closeRemoteSupervisor*(s: RemoteSupervisor) =
  ## [plan §3.1 item 5] Every process ended and reaped, then the threads
  ## joined. Idempotent on nil.
  if s == nil:
    return
  s.closing.store(true)
  s.wake()
  joinThread(s.thread)
  s.signJobs.send(SignJob(stop: true))
  joinThread(s.signThread)
  when defined(posix):
    discard posix.close(s.wakeR)
    discard posix.close(s.wakeW)
  s.jobs.close()
  s.signJobs.close()
  s.signed.close()
  s.posts.close()
  deinitCond(s.cond)
  deinitLock(s.lock)
  `=destroy`(s[])
  freeShared(s)

{.pop.}
