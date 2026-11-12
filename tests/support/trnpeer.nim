## The child-process peer of `test_transport_io` (TRANSPORT §8.2 needs a second
## process: in one process every peer check passes trivially). Built by
## `peerbuild.nim` under the suite's memory manager and sanitizer.
##
## Modes:
## - `owner [serve]`: a transport loop with `trnowner`; with `serve` it serves
##   the inherited listener on fd 4. Commands arrive on the control channel
##   (fd 3): issue, live, admit, events, connect, call, publish, exit.
## - `raw`: accepts one connection on fd 4 with plain syscalls, reads until
##   end of input, and reports how many bytes arrived.
## - `squat <base>`: binds its own listener in a fresh 0755 directory under
##   `<base>`, reports `ready <path>` and then `bytes <n>` on stdout (sudo closes
##   every fd above 2, so no control channel), then removes what it created.
##   G129's other-uid listener.

import std/[os, posix, strutils]
import results
import ../../src/logos_core/cbor
import ../../src/logos_core/transport/io/sock
import ./[ctl, trnowner]

const Ctl = 3.cint
const Inherited = 4.cint

proc reply(v: CborValue) =
  doAssert ctlSend(Ctl, v)

proc summary(ev: IoEvent): CborValue =
  var e = @[(cbor("kind"), cbor($ev.kind)), (cbor("conn"), cbor(ev.conn))]
  proc cred(p: PeerCred): seq[(CborValue, CborValue)] =
    @[(cbor("uid"), cbor(uint64(p.uid))), (cbor("pid"), cbor(int64(p.pid.get(-1))))]

  case ev.kind
  of evEstablished:
    if ev.peer.isSome:
      e.add(cred(ev.peer.get))
    e.add((cbor("consumer"), cbor(ev.binding.consumer)))
    e.add((cbor("route"), cbor(ev.binding.route)))
  of evConnected:
    e.add(cred(ev.connectedPeer))
  of evConnectFailed:
    e.add((cbor("code"), cbor(uint64(ord(ev.failCode)))))
    e.add((cbor("cause"), cbor($ev.failCause)))
    e.add((cbor("msg"), cbor(ev.failMsg)))
  of evClosed:
    e.add((cbor("code"), cbor(uint64(ord(ev.code)))))
    e.add((cbor("cause"), cbor($ev.cause)))
  of evResponse:
    e.add((cbor("ok"), cbor(ev.outcome.ok)))
    if not ev.outcome.ok:
      e.add((cbor("code"), cbor(uint64(ord(ev.outcome.failure.code)))))
  of evLocalFailure:
    e.add((cbor("code"), cbor(uint64(ord(ev.localCode)))))
  of evSubscribe, evUnsubscribe:
    e.add((cbor("sub"), cbor(ev.subscribeId)))
  of evPublishFailed:
    e.add((cbor("code"), cbor(uint64(ord(ev.pubFailCode)))))
  else:
    discard
  cborMap(e)

proc waitFor(o: Owner, kinds: set[IoEventKind], conn: ConnId): CborValue =
  let ev = o.expect(
    proc(ev: IoEvent): bool =
      ev.kind in kinds and ev.conn == conn,
    10_000,
  )
  if ev.isNone:
    return cborMap((cbor("kind"), cbor("timeout")))
  summary(ev.get)

proc ownerMode(serve: bool) =
  let o = newOwner()
  if serve:
    doAssert o.serve(1, Inherited)
  while true:
    discard o.pump(5)
    if not waitReadable(Ctl, 0):
      continue
    let req = ctlRecv(Ctl).valueOr:
      o.stop()
      quit(1)
    case req.text("op")
    of "issue":
      let t = o.issue(
        binding(consumer = req.text("consumer"), endpoint = req.text("endpoint"))
      )
      reply(cborMap((cbor("ticket"), cbor(@t))))
    of "live":
      var t: RouteTicket
      let b = req.bytes("ticket")
      if b.len == t.len:
        copyMem(addr t[0], unsafeAddr b[0], t.len)
      reply(cborMap((cbor("live"), cbor(b.len == t.len and o.live(t)))))
    of "admit":
      o.admit = parseEnum[AdmitMode](req.text("mode"))
      reply(cborMap())
    of "events":
      discard o.pump(20)
      var all: seq[CborValue]
      for ev in o.log:
        all.add(summary(ev))
      reply(cborMap((cbor("events"), cborArray(all))))
    of "connect":
      var t: RouteTicket
      let b = req.bytes("ticket")
      doAssert b.len == t.len
      copyMem(addr t[0], unsafeAddr b[0], t.len)
      o.connect(1, req.text("path"), t, uint32(req.num("uid")))
      zeroMem(addr t[0], t.len)
      reply(o.waitFor({evConnected, evConnectFailed}, 1))
    of "call":
      o.callExists(1, req.num("tag"))
      reply(o.waitFor({evResponse, evLocalFailure}, 1))
    of "publish":
      # On the served endpoint: every subscriber gets the Event.
      o.publish(1, req.text("event"), req.field("data"))
      discard o.pump(20)
      reply(cborMap())
    of "exit":
      o.stop()
      reply(cborMap((cbor("ok"), cbor(true))))
      quit(0)
    else:
      reply(cborMap((cbor("error"), cbor("unknown op"))))

proc drainCount(fd: cint, timeoutMs: int): int =
  ## Bytes read until end of input (or the deadline).
  var buf: array[4096, byte]
  var waited = 0
  while waited < timeoutMs:
    if not waitReadable(fd, 50):
      waited += 50
      continue
    let n = posix.read(fd, addr buf[0], buf.len)
    if n <= 0:
      break
    result += n

proc acceptOne(listener: cint, timeoutMs: int): cint =
  discard setNonblock(listener)
  if not waitReadable(listener, timeoutMs):
    return -1
  sockAccept(listener)

proc rawMode() =
  let fd = acceptOne(Inherited, 10_000)
  var n = -1
  if fd >= 0:
    var flags = fcntl(fd, F_GETFL)
    discard fcntl(fd, F_SETFL, flags and not O_NONBLOCK)
    n = drainCount(fd, 5_000)
    discard fdClose(fd)
  reply(cborMap((cbor("bytes"), cbor(int64(n)))))
  discard ctlRecv(Ctl)
  quit(0)

proc squatMode(base: string) =
  var t: array[4, byte]
  doAssert osRandom(t)
  let dir = base / ("lcnsquat-" & toHex(t[0]) & toHex(t[1]) & toHex(t[2]) & toHex(t[3]))
  doAssert mkdir(cstring(dir), 0o755) == 0
  doAssert chmod(cstring(dir), 0o755) == 0
  let path = dir / "logos_storage_module.sock"
  let fd = unixSocket()
  doAssert fd >= 0
  doAssert sockBind(fd, cstring(path)) == 0
  # The test user must be able to connect: the peer check is under test, not
  # the file mode.
  doAssert chmod(cstring(path), 0o666) == 0
  doAssert sockListen(fd, 4) == 0
  stdout.writeLine("ready " & path)
  stdout.flushFile()
  let c = acceptOne(fd, 10_000)
  var n = -1
  if c >= 0:
    n = drainCount(c, 5_000)
    discard fdClose(c)
  stdout.writeLine("bytes " & $n)
  stdout.flushFile()
  discard fdClose(fd)
  discard unlink(cstring(path))
  discard rmdir(cstring(dir))
  quit(0)

when isMainModule:
  let args = commandLineParams()
  doAssert args.len >= 1, "trnpeer <owner [serve]|raw|squat <base>>"
  case args[0]
  of "owner":
    ownerMode(args.len > 1 and args[1] == "serve")
  of "raw":
    rawMode()
  of "squat":
    squatMode(args[1])
  else:
    quit(2)
