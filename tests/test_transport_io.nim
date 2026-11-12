## TRANSPORT §2.1, §2.3, §3.1, §8.1, §8.2, §8.6, §9.1; G58, G61, G77: the
## unix-stream transport I/O layer over real sockets, against in-process raw
## sockets and a child-process peer (`tests/support/trnpeer.nim`). Step 10a-1:
## the I/O thread, endpoints, the peer check and the Hello exchange.

import std/[atomics, base64, monotimes, os, posix, sequtils, strutils, times]
import unittest2
import results
import ../src/logos_core/cbor
import ../src/logos_core/base/hex
import ../src/logos_core/transport/[envelope, framing]
import ../src/logos_core/transport/io/sock
import ./support/[ctl, peerbuild, peerproc, trnowner]

# Sockets go under a short private base: TMPDIR when the deepest path fits
# `sun_path` and its filesystem holds sockets, else /tmp (plan §5.1).
proc holdsSockets(dir: string): bool =
  let fd = unixSocket()
  let path = dir / "probe.sock"
  result = sockBind(fd, cstring(path)) == 0
  discard fdClose(fd)
  discard unlink(cstring(path))

proc makeBase(): string =
  let probe = "/12345678/logos_storage_module.sock"
  var root = getEnv("TMPDIR", "/tmp").strip(leading = false, chars = {'/'})
  if root.len == 0 or root.len + 16 + probe.len + 1 > int(sunPathMax()):
    root = "/tmp"
  result = root / ("lcnio-" & $getpid())
  createDir(result)
  if not holdsSockets(result) and root != "/tmp":
    removeDir(result)
    result = "/tmp" / ("lcnio-" & $getpid())
    createDir(result)
  doAssert chmod(cstring(result), 0o700) == 0

let base = makeBase()

const deviceTarget = defined(android) or defined(ios)

template peerTest(name: string, body: untyped) =
  ## A test with a child-process peer. Skipped on Android and iOS: the peer is
  ## built when the suite runs (`peerbuild.nim`), and a device has no Nim
  ## compiler (plan §2.13).
  test name:
    when deviceTarget:
      skip()
    else:
      body

# Helpers ---------------------------------------------------------------------------

proc newEndpoint(module = Provider): Endpoint =
  let ep = createEndpoint(base, module)
  doAssert ep.isOk, ep.error.msg
  ep.get

proc statOf(path: string): StatInfo =
  doAssert lstatPath(cstring(path), addr result) == 0, path

proc entries(dir: string): int =
  for _ in walkDir(dir):
    inc result

proc openFds(): int =
  entries("/dev/fd")

proc setBlocking(fd: cint) =
  let fl = fcntl(fd, F_GETFL)
  discard fcntl(fd, F_SETFL, fl and not O_NONBLOCK)

proc rawConnect(path: string): cint =
  ## A plain blocking client socket, outside the transport.
  result = unixSocket()
  doAssert result >= 0
  let r = sockConnect(result, cstring(path))
  if -r == sock.EINPROGRESS:
    var p = TPollfd(fd: result, events: POLLOUT)
    doAssert posix.poll(addr p, 1, 2000) == 1
    doAssert connectResult(result) == 0
  else:
    doAssert r == 0, "connect: " & errText(r)
  setBlocking(result)

proc readUntilEnd(fd: cint, o: Owner = nil, timeoutMs = 3000): (seq[byte], bool) =
  ## What arrives until end of input (true) or the deadline (false). The owner,
  ## when given, keeps handling its events meanwhile (it admits Hellos).
  var data: seq[byte]
  var buf: array[65536, byte]
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    if not o.isNil:
      discard o.pump()
    if not waitReadable(fd, 5):
      continue
    let n = posix.read(fd, addr buf[0], buf.len)
    if n <= 0:
      return (data, true)
    data.add(buf.toOpenArray(0, n - 1))
  (data, false)

proc messages(data: seq[byte]): seq[Message] =
  var r = newFrameReader()
  for body in r.feed(data).get:
    result.add(decodeMessage(body).get)

proc isProtocolError(data: seq[byte], code: ErrorCode): bool =
  let ms = messages(data)
  ms.len == 1 and ms[0].kind == mkProtocolError and ms[0].protocolError.code == code

proc helloBytes(token: openArray[byte], module = Provider): seq[byte] =
  frame(
    encodeCbor(
      toCbor(
        Message(
          kind: mkHello,
          hello: Hello(module: module, token: @token, schema: storageRoot),
        )
      )
    )
  ).get

proc toTicket(b: seq[byte]): RouteTicket =
  doAssert b.len == result.len
  copyMem(addr result[0], unsafeAddr b[0], b.len)

proc op(name: string, fields: varargs[(string, CborValue)]): CborValue =
  var e = @[(cbor("op"), cbor(name))]
  for (k, v) in fields:
    e.add((cbor(k), v))
  cborMap(e)

proc ask(p: Peer, req: CborValue, o: Owner = nil): CborValue =
  ## The child's answer; the owner, when given, keeps handling its events.
  doAssert ctlSend(p.ctl, req)
  let deadline = getMonoTime() + initDuration(seconds = 20)
  while getMonoTime() < deadline:
    if not o.isNil:
      discard o.pump()
    if waitReadable(p.ctl, 5):
      return ctlRecv(p.ctl).get
  doAssert false, "the child did not answer"

proc childTicket(p: Peer, consumer = "app", endpoint = "ep-1"): RouteTicket =
  toTicket(
    p.ask(op("issue", ("consumer", cbor(consumer)), ("endpoint", cbor(endpoint)))).bytes(
      "ticket"
    )
  )

proc childEvents(p: Peer): seq[CborValue] =
  p.ask(op("events")).field("events").items

proc finish(p: var Peer): int =
  discard p.ask(op("exit"))
  p.waitPeer()

proc kinds(o: Owner, conn: ConnId): seq[IoEventKind] =
  for ev in o.log:
    if ev.conn == conn:
      result.add(ev.kind)

proc oneOf(o: Owner, conn: ConnId, timeoutMs = 5000): Opt[IoEvent] =
  o.expect(
    proc(ev: IoEvent): bool =
      ev.conn == conn and ev.kind in {evConnected, evConnectFailed},
    timeoutMs,
  )

# Suites ------------------------------------------------------------------------------

type Probe = object
  loop: Loop
  res: Atomic[int]

proc probeSink(ev: sink IoEvent, ctx: pointer) {.nimcall, gcsafe, raises: [].} =
  let p = cast[ptr Probe](ctx)
  if ev.kind == evStopped:
    p.res.store(ord(p.loop.submit(IoCommand(kind: cmdClose, conn: 1))) + 1)

type Feeder = object
  loop: Loop
  conn: uint64

proc feed(f: Feeder) {.thread.} =
  for i in 0 ..< 2500:
    let r = f.loop.submit(
      IoCommand(conn: f.conn, kind: cmdCall, tag: uint64(i), methodName: "exists")
    )
    doAssert r == sbOk

suite "trnio.thread: the transport I/O thread (G77, I75) [IMPL]":
  test "start and stop with no sockets":
    let o = newOwner()
    o.stop()
    check o.log.mapIt(it.kind) == @[evStopped]

  test "stop with live connections: each is reported, then evStopped is last":
    let ep = newEndpoint()
    let o = newOwner()
    check o.serve(1, dupCloexec(ep.listener))
    o.connect(7, ep.path, o.issue())
    check o.oneOf(7).map(
      proc(e: IoEvent): IoEventKind =
        e.kind
    ) == Opt.some(evConnected)
    o.cursor = 0 # the callee is established before the caller reads its answer
    check o.expectKind(evEstablished).isSome
    o.stop()
    let closed = o.log.filterIt(it.kind == evClosed)
    check closed.len == 2
    check closed.allIt(it.cause == ccShutdown)
    check o.log[^1].kind == evStopped
    check removeEndpoint(ep).isOk

  test "submit is sbStopped once stopping began":
    let probe = createShared(Probe)
    probe.loop = startTransport(fastConfig(), probeSink, probe).get
    probe.loop.stopTransport()
    check probe.res.load == ord(sbStopped) + 1
    deallocShared(probe)

  test "10 000 commands from four threads keep each thread's order":
    let o = newOwner()
    var threads: array[4, Thread[Feeder]]
    for i in 0 ..< 4:
      createThread(threads[i], feed, Feeder(loop: o.loop, conn: 1000'u64 + uint64(i)))
    joinThreads(threads)
    var seen = 0
    let deadline = getMonoTime() + initDuration(seconds = 20)
    while seen < 10_000 and getMonoTime() < deadline:
      discard o.pump(10)
      seen = o.log.countIt(it.kind == evLocalFailure)
    o.stop()
    check seen == 10_000
    for i in 0 ..< 4:
      let tags = o.log
        .filterIt(it.kind == evLocalFailure and it.conn == 1000'u64 + uint64(i))
        .mapIt(it.localTag)
      check tags == toSeq(0'u64 ..< 2500'u64)

  test "a full cycle leaves the open-fd count unchanged":
    proc cycle() =
      let ep = newEndpoint()
      let o = newOwner()
      doAssert o.serve(1, dupCloexec(ep.listener))
      o.connect(3, ep.path, o.issue())
      doAssert o.expectKind(evConnected, 3).isSome
      o.callExists(3, 1)
      doAssert o.expectKind(evResponse, 3).isSome
      o.stop()
      doAssert removeEndpoint(ep).isOk

    cycle() # warm-up: lazily opened process-wide descriptors
    let before = openFds()
    cycle()
    check openFds() == before

suite "trnio.endpoint: endpoint placement and validation (TRANSPORT §8.2, G58)":
  test "[TRN-0180] [TRN-0181] the directory is 0700 and the euid's, whatever the umask":
    for mask in [0o000, 0o022, 0o077]:
      let old = umask(Mode(mask))
      let ep = createEndpoint(base, Provider)
      discard umask(old)
      check ep.isOk
      let d = statOf(ep.get.dir.path)
      check d.isDir
      check d.perm == 0o700
      check d.uid == effectiveUid()
      check validateEndpoint(ep.get).isOk
      check removeEndpoint(ep.get).isOk

  test "[TRN-0182] an object already at the path is rejected and left untouched":
    let d = makeEndpointDir(base).get
    let path = d.path / socketName(Provider)
    # A regular file, a directory, symbolic links (dangling and not), a socket.
    writeFile(path, "keep")
    var before = statOf(path)
    check bindEndpoint(d, Provider).error.kind == eeExists
    check statOf(path).ino == before.ino
    check readFile(path) == "keep"
    removeFile(path)
    createDir(path)
    before = statOf(path)
    check bindEndpoint(d, Provider).error.kind == eeExists
    check statOf(path).ino == before.ino and statOf(path).isDir
    removeDir(path)
    for target in [base / "missing-target", base / "present-target"]:
      if target.endsWith("present-target"):
        writeFile(target, "t")
      doAssert symlink(cstring(target), cstring(path)) == 0
      before = statOf(path)
      check bindEndpoint(d, Provider).error.kind == eeExists
      check statOf(path).isLink and statOf(path).ino == before.ino
      check expandSymlink(path) == target
      if target.endsWith("present-target"):
        check readFile(target) == "t"
        removeFile(target)
      else:
        var st: StatInfo
        check lstatPath(cstring(target), addr st) < 0 # nothing made at the target
      discard unlink(cstring(path))
    let other = unixSocket()
    doAssert sockBind(other, cstring(path)) == 0
    before = statOf(path)
    check bindEndpoint(d, Provider).error.kind == eeExists
    check statOf(path).ino == before.ino and statOf(path).isSocket
    discard fdClose(other)
    discard unlink(cstring(path))
    check removeDir(d).isOk

  test "[TRN-0183] the socket is bound and listening before it is handed off":
    let ep = newEndpoint()
    var typ, domain, listening: cint
    check sockInfo(ep.listener, addr typ, addr domain, addr listening) == 0
    check typ == sock.SockStream and domain == sock.AfUnix and listening == 1
    check sockName(ep.listener).get == ep.path
    let s = statOf(ep.path)
    check s.isSocket and s.uid == effectiveUid() and s.perm == 0o600
    check removeEndpoint(ep).isOk

  test "[TRN-0185] validation fails after each tamper":
    # Tagged, claimed with step 4b (F3).
    var ep = newEndpoint()
    check validateEndpoint(ep).isOk
    # The directory's mode.
    doAssert chmod(cstring(ep.dir.path), 0o755) == 0
    check validateEndpoint(ep).error.kind == eeInvalid
    doAssert chmod(cstring(ep.dir.path), 0o700) == 0
    check validateEndpoint(ep).isOk
    # The directory renamed and replaced by a symbolic link to it.
    let moved = ep.dir.path & ".moved"
    moveDir(ep.dir.path, moved)
    doAssert symlink(cstring(moved), cstring(ep.dir.path)) == 0
    check validateEndpoint(ep).error.kind == eeInvalid
    discard unlink(cstring(ep.dir.path))
    moveDir(moved, ep.dir.path)
    check validateEndpoint(ep).isOk
    # A bound socket that is not listening, and a pipe, as the listener.
    let idle = unixSocket()
    doAssert sockBind(idle, cstring(base / "idle.sock")) == 0
    var swapped = ep
    swapped.listener = idle
    check validateEndpoint(swapped).error.kind == eeInvalid
    var fds: array[2, cint]
    doAssert pipe(fds) == 0
    swapped.listener = fds[0]
    check validateEndpoint(swapped).error.kind == eeInvalid
    discard fdClose(idle)
    discard unlink(cstring(base / "idle.sock"))
    discard posix.close(fds[0])
    discard posix.close(fds[1])
    # The socket unlinked and another bound in its place: removal leaves it.
    doAssert unlink(cstring(ep.path)) == 0
    let squatter = unixSocket()
    doAssert sockBind(squatter, cstring(ep.path)) == 0
    doAssert sockListen(squatter, 1) == 0
    check validateEndpoint(ep).error.kind == eeInvalid
    check removeEndpoint(ep).error.kind == eeReplaced
    check statOf(ep.path).isSocket
    discard fdClose(squatter)
    discard unlink(cstring(ep.path))
    discard rmdir(cstring(ep.dir.path))

  test "[G58] a path that does not fit sun_path fails and leaves nothing":
    let before = entries(base)
    let r = createEndpoint(base, repeat('m', 100))
    check r.error.kind == eeTooLong
    check entries(base) == before

  test "removal removes only the endpoint's own objects":
    let ep = newEndpoint()
    check removeEndpoint(ep).isOk
    check not fileExists(ep.path) and not dirExists(ep.dir.path)
    check dirExists(base)

  test "[TRN-0184] adoptListener takes only a listening unix stream socket":
    # Tagged, claimed with step 4b: the child of `trnio.peer` serves an
    # inherited listener through it.
    let ep = newEndpoint()
    check adoptListener(ep.listener).isOk
    let idle = unixSocket()
    check adoptListener(idle).error.kind == eeInvalid
    var fds: array[2, cint]
    doAssert pipe(fds) == 0
    check adoptListener(fds[0]).error.kind == eeInvalid
    discard fdClose(idle)
    discard posix.close(fds[0])
    discard posix.close(fds[1])
    check removeEndpoint(ep).isOk

suite "trnio.peer: the peer's operating-system identity (TRANSPORT §8.2, §9.1)":
  peerTest "[TRN-0188] [TRN-0189] [TRN-0192] a child serves the parent's listener; the peer check passes":
    let ep = newEndpoint()
    var p = spawnPeer(peerProgram(), ["owner", "serve"], ep.listener)
    let t = p.childTicket(consumer = "app-7")
    let o = newOwner()
    o.connect(1, ep.path, t)
    let c = o.oneOf(1)
    check c.isSome and c.get.kind == evConnected
    if c.isSome and c.get.kind == evConnected:
      # The listener's creator: this process, not the serving child.
      check c.get.connectedPeer.uid == effectiveUid()
      when defined(linux):
        check c.get.connectedPeer.pid == Opt.some(int32(getpid()))
      o.callExists(1, 1)
      let r = o.expectKind(evResponse, 1)
      check r.isSome and r.get.outcome.ok
    let est = p.childEvents().filterIt(it.text("kind") == "evEstablished")
    check est.len == 1
    if est.len == 1:
      check est[0].text("consumer") == "app-7"
      check est[0].num("uid") == uint64(effectiveUid())
    o.stop()
    check p.finish() == 0
    check removeEndpoint(ep).isOk

  peerTest "[TRN-0190] an unexpected identity: TRANSPORT_ERROR; the ticket is neither sent nor consumed":
    let ep = newEndpoint()
    var p = spawnPeer(peerProgram(), ["raw"], ep.listener)
    let o = newOwner()
    let t = o.issue()
    o.connect(1, ep.path, t, uid = effectiveUid() + 1)
    let f = o.expectKind(evConnectFailed, 1)
    check f.isSome
    if f.isSome:
      check f.get.failCode == ecTransport
      check f.get.failCause == cfPeerMismatch
      check f.get.observed.map(
        proc(c: PeerCred): uint32 =
          c.uid
      ) == Opt.some(effectiveUid())
    # The child accepted and read until end of input: nothing arrived.
    let got = ctlRecv(p.ctl)
    check got.isSome and got.get.num("bytes") == 0
    # F1: the issuer's non-consuming check finds the record live.
    check o.live(t)
    discard ctlSend(p.ctl, op("exit"))
    check p.waitPeer() == 0
    o.stop()
    check removeEndpoint(ep).isOk

  peerTest "[TRN-0190] [G129] a listener created by another user (privileged)":
    let user = getEnv("LCN_PEER_USER")
    if user.len == 0 or findExe("sudo").len == 0:
      skip()
    else:
      let dir = "/tmp/lcnpeer-" & $getpid()
      createDir(dir)
      doAssert chmod(cstring(dir), 0o755) == 0
      let exe = dir / "trnpeer"
      copyFile(peerProgram(), exe)
      doAssert chmod(cstring(exe), 0o755) == 0
      var p = spawnPeer(
        exe,
        ["squat", "/tmp"],
        withCtl = false,
        captureStdout = true,
        prefix = ["sudo", "-n", "-u", user],
      )
      let ready = p.readLine()
      check ready.startsWith("ready ")
      let o = newOwner()
      let t = o.issue()
      o.connect(1, ready.substr(6), t)
      let f = o.expectKind(evConnectFailed, 1)
      check f.isSome and f.get.failCause == cfPeerMismatch
      check f.isSome and f.get.observed.isSome and
        f.get.observed.get.uid != effectiveUid()
      check p.readLine() == "bytes 0"
      check o.live(t)
      check p.waitPeer() == 0
      o.stop()
      removeDir(dir)

  peerTest "[TRN-0188] the callee sees the connecting process":
    let ep = newEndpoint()
    let o = newOwner()
    check o.serve(1, dupCloexec(ep.listener))
    var p = spawnPeer(peerProgram(), ["owner"])
    let t = o.issue()
    let r = p.ask(
      op(
        "connect",
        ("path", cbor(ep.path)),
        ("uid", cbor(uint64(effectiveUid()))),
        ("ticket", cbor(@t)),
      ),
      o,
    )
    check r.text("kind") == "evConnected"
    let est = o.expectKind(evEstablished)
    check est.isSome
    if est.isSome:
      check est.get.peer.isSome
      check est.get.peer.get.uid == effectiveUid()
      check est.get.peer.get.pid == Opt.some(int32(p.pid))
    check p.finish() == 0
    o.stop()
    check removeEndpoint(ep).isOk

  test "[TRN-0069] [TRN-0247] only the exact path is used":
    let derived = newEndpoint()
    let named = newEndpoint()
    let o = newOwner()
    check o.serve(1, dupCloexec(named.listener))
    o.connect(1, named.path, o.issue())
    check o.oneOf(1).map(
      proc(e: IoEvent): IoEventKind =
        e.kind
    ) == Opt.some(evConnected)
    # The other instance's socket, at the same file name, got no connection.
    check wouldBlock(sockAccept(derived.listener))
    o.connect(2, base / "absent" / socketName(Provider), o.issue())
    let f = o.oneOf(2)
    check f.isSome and f.get.kind == evConnectFailed
    check f.isSome and f.get.failCode == ecTransport and f.get.failCause == cfConnect
    o.stop()
    check removeEndpoint(derived).isOk
    check removeEndpoint(named).isOk

suite "trnio.hello: the Hello exchange over sockets (TRANSPORT §3.1, §8.1, §8.2, §8.6)":
  peerTest "[TRN-0192] [TRN-0194] [TRN-0349] [CAP-0253] a child caller: the session binds the ticket's route":
    let ep = newEndpoint()
    let o = newOwner()
    check o.serve(1, dupCloexec(ep.listener))
    var p = spawnPeer(peerProgram(), ["owner"])
    let b = binding(consumer = "app-9", route = "route-9")
    let t = o.issue(b)
    let r = p.ask(
      op(
        "connect",
        ("path", cbor(ep.path)),
        ("uid", cbor(uint64(effectiveUid()))),
        ("ticket", cbor(@t)),
      ),
      o,
    )
    check r.text("kind") == "evConnected"
    let est = o.expectKind(evEstablished)
    check est.isSome and est.get.binding == b
    # Redeemed before the Hello response (TRN-0194): the record is gone.
    check not o.live(t)
    let c = p.ask(op("call", ("tag", cbor(5'u64))), o)
    check c.text("kind") == "evResponse" and c.flag("ok")
    check p.finish() == 0
    o.stop()
    check removeEndpoint(ep).isOk

  test "[TRN-0145] [TRN-0320] a ticket offered again on another connection is NOT_AUTHORISED":
    let ep = newEndpoint()
    let o = newOwner()
    check o.serve(1, dupCloexec(ep.listener))
    let t = o.issue()
    o.connect(1, ep.path, t)
    check o.oneOf(1).get.kind == evConnected
    o.connect(2, ep.path, t)
    let f = o.oneOf(2)
    check f.isSome and f.get.kind == evConnectFailed
    check f.isSome and f.get.failCode == ecNotAuthorised and f.get.failCause == cfHello
    o.stop()
    check removeEndpoint(ep).isOk

  test "[TRN-0177] one ticket on two simultaneous connections: exactly one is established":
    let ep = newEndpoint()
    let o = newOwner()
    check o.serve(1, dupCloexec(ep.listener))
    let t = o.issue()
    o.connect(1, ep.path, t)
    o.connect(2, ep.path, t)
    let a = o.oneOf(1)
    o.cursor = 0
    let b = o.oneOf(2)
    check a.isSome and b.isSome
    let ks = @[a.get.kind, b.get.kind]
    check ks.count(evConnected) == 1
    check ks.count(evConnectFailed) == 1
    for e in [a.get, b.get]:
      if e.kind == evConnectFailed:
        check e.failCode == ecNotAuthorised
    check o.log.countIt(it.kind == evEstablished) == 1
    o.stop()
    check removeEndpoint(ep).isOk

  test "[TRN-0276] a Hello the owner cannot evaluate: MODULE_ERROR, close, the ticket stays live":
    let ep = newEndpoint()
    let o = newOwner()
    o.admit = amUnavailable
    check o.serve(1, dupCloexec(ep.listener))
    let t = o.issue()
    o.connect(1, ep.path, t)
    let f = o.oneOf(1)
    check f.isSome and f.get.kind == evConnectFailed
    check f.isSome and f.get.failCode == ecModule
    o.cursor = 0
    let closed = o.expect(
      proc(ev: IoEvent): bool =
        ev.kind == evClosed and ev.conn >= AcceptedConnBase
    )
    check closed.isSome and closed.get.cause == ccProtocol and
      closed.get.code == ecModule
    check o.live(t)
    o.stop()
    check removeEndpoint(ep).isOk

  test "[TRN-0378] [G61] callee: an idle connection closes at the Hello deadline, without ProtocolError":
    let ep = newEndpoint()
    let o = newOwner()
    check o.serve(1, dupCloexec(ep.listener))
    let start = getMonoTime()
    let raw = rawConnect(ep.path)
    let (data, ended) = readUntilEnd(raw, o)
    let took = (getMonoTime() - start).inMilliseconds
    check ended and data.len == 0
    check took >= 250
    let c = o.expectKind(evClosed)
    check c.isSome and c.get.cause == ccHelloTimeout
    discard fdClose(raw)
    o.stop()
    check removeEndpoint(ep).isOk

  test "[TRN-0378] [G61] caller: a callee that never answers is TRANSPORT_ERROR at the deadline":
    let ep = newEndpoint() # listening, never served
    let o = newOwner()
    let start = getMonoTime()
    o.connect(1, ep.path, o.issue())
    let f = o.oneOf(1)
    check f.isSome and f.get.kind == evConnectFailed
    check f.isSome and f.get.failCode == ecTransport and f.get.failCause == cfHello
    check (getMonoTime() - start).inMilliseconds >= 250
    o.stop()
    check removeEndpoint(ep).isOk

  test "[TRN-0378] [TRN-0379] past maxPendingHellos: MODULE_ERROR; an established session is unaffected":
    var cfg = fastConfig()
    cfg.maxPendingHellos = 2
    cfg.helloTimeout = 3000 * Ms
    let ep = newEndpoint()
    let o = newOwner(cfg)
    check o.serve(1, dupCloexec(ep.listener))
    o.connect(1, ep.path, o.issue())
    check o.oneOf(1).get.kind == evConnected
    let idle = @[rawConnect(ep.path), rawConnect(ep.path)]
    let extra = rawConnect(ep.path)
    let (data, ended) = readUntilEnd(extra, o, 2000)
    check ended and isProtocolError(data, ecModule)
    o.callExists(1, 1)
    let r = o.expectKind(evResponse, 1)
    check r.isSome and r.get.outcome.ok
    for fd in idle & extra:
      discard fdClose(fd)
    o.stop()
    check removeEndpoint(ep).isOk

  test "[TRN-0381] stalled 16 MiB Hellos are bounded by the pre-Hello pool":
    let ep = newEndpoint()
    let o = newOwner() # maxHelloInputBytes: 32 MiB; Hello deadline 300 ms
    check o.serve(1, dupCloexec(ep.listener))
    var evil: seq[cint]
    for _ in 0 ..< 8:
      let fd = rawConnect(ep.path)
      check writeAll(fd, @(prefixOf(MinFrameLimit)) & newSeq[byte](100))
      evil.add(fd)
    sleep(150)
    o.connect(1, ep.path, o.issue())
    # Waiting behind the stalled frames: not admitted while they hold the pool.
    check o.oneOf(1, 100).isNone
    let c = o.oneOf(1, 3000)
    check c.isSome and c.get.kind == evConnected
    for fd in evil:
      let (data, ended) = readUntilEnd(fd, o, 2000)
      check ended and data.len == 0
      discard fdClose(fd)
    o.stop()
    check removeEndpoint(ep).isOk

  test "[TRN-0054] [TRN-0055] [TRN-0199] a length prefix over the limit: INVALID_PARAMS, close":
    let ep = newEndpoint()
    let o = newOwner()
    check o.serve(1, dupCloexec(ep.listener))
    let raw = rawConnect(ep.path)
    check writeAll(raw, prefixOf(MinFrameLimit + 1))
    let (data, ended) = readUntilEnd(raw, o)
    check ended and isProtocolError(data, ecInvalidParams)
    let c = o.expectKind(evClosed)
    check c.isSome and c.get.cause == ccProtocol and c.get.code == ecInvalidParams
    check o.log.countIt(it.kind == evHello) == 0
    discard fdClose(raw)
    o.stop()
    check removeEndpoint(ep).isOk

  test "[TRN-0273] [TRN-0274] a Request before the Hello: INVALID_PARAMS, close, no dispatch":
    let ep = newEndpoint()
    let o = newOwner()
    check o.serve(1, dupCloexec(ep.listener))
    let raw = rawConnect(ep.path)
    let req = Message(
      kind: mkRequest,
      request: Request(
        id: 0, methodName: "exists", params: cborMap((cbor("cid"), cbor("bafy")))
      ),
    )
    check writeAll(raw, frame(encodeCbor(toCbor(req))).get)
    let (data, ended) = readUntilEnd(raw, o)
    check ended and isProtocolError(data, ecInvalidParams)
    o.settle(50)
    check o.log.countIt(it.kind in {evEstablished, evDispatch}) == 0
    discard fdClose(raw)
    o.stop()
    check removeEndpoint(ep).isOk

  test "[CAP-0255] [CAP-0256] [CAP-0252] an empty token, a decision id and a COSE object are NOT_AUTHORISED":
    let ep = newEndpoint()
    let o = newOwner()
    check o.serve(1, dupCloexec(ep.listener))
    let cose = encodeCbor(
      cborTag(
        18,
        cborArray(
          cbor(@[0xa1'u8, 0x01, 0x26]),
          cborMap(),
          cbor(@[1'u8, 2, 3]),
          cbor(newSeq[byte](64)),
        ),
      )
    )
    let decision = cast[seq[byte]]("decision-7f3a9c0e4b2d1a68")
    for token in [newSeq[byte](), decision, cose]:
      let raw = rawConnect(ep.path)
      check writeAll(raw, helloBytes(token))
      let (data, ended) = readUntilEnd(raw, o)
      check ended and isProtocolError(data, ecNotAuthorised)
      discard fdClose(raw)
    o.settle(50)
    check o.log.countIt(it.kind in {evEstablished, evDispatch}) == 0
    o.stop()
    check removeEndpoint(ep).isOk

  peerTest "[TRN-0164] [TRN-0171] no event or diagnostic carries the ticket":
    let ep = newEndpoint()
    var p = spawnPeer(peerProgram(), ["raw"], ep.listener)
    let o = newOwner()
    let t = o.issue()
    # A peer mismatch, then a session, a replay and a missing path.
    o.connect(1, ep.path, t, uid = effectiveUid() + 1)
    discard o.oneOf(1)
    discard ctlRecv(p.ctl)
    discard ctlSend(p.ctl, op("exit"))
    check p.waitPeer() == 0
    let served = newEndpoint()
    check o.serve(2, dupCloexec(served.listener))
    o.connect(2, served.path, t)
    discard o.oneOf(2)
    o.connect(3, served.path, t)
    discard o.oneOf(3)
    o.connect(4, base / "absent.sock", t)
    discard o.oneOf(4)
    o.stop()
    var texts: seq[string]
    for ev in o.log:
      case ev.kind
      of evConnectFailed:
        texts.add(ev.failMsg)
      of evServeFailed:
        texts.add(ev.serveError)
      of evLocalFailure:
        texts.add(ev.localMsg)
      of evEstablished:
        texts.add(
          [
            ev.binding.consumer, ev.binding.provider, ev.binding.endpoint,
            ev.binding.route,
          ]
        )
      of evDispatch:
        texts.add(cast[string](ev.params))
      of evResponse:
        if ev.outcome.ok:
          texts.add(cast[string](ev.outcome.result))
        else:
          texts.add(ev.outcome.failure.message.get(""))
      else:
        discard
    let raw = cast[string](@t)
    let hexed = hex.toHex(t)
    for s in texts:
      check raw notin s
      check hexed.toLowerAscii notin s.toLowerAscii
      check base64.encode(t) notin s
    check removeEndpoint(ep).isOk
    check removeEndpoint(served).isOk

suite "trnio.close: closing during the Hello exchange (TRANSPORT §3.2, §8.6)":
  test "cmdStopServing closes the Hellos pending at the endpoint":
    let ep = newEndpoint()
    var cfg = fastConfig()
    cfg.helloTimeout = 3000 * Ms
    let o = newOwner(cfg)
    check o.serve(1, dupCloexec(ep.listener))
    let raw = rawConnect(ep.path)
    sleep(100)
    o.send(IoCommand(kind: cmdStopServing, stopEndpoint: 1))
    let (data, ended) = readUntilEnd(raw, o, 2000)
    check ended and data.len == 0
    let c = o.expectKind(evClosed)
    check c.isSome and c.get.cause == ccOwner
    discard fdClose(raw)
    o.stop()
    check removeEndpoint(ep).isOk

  test "[TRN-0381] a close inside a frame releases its reservation":
    var cfg = fastConfig()
    cfg.maxHelloInputBytes = int(MinFrameLimit) # one maximal frame
    cfg.helloTimeout = 3000 * Ms
    let ep = newEndpoint()
    let o = newOwner(cfg)
    check o.serve(1, dupCloexec(ep.listener))
    let raw = rawConnect(ep.path)
    check writeAll(raw, @(prefixOf(MinFrameLimit)) & newSeq[byte](10))
    sleep(100)
    discard fdClose(raw)
    let c = o.expectKind(evClosed)
    check c.isSome and c.get.cause == ccPeerClosed
    o.connect(1, ep.path, o.issue())
    let e = o.oneOf(1, 2000)
    check e.isSome and e.get.kind == evConnected
    o.stop()
    check removeEndpoint(ep).isOk

  test "half-close after the Hello: the response arrives, then the session closes":
    let ep = newEndpoint()
    let o = newOwner()
    check o.serve(1, dupCloexec(ep.listener))
    let raw = rawConnect(ep.path)
    check writeAll(raw, helloBytes(o.issue()))
    check shutdownWrite(raw) == 0
    let (data, ended) = readUntilEnd(raw, o)
    check ended
    let ms = messages(data)
    check ms.len == 1 and ms[0].kind == mkHello and ms[0].hello.token.len == 0
    o.cursor = 0
    check o.expectKind(evEstablished).isSome
    let c = o.expectKind(evClosed)
    check c.isSome and c.get.cause == ccPeerClosed
    discard fdClose(raw)
    o.stop()
    check removeEndpoint(ep).isOk

removeDir(base)
