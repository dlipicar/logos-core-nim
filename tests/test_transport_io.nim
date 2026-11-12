## TRANSPORT §2.1, §2.3, §3.1, §4, §5, §6, §8.1, §8.2, §8.6, §9.1; G58, G61, G77:
## the unix-stream transport I/O layer over real sockets, against in-process raw
## sockets and a child-process peer (`tests/support/trnpeer.nim`): the I/O
## thread, endpoints, the peer check and the Hello exchange (step 10a-1); calls,
## execution slots and the delayed queue (A21), subscriptions and Events, the
## session's end, and the aggregate limits (step 10a-2).

import std/[atomics, base64, monotimes, os, posix, sequtils, strutils, times]
import unittest2
import results
import ../src/logos_core/cbor
import ../src/logos_core/base/hex
import ../src/logos_core/commitment
import ../src/logos_core/iface/[accept, surface]
import ../src/logos_core/transport/[access, boundary, envelope, framing, session]
import ../src/logos_core/transport/io/sock
import ./support/[ctl, peerbuild, peerproc, specdata, trnowner]

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
    # maxHelloInputBytes: 32 MiB. The stalled Hellos' deadlines end 500 ms
    # before the caller's, whatever the load: it waits behind them, then fits.
    var cfg = fastConfig()
    cfg.helloTimeout = 1500 * Ms
    let o = newOwner(cfg)
    check o.serve(1, dupCloexec(ep.listener))
    var evil: seq[cint]
    for _ in 0 ..< 8:
      let fd = rawConnect(ep.path)
      check writeAll(fd, @(prefixOf(MinFrameLimit)) & newSeq[byte](100))
      evil.add(fd)
    sleep(500)
    o.connect(1, ep.path, o.issue())
    # Waiting behind the stalled frames: not admitted while they hold the pool.
    check o.oneOf(1, 100).isNone
    let c = o.oneOf(1, 5000)
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

# Sessions (step 10a-2) ----------------------------------------------------------------

let storageBoundary = boundary(storageSet, storageRoot).get
const MiB = 1024 * 1024

proc waitSink(ev: sink IoEvent, ctx: pointer) {.nimcall, gcsafe, raises: [].} =
  ## On the I/O thread: `submitWait` must refuse rather than wait.
  let p = cast[ptr Probe](ctx)
  if ev.kind == evLocalFailure and p.res.load == 0:
    p.res.store(ord(p.loop.submitWait(IoCommand(kind: cmdClose, conn: 1))) + 1)

proc openLater(g: ptr Atomic[bool]) {.thread.} =
  sleep(100)
  g[].store(false)

proc served(cfg = fastConfig()): (Owner, Endpoint) =
  let ep = newEndpoint()
  let o = newOwner(cfg)
  doAssert o.serve(1, dupCloexec(ep.listener))
  (o, ep)

proc done(o: Owner, ep: Endpoint) =
  o.stop()
  doAssert removeEndpoint(ep).isOk

proc events(o: Owner, kind: IoEventKind, conn = high(uint64), start = 0): seq[IoEvent] =
  for i in start ..< o.log.len:
    let ev = o.log[i]
    if ev.kind == kind and (conn == high(uint64) or ev.conn == conn):
      result.add(ev)

const BigWait = 20_000 * Slow
  ## A wait on multi-MiB payloads. One I/O thread serves both ends, and a debug
  ## or sanitizer build on a shared runner encodes, checks and copies each MiB
  ## several times slower than the default waits allow.

proc pumpUntil(
    owners: openArray[Owner], cond: proc(): bool, timeoutMs = 5000 * Slow
): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    if cond():
      return true
    for o in owners:
      discard o.pump()
    sleep(1)
  cond()

proc waitN(
    o: Owner,
    kind: IoEventKind,
    conn: ConnId,
    n = 1,
    start = 0,
    timeoutMs = 5000 * Slow,
    others: seq[Owner] = @[],
): seq[IoEvent] =
  ## The events of `kind` on `conn` from `start`, once there are `n` of them
  ## (or at the deadline).
  discard pumpUntil(
    @[o] & others,
    proc(): bool =
      o.events(kind, conn, start).len >= n,
    timeoutMs,
  )
  o.events(kind, conn, start)

proc attach(
    o: Owner, ep: Endpoint, conn: ConnId, b = binding(), caller: Owner = nil
): ConnId =
  ## Connects `conn` (from `caller`, else `o`) to `ep`, served by `o`; the
  ## callee's connection id.
  let c = if caller.isNil: o else: caller
  let start = o.log.len
  let cstart = c.log.len
  c.connect(conn, ep.path, o.issue(b))
  doAssert pumpUntil(
    [o, c],
    proc(): bool =
      c.events(evConnected, conn, cstart).len == 1 and
        o.events(evEstablished, high(uint64), start).len == 1,
  )
  o.cursor = o.log.len
  c.cursor = c.log.len
  o.events(evEstablished, high(uint64), start)[0].conn

proc response(
    o: Owner, conn: ConnId, tag: uint64, timeoutMs = 5000 * Slow
): Opt[IoEvent] =
  ## The outcome of call `tag` on `conn`, once it arrives.
  discard pumpUntil(
    [o],
    proc(): bool =
      o.events(evResponse, conn).anyIt(it.tag == tag),
    timeoutMs,
  )
  for r in o.events(evResponse, conn):
    if r.tag == tag:
      return Opt.some(r)
  Opt.none(IoEvent)

proc code(r: Opt[IoEvent]): ErrorCode =
  if r.isNone:
    return ecOk
  if r.get.outcome.ok:
    return ecOk
  r.get.outcome.failure.code

type Raw = object
  ## A caller outside the transport, for peers that misbehave or do not read.
  fd: cint
  caller: CallerConn
  reader: FrameReader
  got: seq[Message]

proc readMsgs(r: var Raw, o: Owner, n: int, timeoutMs = 3000 * Slow): seq[Message] =
  ## Reads until `n` more messages arrived or the deadline; the owner keeps
  ## handling its events meanwhile.
  let start = r.got.len
  var buf: array[65536, byte]
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while r.got.len - start < n and getMonoTime() < deadline:
    discard o.pump()
    if not waitReadable(r.fd, 5):
      continue
    let k = posix.read(r.fd, addr buf[0], buf.len)
    if k <= 0:
      break
    for body in r.reader.feed(buf.toOpenArray(0, k - 1)).get:
      r.got.add(decodeMessage(body).get)
  r.got[start ..^ 1]

proc rawSession(o: Owner, ep: Endpoint, b = binding()): Raw =
  result.fd = rawConnect(ep.path)
  result.caller = callerConn(storageBoundary)
  result.reader = newFrameReader()
  doAssert writeAll(result.fd, helloBytes(o.issue(b)))
  let hello = result.readMsgs(o, 1)
  doAssert hello.len == 1 and hello[0].kind == mkHello

proc sendAll(fd: cint, data: openArray[byte]): bool =
  ## A blocking write that never raises SIGPIPE (`sockSend`).
  var off = 0
  while off < data.len:
    let n = sockSend(fd, unsafeAddr data[off], csize_t(data.len - off))
    if n < 0:
      return false
    off += int(n)
  true

proc put(r: Raw, body: seq[byte]): bool {.discardable.} =
  sendAll(r.fd, frame(body).get)

proc existsParams(cid = "bafy"): CborValue =
  cborMap((cbor("cid"), cbor(cid)))

proc rootOf(set: ContractSet, declaration: string): Digest =
  for c in set.documents:
    let d = c.model.find(declaration)
    if d.isSome:
      return declarationRoot(c.model, d.get)
  doAssert false, declaration

const
  Progress = "storage.upload_progress_event"
  Started = "storage.started_event"
  Done = "storage.upload_done_event"

suite "trnio.calls: calls over sockets (TRANSPORT §4, §6, §7, §8.1, §8.6; A21)":
  test "[TRN-0141] [TRN-0136] responses may come out of order; each reaches its call":
    let (o, ep) = served()
    o.respond = false
    let callee = o.attach(ep, 1)
    o.callExists(1, 10)
    o.callExists(1, 11)
    let ds = o.waitN(evDispatch, callee, 2)
    check ds.len == 2
    o.respondTo(callee, ds[1].requestId)
    check o.response(1, 11).code == ecOk
    check o.events(evResponse, 1).mapIt(it.tag) == @[11'u64]
    o.respondTo(callee, ds[0].requestId)
    check o.response(1, 10).code == ecOk
    o.done(ep)

  test "[TRN-0314] [TRN-0316] [TRN-0130] [TRN-0382] maxInFlight 1: Cancel of the executing request commits CANCELLED at once; its slot is held until the work ends":
    var cfg = fastConfig()
    cfg.maxInFlight = 1
    let (o, ep) = served(cfg)
    o.respond = false
    let callee = o.attach(ep, 1)
    o.callExists(1, 1)
    let a = o.waitN(evDispatch, callee)[0].requestId
    o.callExists(1, 2)
    o.cancel(1, 1)
    check o.response(1, 1).code == ecCancelled
    check o.waitN(evStop, callee).mapIt(it.stopId) == @[a]
    # The provider has not stopped: the second Request waits for the slot.
    o.settle(100)
    check o.events(evDispatch, callee).len == 1
    o.workEnded(callee, a)
    let ds = o.waitN(evDispatch, callee, 2)
    check ds.len == 2
    o.respondTo(callee, ds[1].requestId)
    check o.response(1, 2).code == ecOk
    o.done(ep)

  test "[TRN-0384] a queued Request observes Cancel: CANCELLED, never dispatched":
    var cfg = fastConfig()
    cfg.maxInFlight = 1
    let (o, ep) = served(cfg)
    o.respond = false
    let callee = o.attach(ep, 1)
    o.callExists(1, 1)
    let a = o.waitN(evDispatch, callee)[0].requestId
    o.callExists(1, 2)
    o.settle(50)
    o.cancel(1, 2)
    check o.response(1, 2).code == ecCancelled
    o.respondTo(callee, a)
    check o.response(1, 1).code == ecOk
    o.settle(100)
    check o.events(evDispatch, callee).len == 1
    check o.events(evStop, callee).len == 0
    o.done(ep)

  test "[TRN-0382] the loop's slots stay held after CANCELLED and after close (a zombie) until the work ends":
    var cfg = fastConfig()
    cfg.maxTotalExecuting = 1
    let (o, ep) = served(cfg)
    o.respond = false
    let c1 = o.attach(ep, 1)
    let c2 = o.attach(ep, 2)
    o.callExists(1, 1)
    let a = o.waitN(evDispatch, c1)[0].requestId
    # Cancelled: still executing, so the other connection's Request waits.
    o.cancel(1, 1)
    check o.response(1, 1).code == ecCancelled
    o.callExists(2, 1)
    o.settle(100)
    check o.events(evDispatch, c2).len == 0
    # Closed: the work still runs and still holds the loop's slot.
    o.send(IoCommand(conn: 1, kind: cmdClose))
    check o.waitN(evClosed, c1).len == 1
    o.settle(100)
    check o.events(evDispatch, c2).len == 0
    o.workEnded(c1, a)
    check o.waitN(evDispatch, c2).len == 1
    o.done(ep)

  test "[TRN-0383] [TRN-0385] [TRN-0386] the delayed queue overflows: TRANSPORT_ERROR; every accepted Request was dispatched or failed with TRANSPORT_ERROR":
    var cfg = fastConfig()
    cfg.maxInFlight = 1
    cfg.maxDelayedRequests = 2
    let (o, ep) = served(cfg)
    o.respond = false
    let callee = o.attach(ep, 1)
    for tag in 1'u64 .. 4:
      o.callExists(1, tag)
    let closed = o.waitN(evClosed, callee)
    check closed.len == 1 and closed[0].cause == ccProtocol and
      closed[0].code == ecTransport
    let rs = o.waitN(evResponse, 1, 4)
    check rs.len == 4 and rs.allIt(it.outcome.failure.code == ecTransport)
    check o.events(evDispatch, callee).len == 1
    check closed.len == 1 and
      closed[0].ids == o.events(evDispatch, callee).mapIt(it.requestId)
    let cc = o.waitN(evClosed, 1)
    check cc.len == 1 and cc[0].cause == ccPeerError and cc[0].code == ecTransport
    o.done(ep)

  test "[TRN-0315] Cancels while the caller reads nothing exhaust the control reserve: the session terminates":
    var cfg = fastConfig()
    cfg.controlReserve = 4096
    cfg.connOutputBytes = int(MinFrameLimit) + 4096 + 4
    cfg.writeStallTimeout = 10_000 * Ms * Slow
    let (o, ep) = served(cfg)
    o.respond = false
    var raw = o.rawSession(ep)
    raw.put(raw.caller.subscribe(1, Progress).get)
    check o.waitN(evSubscribe, high(uint64)).len == 1
    o.settle(20)
    # One Event fills the data budget; the caller does not read it.
    o.publish(1, Progress, progress(0, "x".repeat(int(MinFrameLimit) - 2048)))
    o.settle(100)
    var ids: seq[uint64]
    for _ in 0 ..< 1000:
      let (id, bytes) = raw.caller.request("exists", existsParams()).get
      ids.add(id)
      raw.put(bytes)
    for id in ids:
      raw.put(raw.caller.cancel(id).get)
    let closed = o.waitN(evClosed, high(uint64))
    check closed.len == 1 and closed[0].cause == ccProtocol and
      closed[0].code == ecTransport
    # It closed before every CANCELLED was committed.
    check o.events(evStop).len < 1000
    discard fdClose(raw.fd)
    o.done(ep)

  test "[TRN-0078] connection loss fails in-flight calls with TRANSPORT_ERROR; nothing is replayed":
    let (o, ep) = served()
    o.respond = false
    let callee = o.attach(ep, 1)
    o.callExists(1, 1)
    check o.waitN(evDispatch, callee).len == 1
    o.send(IoCommand(conn: callee, kind: cmdClose))
    check o.response(1, 1).code == ecTransport
    let c2 = o.attach(ep, 2)
    o.settle(100)
    check o.events(evDispatch).len == 1
    check o.events(evDispatch, c2).len == 0
    o.done(ep)

  test "[TRN-0161] [TRN-0162] logos.schema is answered by the transport with the selected contract only":
    let (o, ep) = served()
    let callee = o.attach(ep, 1)
    o.call(1, 1, "schema")
    let r = o.response(1, 1)
    check r.isSome and r.get.outcome.ok
    check r.get.outcome.result == encodeCbor(
      schemaResponse(storageSet, storageRoot).get
    )
    check o.events(evDispatch, callee).len == 0
    o.done(ep)

  test "[TRN-0162] a route that selects an implemented interface discloses only that interface":
    let sensor = acceptContractSet(
      mirror("IFC/3.9.2.module.cddl"),
      [mirror("IFC/3.9.2.interface.cddl")],
      [mirror("IFC/3.9.2.supporting.cddl")],
    ).get
    let iface = sensor.interfaces[0].root
    let ep = newEndpoint("sensor_module")
    let o = newOwner()
    check o.serve(
      1,
      dupCloexec(ep.listener),
      provider = "sensor_module",
      contract = ContractInput(
        root: sensor.primary.root,
        schema: encodeCbor(schemaResponse(sensor, sensor.primary.root).get),
      ),
      contracts = @[sensor.primary.root, iface],
    )
    let selected =
      ContractInput(root: iface, schema: encodeCbor(schemaResponse(sensor, iface).get))
    let start = o.log.len
    o.connect(
      1,
      ep.path,
      o.issue(binding(provider = "sensor_module", contract = iface)),
      module = "sensor_module",
      selected = selected,
    )
    check o.waitN(evConnected, 1, start = start).len == 1
    o.call(1, 1, "schema")
    let r = o.response(1, 1)
    check r.isSome and r.get.outcome.ok
    check r.get.outcome.result == selected.schema
    check r.get.outcome.result !=
      encodeCbor(schemaResponse(sensor, sensor.primary.root).get)
    check o.events(evDispatch).len == 0
    o.done(ep)

  test "[TRN-0151] [TRN-0158] [CAP-0253] a method outside the route's access is NOT_AUTHORISED, without dispatch":
    let (o, ep) = served()
    let access = RouteAccess(methods: Opt.some(@[storageSet.rootOf("storage.exists")]))
    let callee = o.attach(ep, 1, binding(access = access))
    o.call(1, 1, "space")
    check o.response(1, 1).code == ecNotAuthorised
    o.call(1, 2, "schema")
    check o.response(1, 2).code == ecNotAuthorised
    o.callExists(1, 3)
    check o.response(1, 3).code == ecOk
    check o.events(evDispatch, callee).len == 1
    o.done(ep)

suite "trnio.events: subscriptions and Events over sockets (TRANSPORT §5.1, §5.2, §6)":
  test "[TRN-0106] [TRN-0121] subscribe, publish and unsubscribe":
    let (o, ep) = served()
    let callee = o.attach(ep, 1)
    o.subscribe(1, 7, Started)
    let s = o.waitN(evSubscription, 1)
    check s.len == 1 and s[0].subscriptionId == 7 and s[0].subscriptionFailure.isNone
    check o.events(evSubscribe, callee).mapIt(it.subscribeEvent) == @[Started]
    o.publish(1, Started, cborMap())
    let e = o.waitN(evEvent, 1)
    check e.len == 1 and e[0].eventSub == 7 and e[0].eventName == Started
    check e.len == 1 and e[0].eventData == encodeCbor(cborMap())
    o.unsubscribe(1, 7)
    let u = o.waitN(evSubscription, 1, 2)
    check u.len == 2 and u[1].subscriptionOp == mkUnsubscribe
    check o.events(evUnsubscribe, callee).len == 1
    o.publish(1, Started, cborMap())
    o.settle(100)
    check o.events(evEvent, 1).len == 1
    o.done(ep)

  peerTest "[TRN-0106] [TRN-0121] Events cross processes":
    let ep = newEndpoint()
    var p = spawnPeer(peerProgram(), ["owner", "serve"], ep.listener)
    let t = p.childTicket()
    let o = newOwner()
    o.connect(1, ep.path, t)
    check o.oneOf(1).map(
      proc(e: IoEvent): IoEventKind =
        e.kind
    ) == Opt.some(evConnected)
    o.subscribe(1, 1, Started)
    check o.waitN(evSubscription, 1).len == 1
    discard p.ask(op("publish", ("event", cbor(Started)), ("data", cborMap())), o)
    let e = o.waitN(evEvent, 1)
    check e.len == 1 and e[0].eventName == Started
    check p.childEvents().countIt(it.text("kind") == "evSubscribe") == 1
    o.stop()
    check p.finish() == 0
    check removeEndpoint(ep).isOk

  test "[TRN-0158] the route's subscription and publication scopes":
    let (o, ep) = served()
    let access = RouteAccess(
      subscribeEvents:
        Opt.some(@[storageSet.rootOf(Started), storageSet.rootOf(Progress)]),
      publishEvents: Opt.some(@[storageSet.rootOf(Progress)]),
    )
    let callee = o.attach(ep, 1, binding(access = access))
    o.subscribe(1, 1, Done)
    let denied = o.waitN(evSubscription, 1)
    check denied.len == 1 and denied[0].subscriptionFailure.get.code == ecNotAuthorised
    check o.events(evSubscribe, callee).len == 0
    o.subscribe(1, 2, Started)
    o.subscribe(1, 3, Progress)
    check o.waitN(evSubscription, 1, 3).len == 3
    # Started may be subscribed to, but not published.
    o.publish(1, Started, cborMap())
    let f = o.waitN(evPublishFailed, callee)
    check f.len == 1 and f[0].pubFailKind == peNotInContract
    check f.len == 1 and f[0].pubFailCode == ecNotAuthorised
    o.publish(1, Progress, progress(1))
    let e = o.waitN(evEvent, 1)
    check e.len == 1 and e[0].eventName == Progress
    o.done(ep)

  test "[TRN-0121] [TRN-0122] [TRN-0267] buffered Events arrive in order, none lost while open":
    let (o, ep) = served()
    discard o.attach(ep, 1)
    o.subscribe(1, 1, Progress)
    check o.waitN(evSubscription, 1).len == 1
    for i in 0'u64 ..< 300:
      o.publish(1, Progress, progress(i))
    let es = o.waitN(evEvent, 1, 300)
    check es.len == 300
    check es.mapIt(decodeValue(it.eventData).get) ==
      toSeq(0'u64 ..< 300'u64).mapIt(progress(it))
    o.done(ep)

  test "[TRN-0123] [TRN-0125] output overflow: ProtocolError TRANSPORT_ERROR and close; the caller's subscriptions end":
    var cfg = fastConfig()
    cfg.connOutputBytes = int(MinFrameLimit) + 64 * 1024 + 4
    cfg.callerUndeliveredBytes = int(MinFrameLimit)
    cfg.closeLinger = 5000 * Ms * Slow
    cfg.writeStallTimeout = 10_000 * Ms * Slow
    let (o, ep) = served(cfg)
    let callee = o.attach(ep, 1)
    o.subscribe(1, 1, Progress)
    check o.waitN(evSubscription, 1).len == 1
    o.autoRelease = false # the caller stops reading at 16 MiB
    let big = "x".repeat(4 * MiB)
    for i in 0'u64 ..< 12:
      o.publish(1, Progress, progress(i, big))
    let closed = o.waitN(evClosed, callee, timeoutMs = BigWait)
    check closed.len == 1 and closed[0].cause == ccOverflow
    check closed.len == 1 and closed[0].code == ecTransport
    # The caller reads on: the committed Events in order, then the ProtocolError.
    o.autoRelease = true
    var credit = 0
    for e in o.events(evEvent, 1):
      credit += e.credit
    o.release(1, credit)
    let cc = o.waitN(evClosed, 1, timeoutMs = BigWait)
    check cc.len == 1 and cc[0].cause == ccPeerError and cc[0].code == ecTransport
    let es = o.events(evEvent, 1)
    check es.len < 12
    for i, e in es:
      check decodeValue(e.eventData).get.field("bytes_sent") == cbor(uint64(i))
    o.done(ep)

  test "[TRN-0126] a caller that stops reading is closed at the write stall, without ProtocolError":
    var cfg = fastConfig()
    cfg.writeStallTimeout = 300 * Ms
    let (o, ep) = served(cfg)
    var raw = o.rawSession(ep)
    raw.put(raw.caller.subscribe(1, Progress).get)
    check o.waitN(evSubscribe, high(uint64)).len == 1
    o.settle(20)
    # Far more than the socket's send buffer (no SO_SNDBUF is set).
    o.publish(1, Progress, progress(0, "x".repeat(2 * MiB)))
    let closed = o.waitN(evClosed, high(uint64), timeoutMs = BigWait)
    check closed.len == 1 and closed[0].cause == ccNotWritable
    discard fdClose(raw.fd)
    o.done(ep)

  test "[TRN-0124] submit is sbBusy at maxPendingOutputBytes; submitWait waits until the I/O thread takes it":
    var cfg = fastConfig()
    cfg.maxPendingOutputBytes = MiB
    let o = newOwner(cfg)
    let data = progress(0, "x".repeat(600_000))
    o.closeGate()
    o.callExists(99, 1) # an event: the I/O thread now waits in the sink
    check pumpUntil(
      [o],
      proc(): bool =
        o.atGate(),
    )
    check o.loop.submit(publishCmd(9, Progress, data)) == sbOk
    check o.loop.submit(publishCmd(9, Progress, data)) == sbBusy
    check o.loop.submitWait(publishCmd(9, Progress, data), Opt.some(50 * Ms)) == sbBusy
    var opener: Thread[ptr Atomic[bool]]
    createThread(opener, openLater, o.gate)
    check o.loop.submitWait(publishCmd(9, Progress, data)) == sbOk
    joinThread(opener)
    # Never on a thread the I/O thread's events wait for.
    registerOwnerThread(o.loop)
    check o.loop.submitWait(publishCmd(9, Progress, data)) == sbRefused
    unregisterOwnerThread()
    o.stop()

  test "[TRN-0313] scoped publication stops at the terminal Response and at Cancel":
    let (o, ep) = served()
    o.respond = false
    let callee = o.attach(ep, 1)
    o.subscribe(1, 1, Progress)
    check o.waitN(evSubscription, 1).len == 1
    o.callExists(1, 1)
    let a = o.waitN(evDispatch, callee)[0].requestId
    o.publishScoped(callee, a, Progress, progress(1))
    check o.waitN(evEvent, 1).len == 1
    o.respondTo(callee, a)
    check o.response(1, 1).code == ecOk
    o.publishScoped(callee, a, Progress, progress(2))
    let f = o.waitN(evPublishFailed, callee)
    check f.len == 1 and f[0].pubFailKind == peNoDestination
    check f.len == 1 and f[0].pubFailRequest == Opt.some(a)
    o.callExists(1, 2)
    let b = o.waitN(evDispatch, callee, 2)[1].requestId
    o.cancel(1, 2)
    check o.response(1, 2).code == ecCancelled
    o.settle(20)
    o.publishScoped(callee, b, Progress, progress(3))
    check o.waitN(evPublishFailed, callee, 2).len == 2
    check o.events(evEvent, 1).len == 1
    o.done(ep)

  test "[TRN-0265] [TRN-0266] [IMPL-DECISION G165] an oversized Event is never committed: tlReport keeps the connection, tlClose closes":
    let (o, ep) = served()
    let callee = o.attach(ep, 1)
    o.subscribe(1, 1, Progress)
    check o.waitN(evSubscription, 1).len == 1
    let huge = progress(0, "x".repeat(int(MinFrameLimit)))
    o.publish(1, Progress, huge, tlReport)
    let f = o.waitN(evPublishFailed, callee, timeoutMs = BigWait)
    check f.len == 1 and f[0].pubFailKind == peTooLarge and f[0].pubFailCode == ecModule
    o.callExists(1, 1)
    check o.response(1, 1, BigWait).code == ecOk
    o.publish(1, Progress, huge, tlClose)
    let closed = o.waitN(evClosed, callee, timeoutMs = BigWait)
    check closed.len == 1 and closed[0].cause == ccProtocol
    check closed.len == 1 and closed[0].code == ecTransport
    check o.events(evEvent, 1).len == 0
    o.done(ep)

  test "caller credits: reading pauses at callerUndeliveredBytes and resumes on release":
    var cfg = fastConfig()
    cfg.callerUndeliveredBytes = int(MinFrameLimit)
    # One I/O thread serves both ends: hashing a 4 MiB Event in a debug or
    # sanitizer build must not count as the peer's write stall.
    cfg.writeStallTimeout = 10_000 * Ms * Slow
    let (o, ep) = served(cfg)
    discard o.attach(ep, 1)
    o.subscribe(1, 1, Progress)
    check o.waitN(evSubscription, 1).len == 1
    o.autoRelease = false
    # Reading pauses after the Event that brings the undelivered bytes to the
    # limit [IMPL]: the 4th of these. The last two are small, so they would
    # arrive at once if reading went on.
    let big = "x".repeat(4 * MiB)
    for i in 0'u64 ..< 6:
      o.publish(1, Progress, progress(i, if i < 4: big else: "s"))
    # 16 MiB before the pause, four times what `BigWait` is sized for (a loaded
    # CI runner took up to 20 s per 4 MiB Event under msan).
    let first = o.waitN(evEvent, 1, 4, timeoutMs = 4 * BigWait)
    check first.len == 4
    var credit = 0
    for e in first:
      credit += e.credit
    if first.len == 4:
      check credit - first[3].credit < cfg.callerUndeliveredBytes
      check credit >= cfg.callerUndeliveredBytes
    o.settle(200 * Slow)
    check o.events(evEvent, 1).len == 4
    o.release(1, credit)
    let all = o.waitN(evEvent, 1, 6, timeoutMs = BigWait)
    check all.len == 6
    for i, e in all:
      check decodeValue(e.eventData).get.field("bytes_sent") == cbor(uint64(i))
    o.done(ep)

suite "trnio.termination: the session's end (TRANSPORT §8.1)":
  test "[TRN-0317] [TRN-0153] [TRN-0163] [CAP-0254] the session ends at endsIn: admission stops, subscriptions end, then ProtocolError NOT_AUTHORISED":
    var cfg = fastConfig()
    cfg.terminationDrain = 1500 * Ms
    let (o, ep) = served(cfg)
    o.respond = false
    o.endsIn = Opt.some(300 * Ms)
    let start = o.log.len
    let callee = o.attach(ep, 1, binding(decision = "decision-42"))
    check o.events(evEstablished, callee, start)[0].binding.decision == "decision-42"
    o.subscribe(1, 1, Started)
    check o.waitN(evSubscription, 1).len == 1
    o.callExists(1, 1)
    let a = o.waitN(evDispatch, callee)[0].requestId
    sleep(350)
    # Terminating: a new Request is refused without dispatch; no Event goes out.
    o.callExists(1, 2)
    check o.response(1, 2).code == ecNotAuthorised
    o.publish(1, Started, cborMap())
    # In-flight work may still finish during the drain.
    o.respondTo(callee, a)
    check o.response(1, 1).code == ecOk
    let closed = o.waitN(evClosed, callee, timeoutMs = 6000 * Slow)
    check closed.len == 1 and closed[0].cause == ccTerminated
    check closed.len == 1 and closed[0].code == ecNotAuthorised
    let cc = o.waitN(evClosed, 1)
    check cc.len == 1 and cc[0].cause == ccPeerError and cc[0].code == ecNotAuthorised
    check o.events(evEvent, 1).len == 0
    check o.events(evDispatch, callee).len == 1
    o.done(ep)

  test "[TRN-0384] [TRN-0321] revocation (cmdTerminate): queued Requests get NOT_AUTHORISED and are never dispatched, even when a slot frees":
    var cfg = fastConfig()
    cfg.maxInFlight = 1
    cfg.terminationDrain = 1500 * Ms
    let (o, ep) = served(cfg)
    o.respond = false
    let callee = o.attach(ep, 1)
    o.callExists(1, 1)
    let a = o.waitN(evDispatch, callee)[0].requestId
    o.callExists(1, 2)
    o.settle(50)
    o.terminate(callee)
    check o.response(1, 2).code == ecNotAuthorised
    o.respondTo(callee, a) # its work ends: a slot frees
    check o.response(1, 1).code == ecOk
    check o.waitN(evClosed, callee, timeoutMs = 6000 * Slow).len == 1
    check o.events(evDispatch, callee).len == 1
    o.done(ep)

  test "[TRN-0325] [TRN-0322] termination with a caller that reads nothing finishes within closeLinger":
    var cfg = fastConfig()
    cfg.writeStallTimeout = 10_000 * Ms * Slow
    let (o, ep) = served(cfg)
    var raw = o.rawSession(ep)
    raw.put(raw.caller.subscribe(1, Progress).get)
    check o.waitN(evSubscribe, high(uint64)).len == 1
    o.settle(20)
    # Far more than the socket's send buffer (no SO_SNDBUF is set).
    o.publish(1, Progress, progress(0, "x".repeat(2 * MiB)))
    # Unread Requests stay unread.
    for _ in 0 ..< 3:
      raw.put(raw.caller.request("exists", existsParams()).get[1])
    let callee = o.events(evSubscribe)[0].conn
    # Commands are handled in order: once call 1 on the unknown connection 99
    # fails, the Event is committed, and the clock starts.
    o.callExists(99, 1)
    check o.waitN(evLocalFailure, 99, timeoutMs = BigWait).len == 1
    let start = getMonoTime()
    o.terminate(callee)
    let closed = o.waitN(evClosed, callee)
    check closed.len == 1 and closed[0].cause == ccTerminated
    # The fd closes once closeLinger passed, the flush unfinished.
    sleep(300)
    let (_, ended) = readUntilEnd(raw.fd, o, 3000 * Slow)
    check ended
    check (getMonoTime() - start).inMilliseconds < 5000 * Slow
    discard fdClose(raw.fd)
    o.done(ep)

suite "trnio.limits: aggregate limits (TRANSPORT §8.6)":
  test "[TRN-0378] [TRN-0379] [TRN-0381] a frame that finds no room in maxInputBytes waits, then closes at admissionTimeout":
    var cfg = fastConfig()
    cfg.maxInputBytes = 24 * MiB
    let (o, ep) = served(cfg)
    var a = o.rawSession(ep)
    var b = o.rawSession(ep)
    check writeAll(a.fd, @(prefixOf(int(MinFrameLimit))) & newSeq[byte](1000))
    o.settle(50)
    check writeAll(b.fd, @(prefixOf(int(MinFrameLimit))) & newSeq[byte](1000))
    let ms = b.readMsgs(o, 1, 3000)
    check ms.len == 1 and ms[0].kind == mkProtocolError
    check ms.len == 1 and ms[0].protocolError.code == ecTransport
    discard fdClose(a.fd)
    discard fdClose(b.fd)
    o.done(ep)

  test "[TRN-0378] maxOutbound: local MODULE_ERROR, nothing opened":
    var cfg = fastConfig()
    cfg.maxOutbound = 1
    let (o, ep) = served(cfg)
    discard o.attach(ep, 1)
    o.connect(2, ep.path, o.issue())
    let f = o.oneOf(2)
    check f.isSome and f.get.kind == evConnectFailed
    check f.get.failCode == ecModule and f.get.failCause == cfCapacity
    o.done(ep)

  test "[TRN-0378] [TRN-0379] maxTotalCalls: local MODULE_ERROR":
    var cfg = fastConfig()
    cfg.maxTotalCalls = 2
    let (o, ep) = served(cfg)
    o.respond = false
    discard o.attach(ep, 1)
    discard o.attach(ep, 2)
    o.callExists(1, 1)
    o.callExists(2, 1)
    o.callExists(2, 2)
    let f = o.waitN(evLocalFailure, 2)
    check f.len == 1 and f[0].localTag == 2 and f[0].localCode == ecModule
    o.done(ep)

  test "[TRN-0378] [TRN-0379] maxTotalSubscriptions: subscription-result-err MODULE_ERROR":
    var cfg = fastConfig()
    cfg.maxTotalSubscriptions = 1
    let (o, ep) = served(cfg)
    discard o.attach(ep, 1)
    discard o.attach(ep, 2)
    o.subscribe(1, 1, Started)
    check o.waitN(evSubscription, 1)[0].subscriptionFailure.isNone
    o.subscribe(2, 1, Started)
    let s = o.waitN(evSubscription, 2)
    check s.len == 1 and s[0].subscriptionFailure.get.code == ecModule
    o.done(ep)

  test "[TRN-0378] [TRN-0379] maxTotalSubscriptionIds: the callee closes; the caller fails locally":
    var cfg = fastConfig()
    cfg.maxTotalSubscriptionIds = 1
    let (o, ep) = served(cfg)
    var raw = o.rawSession(ep)
    raw.put(raw.caller.subscribe(1, Started).get)
    check o.waitN(evSubscribe, high(uint64)).len == 1
    raw.put(raw.caller.subscribe(2, Started).get)
    let closed = o.waitN(evClosed, high(uint64))
    check closed.len == 1 and closed[0].code == ecTransport
    discard fdClose(raw.fd)
    o.done(ep)
    # The caller side, on its own loop.
    let (a, ep2) = served()
    let b = newOwner(cfg)
    discard a.attach(ep2, 1, caller = b)
    b.subscribe(1, 1, Started)
    check b.waitN(evSubscription, 1, others = @[a]).len == 1
    b.subscribe(1, 2, Started)
    let f = b.waitN(evLocalFailure, 1, others = @[a])
    check f.len == 1 and f[0].localTag == 2 and f[0].localCode == ecModule
    b.stop()
    a.done(ep2)

  test "[TRN-0378] every limit is finite and positive, and the pools hold a maximal frame":
    check defaultTransportConfig().validate().isOk
    for edit in [
      proc(c: var TransportConfig) =
        c.maxTotalExecuting = 0,
      proc(c: var TransportConfig) =
        c.maxTotalCalls = 0,
      proc(c: var TransportConfig) =
        c.maxTotalSubscriptions = 0,
      proc(c: var TransportConfig) =
        c.maxTotalSubscriptionIds = 0,
      proc(c: var TransportConfig) =
        c.maxPendingOutputBytes = 0,
      proc(c: var TransportConfig) =
        c.maxDelayedRequests = 0,
      proc(c: var TransportConfig) =
        c.maxPastCapFrames = 0,
      proc(c: var TransportConfig) =
        c.maxDelayedBytes = MiB,
      proc(c: var TransportConfig) =
        c.callerUndeliveredBytes = MiB,
      proc(c: var TransportConfig) =
        c.maxInputBytes = MiB,
      proc(c: var TransportConfig) =
        c.terminationDrain = -1,
      proc(c: var TransportConfig) =
        c.connOutputBytes = int(MinFrameLimit),
    ]:
      var c = defaultTransportConfig()
      edit(c)
      check c.validate().isErr

suite "trnio.hello: pipelined frames (TRANSPORT §2.3, §3.1)":
  test "[TRN-0273] [TRN-0274] [IMPL] a Hello and a Request in one write: the Request is dispatched after establishment (S10a-1)":
    let (o, ep) = served()
    let fd = rawConnect(ep.path)
    var caller = callerConn(storageBoundary)
    let req = frame(caller.request("exists", existsParams()).get[1]).get
    check writeAll(fd, helloBytes(o.issue()) & req)
    var raw = Raw(fd: fd, caller: caller, reader: newFrameReader())
    let ms = raw.readMsgs(o, 2)
    check ms.len == 2 and ms[0].kind == mkHello
    check ms.len == 2 and ms[1].kind == mkResponse and ms[1].response.ok
    let est = o.events(evEstablished)
    check est.len == 1 and o.events(evDispatch, est[0].conn).len == 1
    discard fdClose(fd)
    o.done(ep)

suite "trnio.thread: submitWait (TRANSPORT §5.2; F8)":
  test "submitWait refuses to run on the I/O thread":
    let probe = createShared(Probe)
    probe.loop = startTransport(fastConfig(), waitSink, probe).get
    discard probe.loop.submit(IoCommand(kind: cmdClose, conn: 1)) # no event
    discard
      probe.loop.submit(IoCommand(conn: 5, kind: cmdCall, tag: 1, methodName: "exists"))
    let deadline = getMonoTime() + initDuration(seconds = 5)
    while probe.res.load == 0 and getMonoTime() < deadline:
      sleep(1)
    probe.loop.stopTransport()
    check probe.res.load == ord(sbRefused) + 1
    deallocShared(probe)

proc sleepUntil(t: MonoTime) =
  let left = (t - getMonoTime()).inMilliseconds
  if left > 0:
    sleep(int(left))

suite "trnio.deadlines: a deadline that passes while the I/O thread is busy (TRANSPORT §8.6) [IMPL]":
  # The gate holds the I/O thread still across a deadline while the peer's
  # bytes, or the owner's answer, arrive in time. Without the verdict turn,
  # chronos runs the expired timer first and blames the peer.
  const T = 500 * Slow ## the deadline the test is about, in ms

  test "[TRN-0378] [G61] caller: a Hello response that arrived in time counts":
    let ep = newEndpoint()
    let callee = newOwner()
    callee.admit = amIgnore
    check callee.serve(1, dupCloexec(ep.listener))
    var cfg = fastConfig()
    cfg.helloTimeout = T * Ms
    let o = newOwner(cfg)
    let start = getMonoTime()
    o.connect(1, ep.path, callee.issue())
    let hello = callee.expectKind(evHello)
    let armed = getMonoTime() # the caller's deadline was armed before this
    o.closeGate()
    o.callExists(99, 1) # an event: the I/O thread now waits in the sink
    check pumpUntil(
      [o],
      proc(): bool =
        o.atGate(),
    )
    check hello.isSome
    if hello.isSome:
      callee.admitHello(hello.get)
    check callee.expectKind(evEstablished).isSome
    # The response is in the caller's socket before its deadline.
    check (getMonoTime() - start).inMilliseconds < T
    sleepUntil(armed + initDuration(milliseconds = T + 100))
    o.openGate()
    let r = o.oneOf(1)
    check r.isSome and r.get.kind == evConnected
    o.stop()
    callee.done(ep)

  test "[TRN-0378] [G61] callee: an admission the owner queued in time counts":
    var cfg = fastConfig()
    cfg.helloTimeout = T * Ms
    let ep = newEndpoint()
    let o = newOwner(cfg)
    o.admit = amIgnore
    check o.serve(1, dupCloexec(ep.listener))
    let start = getMonoTime()
    var raw = Raw(
      fd: rawConnect(ep.path),
      caller: callerConn(storageBoundary),
      reader: newFrameReader(),
    )
    check writeAll(raw.fd, helloBytes(o.issue()))
    let hello = o.expectKind(evHello)
    let armed = getMonoTime() # the callee's deadline was armed before this
    # Held inside a socket callback: the owner's answer waits in the channel.
    o.closeGate()
    let other = rawConnect(ep.path)
    check writeAll(other, helloBytes(o.issue()))
    check pumpUntil(
      [o],
      proc(): bool =
        o.atGate(),
    )
    check hello.isSome
    if hello.isSome:
      o.admitHello(hello.get)
    check (getMonoTime() - start).inMilliseconds < T
    sleepUntil(armed + initDuration(milliseconds = T + 100))
    o.openGate()
    let ms = raw.readMsgs(o, 1)
    check ms.len == 1 and ms[0].kind == mkHello
    check o.expectKind(evEstablished).isSome
    discard fdClose(other)
    discard fdClose(raw.fd)
    o.done(ep)

  test "[TRN-0378] [TRN-0381] a frame's wait ends with room another connection freed in time":
    var cfg = fastConfig()
    cfg.maxInputBytes = 24 * MiB
    cfg.admissionTimeout = T * Ms
    let (o, ep) = served(cfg)
    var a = o.rawSession(ep)
    var b = o.rawSession(ep)
    # a holds 9 MiB being read; b's 16 MiB do not fit beside them.
    let held = 9 * MiB
    check writeAll(a.fd, @(prefixOf(held)) & newSeq[byte](held - 10))
    o.settle(50)
    let start = getMonoTime()
    check writeAll(b.fd, @(prefixOf(int(MinFrameLimit))) & newSeq[byte](1000))
    o.settle(50)
    let armed = getMonoTime() # b's wait began before this
    o.closeGate()
    let other = rawConnect(ep.path)
    check writeAll(other, helloBytes(o.issue()))
    check pumpUntil(
      [o],
      proc(): bool =
        o.atGate(),
    )
    # a's frame ends (its reservation is released when it is handled).
    check writeAll(a.fd, newSeq[byte](10))
    check (getMonoTime() - start).inMilliseconds < T
    sleepUntil(armed + initDuration(milliseconds = T + 100))
    o.openGate()
    # b was admitted: it waits for the rest of its frame, nothing is sent to it.
    let ms = b.readMsgs(o, 1, 500)
    check ms.len == 0
    discard fdClose(other)
    discard fdClose(a.fd)
    discard fdClose(b.fd)
    o.done(ep)

removeDir(base)
