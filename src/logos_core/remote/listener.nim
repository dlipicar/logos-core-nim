## The listener role of `logos_remote` (Tier 5 step 5-7a-2; DECISIONS G411,
## G413; 5-7a plan §3.1, §3.9) [IMPL]. One process per enabled listener
## record. It runs no module code and holds no engine state (owner decision
## B1): it serves TLS on the listening socket logosd bound, authenticates each
## peer against the trust snapshot of logosd's start, and relays the Hello
## judgment and every Runtime Control frame to logosd over its control
## channel. No module payload crosses that channel (plan §3.16).
##
## Descriptors (`hostspawn.c`): fd 3 the control channel (a socket pair), fd 4
## the TCP listener, fd 5 the restart lock, into which the process writes its
## pid. Arguments: `listener --parent=<logosd's pid>`.
##
## Its end (plan §3.1 items 1, 2 and 5):
## - first thing, the parent watch is registered and then compared
##   (`parentwatch.watchParent`); a parent already gone ends the process;
## - a watcher thread blocks on that watch (macOS: the parent's `NOTE_EXIT`;
##   Linux: a hang-up of fd 3, beside the parent-death signal) and ends the
##   process with `_exit`, so a wedged event loop cannot keep it alive;
## - EOF or an error on fd 3 ends it at once, its TLS connections dropped
##   unflushed (the kernel closes them);
## - `stop` ends it in order: no new connection, the open ones closed.
##
## Messages, in order: `snapshot`, `test_key` (tests only: a build with
## `-d:logosTestSigning` and `-d:lcnTestHooks`), `listen`; the process then
## answers `listening` and serves. Each connection's first frame goes to
## logosd as `hello_judge`, and nothing more is read from it until
## `hello_admit` (its response sent, then every frame relayed as `rc_in`) or
## `hello_refuse` (its ProtocolError sent, if any, and the connection closed).
## `rc_out` frames go back on their connection; `close_conn` ends one; the
## process reports each end as `conn_closed`. Anything else, or a frame that
## does not decode, ends the process.

{.push raises: [].}

import std/tables
from std/os import getEnv, sleep
from std/cmdline import commandLineParams
from std/posix import nil
import chronos
import results
import logos_sdk/base/[parentwatch, testhooks]
import ../transport/tls/[engine, params, signing, stream, trust, verify]
import ./carrier

const TestKey = defined(logosTestSigning) and defined(lcnTestHooks)

when TestKey:
  import ../transport/tls/[p256, testsigner]

testHooksMarker("remote_listener")

const
  ControlFd* = cint(3) ## the control channel to logosd
  ListenFd* = cint(4) ## the TCP listener logosd bound
  LockFd* = cint(5) ## the restart lock (G275's mechanism)
  RoleListener* = "listener"
  ExitUsage* = 2 ## not started by logosd: a missing argument or descriptor
  ExitLost* = 70 ## the parent or the control channel is gone
  WedgeVar* = "LCN_REMOTE_TEST_WEDGE_MS"
    ## [plan §3.1; lcnTestHooks builds only] block the event loop this long,
    ## from 200 ms after `listening` (sent by then), for the wedged-loop test

type
  Phase = enum
    phSnapshot ## waiting for the snapshot
    phListen ## waiting for `test_key` or `listen`
    phServing

  Conn = ref object
    id: uint64
    s: TlsStream
    verdict: Future[Opt[seq[byte]]].Raising([CancelledError])
      ## some: admitted, with the Hello response; none: refused or stopping
    refusal: seq[byte] ## the ProtocolError to send when refused; empty: none

  Remote = ref object
    ctl: StreamTransport
    reader: FrameReader
    phase: Phase
    trust: TrustSnapshot
    client: SignClient
    listener: TlsListener
    conns: Table[uint64, Conn]
    next: uint64
    when TestKey:
      key: P256Key

var watcher: Thread[ParentWatch]

proc say(msg: string) =
  try:
    stderr.writeLine("logos_remote: " & msg)
  except IOError:
    discard

proc ended(msg: string, code: int) {.noreturn.} =
  if msg.len > 0:
    say(msg)
  quit(code)

proc lost(msg: string) {.noreturn.} =
  ## [plan §3.1 item 1] The channel or the parent is gone: every connection
  ## is dropped, no drain, no grace.
  if msg.len > 0:
    say(msg)
  posix.exitnow(ExitLost)

proc watcherMain(w: ParentWatch) {.thread.} =
  ## [plan §3.1, the watcher thread] Blocks, then ends the process at once.
  waitParentEnd(w, ControlFd)
  posix.exitnow(ExitLost)

proc writePid(fd: cint) =
  ## [plan §3.1 item 3] The pid, so a refused start can name it.
  let text = $posix.getpid() & "\n"
  discard posix.ftruncate(fd, 0)
  discard posix.pwrite(fd, unsafeAddr text[0], text.len, 0)

proc send(r: Remote, m: LcnRchMessage) =
  ## One message on the control channel, after every earlier one; a failed
  ## write ends the process.
  let f = frameOf(m).valueOr:
    lost(error)
  let w = r.ctl.write(f)
  w.addCallback(
    proc(udata: pointer) {.gcsafe, raises: [].} =
      if w.failed:
        lost("the control channel failed")
  )

proc serveConn(r: Remote, s: TlsStream) {.async: (raises: []).} =
  ## One accepted, authenticated connection: its Hello judged by logosd, then
  ## its frames relayed. The listener closes the stream when this returns.
  inc r.next
  let c = Conn(
    id: r.next,
    s: s,
    verdict: Future[Opt[seq[byte]]].Raising([CancelledError]).init("remote.verdict"),
  )
  r.conns[c.id] = c
  block serve:
    var first: Result[Opt[TlsFrame], string]
    try:
      first = await s.readFrame()
    except CancelledError:
      break serve
    if first.isErr or first.get.isNone:
      break serve
    let binding = s.takeChannelBinding().valueOr:
      break serve
    let peer = s.peer
    r.send(
      toMessage(
        LcnRchHelloJudge(
          id: c.id,
          runtime: peer.runtime,
          revision: peer.revision,
          binding: binding,
          hello: first.get.get.body,
        )
      )
    )
    var v = Opt.none(seq[byte])
    try:
      v = await c.verdict
    except CancelledError:
      break serve
    if v.isNone:
      if c.refusal.len > 0:
        try:
          discard await s.writeFrame(c.refusal)
        except CancelledError:
          discard
      break serve
    var sent: Result[void, string]
    try:
      sent = await s.writeFrame(v.get)
    except CancelledError:
      break serve
    if sent.isErr:
      break serve
    while true:
      var f: Result[Opt[TlsFrame], string]
      try:
        f = await s.readFrame()
      except CancelledError:
        break
      if f.isErr or f.get.isNone:
        break
      r.send(toMessage(LcnRchRcIn(id: c.id, frame: f.get.get.body)))
  r.conns.del(c.id)
  r.send(toMessage(LcnRchConnClosed(id: c.id)))

proc relayOut(s: TlsStream, frame: seq[byte]) {.async: (raises: []).} =
  ## One `rc_out` frame on its connection; called at once, so frames keep the
  ## order logosd sent them in (`writeFrame` seals before it returns). A
  ## failed write ends the connection.
  try:
    if (await s.writeFrame(frame)).isErr:
      await s.close()
  except CancelledError:
    discard

proc listen(r: Remote, m: LcnRchListen) =
  let cfg = configOf(m.limits).valueOr:
    lost("listen: " & error)
  let ctx = newTlsContext(tlsServer, m.certificate).valueOr:
    lost("listen: " & error)
  var sign: Signer
  when TestKey:
    if r.key != nil:
      sign = keySigner(r.key, tlsServer)
  if sign == nil:
    sign = r.client.signer
  let handler = proc(s: TlsStream): Future[void] {.async: (raises: []), gcsafe.} =
    await r.serveConn(s)
  r.listener = serveAdopted(ListenFd, ctx, anyEnrolled(r.trust), sign, cfg, handler).valueOr:
    lost("listen: " & error)
  r.send(toMessage(LcnRchListening()))
  when defined(lcnTestHooks):
    let wedge = getEnv(WedgeVar)
    if wedge.len > 0:
      var ms = 0
      for ch in wedge:
        if ch in {'0' .. '9'}:
          ms = ms * 10 + (ord(ch) - ord('0'))
      discard setTimer(
        Moment.fromNow(milliseconds(200)),
        proc(udata: pointer) {.gcsafe, raises: [].} =
          sleep(ms), # blocks the event loop: only the watcher thread can act
      )
  r.phase = phServing

proc stop(r: Remote) {.async: (raises: []).} =
  ## [plan §3.1 item 5] An orderly end: no new connection, those open closed.
  for c in r.conns.values:
    if not c.verdict.finished:
      c.verdict.complete(Opt.none(seq[byte]))
  if r.listener != nil:
    await r.listener.close()

proc handle(r: Remote, m: LcnRchMessage): bool =
  ## One control message; true once the process is to end in order.
  type K = LcnRchMessageKind
  case r.phase
  of phSnapshot:
    if m.kind != K.lcn_Rch_snapshot:
      lost("the first control message is not the snapshot")
    r.trust = snapshotOf(m.arm_lcn_Rch_snapshot).valueOr:
      lost("the snapshot does not check: " & error)
    r.phase = phListen
  of phListen:
    case m.kind
    of K.lcn_Rch_test_key:
      when TestKey:
        r.key = fromPkcs8(m.arm_lcn_Rch_test_key.pkcs8).valueOr:
          lost("the test key does not load: " & error)
      else:
        lost("a test key reached a build without test signing")
    of K.lcn_Rch_listen:
      r.listen(m.arm_lcn_Rch_listen)
    else:
      lost("a control message before listen that is not test_key")
  of phServing:
    case m.kind
    of K.lcn_Rch_signed, K.lcn_Rch_sign_refused:
      if not r.client.deliver(m.answerId, m.answerOf):
        lost("logosd answered a sign request this process never sent")
    of K.lcn_Rch_hello_admit:
      let a = m.arm_lcn_Rch_hello_admit
      let c = r.conns.getOrDefault(a.id)
      if c != nil and not c.verdict.finished:
        c.verdict.complete(Opt.some(a.response))
    of K.lcn_Rch_hello_refuse:
      let a = m.arm_lcn_Rch_hello_refuse
      let c = r.conns.getOrDefault(a.id)
      if c != nil and not c.verdict.finished:
        c.refusal = a.response
        c.verdict.complete(Opt.none(seq[byte]))
    of K.lcn_Rch_rc_out:
      let a = m.arm_lcn_Rch_rc_out
      let c = r.conns.getOrDefault(a.id)
      if c != nil and not c.s.isClosed:
        asyncSpawn relayOut(c.s, a.frame)
    of K.lcn_Rch_close_conn:
      let c = r.conns.getOrDefault(m.arm_lcn_Rch_close_conn.id)
      if c != nil:
        if not c.verdict.finished:
          c.verdict.complete(Opt.none(seq[byte]))
        asyncSpawn c.s.close()
    of K.lcn_Rch_stop:
      return true
    else:
      lost("an unexpected control message")
  false

proc run(r: Remote) {.async: (raises: []).} =
  var buf = newSeq[byte](64 * 1024)
  while true:
    var n = 0
    try:
      n = await r.ctl.readOnce(addr buf[0], buf.len)
    except CancelledError, TransportError:
      lost("the control channel failed")
    if n == 0:
      lost("") # logosd closed the channel, or ended
    let frames = r.reader.feed(buf.toOpenArray(0, n - 1)).valueOr:
      lost("a control frame over the channel's limit")
    for body in frames:
      let m = decodeMessage(body).valueOr:
        lost("a control frame that is not a channel message: " & error)
      if r.handle(m):
        await r.stop()
        return

proc runRemote*() {.noreturn.} =
  ## The whole program.
  discard posix.signal(posix.SIGPIPE, posix.SIG_IGN)
  let args = commandLineParams()
  if args.len == 0 or args[0] != RoleListener:
    ended("usage: logos_remote listener --parent=<pid> (started by logosd)", ExitUsage)
  let parent = parentArg(args).valueOr:
    ended("no --parent=<pid> argument", ExitUsage)
  # [plan §3.1 item 2] The watch first, then the comparison, before fd 3 is read.
  let w = watchParent(parent).valueOr:
    ended(error, ExitLost)
  for fd in [ControlFd, ListenFd, LockFd]:
    if posix.fcntl(fd, posix.F_GETFD) < 0:
      ended("no descriptor " & $fd & ": not started by logosd", ExitUsage)
    discard posix.fcntl(fd, posix.F_SETFD, posix.FD_CLOEXEC)
  writePid(LockFd)
  try:
    createThread(watcher, watcherMain, w)
  except ResourceExhaustedError:
    ended("cannot start the watcher thread", ExitLost)
  # Non-blocking, as chronos reads a pipe transport until EAGAIN: a blocking
  # descriptor would hold the event loop in its second read.
  let fl = posix.fcntl(ControlFd, posix.F_GETFL)
  if fl < 0 or posix.fcntl(ControlFd, posix.F_SETFL, fl or posix.O_NONBLOCK) < 0:
    ended("the control channel cannot be used", ExitLost)
  let ctl = fromPipe2(AsyncFD(ControlFd)).valueOr:
    ended("the control channel cannot be used", ExitLost)
  let r = Remote(ctl: ctl, reader: newRchReader(), phase: phSnapshot)
  r.client = newSignClient(
    tlsServer,
    proc(id: uint64, alg: uint16, input: seq[byte]): bool {.gcsafe, raises: [].} =
      r.send(signRequest(id, alg, input))
      true,
  )
  waitFor r.run()
  quit(0)

{.pop.}
