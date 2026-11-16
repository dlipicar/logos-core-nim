## Step 5-4 (G107), Q11: can chronos 4.4.1's Windows dispatcher drive AF_UNIX
## streams through its public API only, with no fork? Four variants:
##   (a) overlapped WSARecv/WSASend/AcceptEx (and ConnectEx) completions;
##   (b) a zero-byte WSARecv/WSASend as a readiness signal;
##   (c) WSAEventSelect on an auto-reset event, waited with registerWaitable;
##   (d) IOCTL_AFD_POLL on the AFD device, completed on chronos's port (wepoll's way).
## Prints `fact loop:<name> <value>` lines. Windows only.
##
##   nim c -d:release --threads:on --path:<chronos> --path:<results> --path:<stew> \
##     loopprobe.nim && loopprobe.exe <short dir for socket files>

when not defined(windows):
  {.error: "loopprobe is Windows only".}

{.compile: "loopprobe.c".}
{.passl: "-lws2_32".}

import std/[os, strutils, tables]
import chronos/[asyncloop, threadsync, osdefs]

proc lp_init(): cint {.importc, cdecl.}
proc lp_socket(): uint {.importc, cdecl.}
proc lp_bind_listen(s: uint, p: cstring, backlog: cint): cint {.importc, cdecl.}
proc lp_bind(s: uint, p: cstring): cint {.importc, cdecl.}
proc lp_connect(s: uint, p: cstring): cint {.importc, cdecl.}
proc lp_accept(l: uint): uint {.importc, cdecl.}
proc lp_nonblock(s: uint, on: cint): cint {.importc, cdecl.}
proc lp_close(s: uint): cint {.importc, cdecl.}
proc lp_shutdown_send(s: uint): cint {.importc, cdecl.}
proc lp_recv(s: uint, b: pointer, n: cint): clong {.importc, cdecl.}
proc lp_send(s: uint, b: pointer, n: cint): clong {.importc, cdecl.}
proc lp_peerpid(s: uint): culong {.importc, cdecl.}
proc lp_writable(s: uint, ms: cint): cint {.importc, cdecl.}
proc lp_wsarecv(s: uint, b: pointer, n: culong, ovl: pointer): cint {.importc, cdecl.}
proc lp_wsasend(s: uint, b: pointer, n: culong, ovl: pointer): cint {.importc, cdecl.}
proc lp_acceptex(l, a: uint, buf, ovl: pointer): cint {.importc, cdecl.}
proc lp_update_accept(a, l: uint): cint {.importc, cdecl.}
proc lp_connectex(
  s: uint, p: cstring, ovl: pointer, stage: ptr cint
): cint {.importc, cdecl.}

proc lp_event(): pointer {.importc, cdecl.}
proc lp_eventselect(s: uint, ev: pointer, mask: clong): cint {.importc, cdecl.}
proc lp_enum_events(s: uint, ev: pointer, errs: ptr cint): clong {.importc, cdecl.}
proc lp_afd_open(err: ptr cint): pointer {.importc, cdecl.}
proc lp_base_handle(s: uint, err: ptr cint): uint {.importc, cdecl.}
proc lp_afd_poll(
  afd: pointer, base: uint, events: culong, info, ovl: pointer
): cint {.importc, cdecl.}

proc lp_afd_events(info: pointer): culong {.importc, cdecl.}
proc lp_lasterr(): cint {.importc, cdecl.}
proc lp_inherit(h: uint, on: cint): cint {.importc, cdecl.}
proc lp_spawn(cmd: cstring): pointer {.importc, cdecl.}
proc lp_wait(p: pointer, ms: cint): clong {.importc, cdecl.}
proc lp_cancel(h, ovl: pointer): cint {.importc, cdecl.}
proc GetCurrentProcessId(): uint32 {.importc, stdcall, dynlib: "kernel32".}

const
  WouldBlock = 10035
  BadSock = high(uint)
  FdRead = 1
  FdWrite = 2
  FdAccept = 8
  FdConnect = 16
  FdClose = 32
  AfdReceive = 0x1'u32
  AfdSend = 0x4'u32
  AfdDisconnect = 0x8'u32
  AfdAbort = 0x10'u32
  AfdLocalClose = 0x20'u32
  AfdAccept = 0x80'u32
  OkCode = -1 # chronos's poll() sets errCode to OSErrorCode(-1) on success

var dir: string
var seqNo = 0

proc fact(name: string, value: auto) =
  echo "fact loop:", name, " ", value
  flushFile(stdout)

proc sockPath(tag: string): string =
  inc seqNo
  result = dir / ("l" & $seqNo & tag & ".s")
  discard tryRemoveFile(result)

# ------------------------------------------------------------------ loop helpers

var gDeadline = false

proc onDeadline(arg: pointer) {.gcsafe, raises: [].} =
  gDeadline = true

proc runUntil(cond: proc(): bool, ms: int): bool =
  ## Polls chronos until `cond` holds or `ms` pass; a timer bounds each wait.
  gDeadline = false
  let t = setTimer(Moment.fromNow(milliseconds(ms)), onDeadline, nil)
  while not cond() and not gDeadline:
    poll()
  clearTimer(t)
  cond()

proc spin(ms: int) =
  discard runUntil(
    proc(): bool =
      false,
    ms,
  )

proc msSince(t: Moment): int64 =
  (Moment.now() - t).milliseconds

type
  Op = object of CustomOverlapped
    fired: bool
    err: int
    bytes: int
    owner: pointer
    info: array[8, uint64] # AFD_POLL_INFO for one handle, 8-byte aligned

  OpRef = ref Op

var gOps: seq[OpRef] # every Op stays alive until exit
var gObjs: seq[RootRef] # and so does every echo state and peer

proc onOp(arg: pointer) {.gcsafe, raises: [].} =
  let op = cast[ptr Op](arg)
  op.fired = true
  op.err = int(op.data.errCode)
  op.bytes = int(op.data.bytesCount)

proc newOp(cb: CallbackFunc = onOp): OpRef =
  result = OpRef()
  result.data.cb = cb
  gOps.add result

proc rearm(op: OpRef) =
  op.internal = nil
  op.internalHigh = nil
  op.offset = 0
  op.offsetHigh = 0
  op.hEvent = HANDLE(0)
  op.fired = false
  op.err = 0
  op.bytes = 0

proc errText(code: int): string =
  if code == OkCode:
    "ok"
  else:
    "err=" & $code

proc orTimeout(got: bool, what: string): string =
  if got: what else: "timeout"

proc evs(op: OpRef): string =
  errText(op.err) & " events=0x" & toHex(lp_afd_events(op.info[0].addr), 2)

proc reg(s: uint): string =
  let r = register2(AsyncFD(int(s)))
  if r.isOk:
    "ok"
  else:
    "err=" & $int(r.error)

type Pair = tuple[l, a, c: uint, path: string, err: string]

proc mkPair(tag: string): Pair =
  ## A listener, its accepted socket `a` and the client `c`, all blocking.
  result.path = sockPath(tag)
  result.l = lp_socket()
  var r = lp_bind_listen(result.l, result.path.cstring, 64)
  if r != 0:
    result.err = "listen " & $r
    return
  result.c = lp_socket()
  discard lp_nonblock(result.c, 1)
  r = lp_connect(result.c, result.path.cstring)
  if r != 0 and r != WouldBlock:
    result.err = "connect " & $r
    return
  result.a = lp_accept(result.l)
  if result.a == BadSock:
    result.err = "accept"
    return
  if lp_writable(result.c, 3000) != 1:
    result.err = "client not writable"
    return
  discard lp_nonblock(result.c, 0)

proc payload(n: int, seed: int): seq[byte] =
  result = newSeq[byte](n)
  var x = uint32((seed * 7919 + 1) and 0x7fffffff)
  for i in 0 ..< n:
    x = x xor (x shl 13)
    x = x xor (x shr 17)
    x = x xor (x shl 5)
    result[i] = byte(x and 0xff)

# --------------------------------------------- the cross-thread wake-up check

var gSig: ThreadSignalPtr
var gSigSeen = 0

proc onSig(arg: pointer) {.gcsafe, raises: [].} =
  inc gSigSeen
  gSig.wait().addCallback(onSig)

proc firer(sig: ThreadSignalPtr) {.thread.} =
  for i in 0 ..< 200:
    discard sig.fireSync()
    sleep(1)

var gFirer: Thread[ThreadSignalPtr]

proc startSignals() =
  if gSig == nil:
    gSig = ThreadSignalPtr.new().expect("signal")
    gSig.wait().addCallback(onSig)
  gSigSeen = 0
  createThread(gFirer, firer, gSig)

proc endSignals(prefix: string) =
  joinThread(gFirer)
  let before = gSigSeen
  discard gSig.fireSync()
  let seen = runUntil(
    proc(): bool =
      gSigSeen > before,
    3000,
  )
  fact(prefix & ".signal_fired", 200)
  fact(prefix & ".signal_seen", before)
  fact(prefix & ".signal_final_seen", seen)

# ------------------------------------------------- (a) overlapped completions

type EchoA = ref object of RootObj
  srv, cli: uint
  want: seq[byte]
  sbuf: seq[byte]
  back: seq[byte]
  cliGot, cliSent: int
  srvEof, cliEof: bool
  err: string
  srvRecv, srvSend, cliRecv, cliSend: OpRef

proc onEchoA(arg: pointer) {.gcsafe, raises: [].}

proc postSrvRecv(e: EchoA) =
  e.srvRecv.rearm()
  let r =
    lp_wsarecv(e.srv, e.sbuf[0].addr, culong(e.sbuf.len), cast[pointer](e.srvRecv))
  if r != 0:
    e.err = "srv WSARecv " & $r

proc postCliRecv(e: EchoA) =
  e.cliRecv.rearm()
  let room = min(e.back.len - e.cliGot, 1 shl 20)
  let r =
    lp_wsarecv(e.cli, e.back[e.cliGot].addr, culong(room), cast[pointer](e.cliRecv))
  if r != 0:
    e.err = "cli WSARecv " & $r

proc postCliSend(e: EchoA) =
  e.cliSend.rearm()
  let n = min(e.want.len - e.cliSent, 1 shl 20)
  let r = lp_wsasend(e.cli, e.want[e.cliSent].addr, culong(n), cast[pointer](e.cliSend))
  if r != 0:
    e.err = "cli WSASend " & $r

proc onEchoA(arg: pointer) {.gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    let op = cast[ptr Op](arg)
    let e = cast[EchoA](op.owner)
    let code = int(op.data.errCode)
    let n = int(op.data.bytesCount)
    if code != OkCode:
      e.err = "completion " & $code
      return
    if op == cast[ptr Op](e.srvRecv):
      if n == 0:
        e.srvEof = true
        discard lp_shutdown_send(e.srv)
      else:
        e.srvSend.rearm()
        let r = lp_wsasend(e.srv, e.sbuf[0].addr, culong(n), cast[pointer](e.srvSend))
        if r != 0:
          e.err = "srv WSASend " & $r
    elif op == cast[ptr Op](e.srvSend):
      e.postSrvRecv()
    elif op == cast[ptr Op](e.cliSend):
      e.cliSent += n
      if e.cliSent < e.want.len:
        e.postCliSend()
      else:
        discard lp_shutdown_send(e.cli)
    elif op == cast[ptr Op](e.cliRecv):
      if n == 0:
        e.cliEof = true
      else:
        e.cliGot += n
        if e.cliGot < e.back.len:
          e.postCliRecv()
        else:
          e.cliEof = true

proc echoA(size: int, tag: string) =
  let p = mkPair(tag)
  if p.err.len > 0:
    fact("a.echo_" & tag, "setup " & p.err)
    return
  let e = EchoA(
    srv: p.a,
    cli: p.c,
    want: payload(size, size),
    sbuf: newSeq[byte](65536),
    back: newSeq[byte](size),
  )
  gObjs.add e
  for op in [addr e.srvRecv, addr e.srvSend, addr e.cliRecv, addr e.cliSend]:
    op[] = newOp(onEchoA)
    op[].owner = cast[pointer](e)
  if tag == "1B":
    fact("a.register_accepted", reg(p.a))
    fact("a.register_client", reg(p.c))
  else:
    discard reg(p.a)
    discard reg(p.c)
  let t = Moment.now()
  e.postSrvRecv()
  e.postCliRecv()
  e.postCliSend()
  let done = runUntil(
    proc(): bool =
      e.err.len > 0 or (e.cliEof and e.cliGot == size),
    60000,
  )
  let res =
    if e.err.len > 0:
      e.err
    elif not done:
      "timeout got=" & $e.cliGot
    elif e.back == e.want:
      "ok"
    else:
      "mismatch"
  fact("a.echo_" & tag, res)
  fact("a.echo_" & tag & "_ms", msSince(t))
  discard lp_close(p.c)
  spin(50)
  discard lp_close(p.a)
  discard lp_close(p.l)

proc acceptExTest() =
  let path = sockPath("ax")
  let l = lp_socket()
  fact("a.acceptex_listen", lp_bind_listen(l, path.cstring, 16))
  fact("a.acceptex_register_listener", reg(l))
  let x = lp_socket()
  let op = newOp()
  var buf: array[512, byte]
  fact("a.acceptex_post", lp_acceptex(l, x, buf[0].addr, cast[pointer](op)))
  let c = lp_socket()
  discard lp_nonblock(c, 1)
  let cr = lp_connect(c, path.cstring)
  fact(
    "a.acceptex_connect",
    if cr == WouldBlock:
      "wouldblock"
    else:
      $cr,
  )
  let got = runUntil(
    proc(): bool =
      op.fired,
    5000,
  )
  fact("a.acceptex_completed", orTimeout(got, errText(op.err)))
  if got and op.err == OkCode:
    fact("a.acceptex_update_context", lp_update_accept(x, l))
    fact("a.acceptex_peerpid_is_self", lp_peerpid(x) == culong(GetCurrentProcessId()))
    fact("a.acceptex_register_accepted", reg(x))
    var b: array[1, byte]
    let rop = newOp()
    discard lp_wsarecv(x, b[0].addr, 1, cast[pointer](rop))
    discard lp_nonblock(c, 0)
    var one = [byte 7]
    discard lp_send(c, one[0].addr, 1)
    let rgot = runUntil(
      proc(): bool =
        rop.fired,
      3000,
    )
    fact(
      "a.acceptex_socket_reads",
      rgot and rop.err == OkCode and rop.bytes == 1 and b[0] == 7,
    )
  # A pending WSARecv whose socket closes: does the completion still arrive?
  let rop2 = newOp()
  var b2: array[16, byte]
  discard lp_wsarecv(x, b2[0].addr, 16, cast[pointer](rop2))
  discard lp_close(x)
  let cgot = runUntil(
    proc(): bool =
      rop2.fired,
    3000,
  )
  fact("a.close_with_pending_recv", orTimeout(cgot, errText(rop2.err)))
  discard lp_close(c)
  discard lp_close(l)

proc connectExTest() =
  let path = sockPath("cx")
  let l = lp_socket()
  discard lp_bind_listen(l, path.cstring, 16)
  var stage: cint
  # Unbound first: Winsock requires a bound socket for ConnectEx.
  let s1 = lp_socket()
  discard reg(s1)
  let op1 = newOp()
  let r1 = lp_connectex(s1, path.cstring, cast[pointer](op1), stage.addr)
  fact("a.connectex_unbound", "stage=" & $stage & " r=" & $r1)
  discard lp_close(s1)
  let s2 = lp_socket()
  let own = sockPath("cxb")
  fact("a.connectex_bind_client", lp_bind(s2, own.cstring))
  discard reg(s2)
  let op2 = newOp()
  let r2 = lp_connectex(s2, path.cstring, cast[pointer](op2), stage.addr)
  fact("a.connectex_bound", "stage=" & $stage & " r=" & $r2)
  if stage == 3:
    let got = runUntil(
      proc(): bool =
        op2.fired,
      3000,
    )
    fact("a.connectex_completed", orTimeout(got, errText(op2.err)))
  discard lp_close(s2)
  discard lp_close(l)

# ------------------------------------------------- (b) zero-byte operations

proc zeroByteTest() =
  let p = mkPair("zb")
  if p.err.len > 0:
    fact("b.setup", p.err)
    return
  discard reg(p.a)
  discard reg(p.c)
  var dummy: array[1, byte]
  let op = newOp()
  fact("b.zero_recv_post", lp_wsarecv(p.a, dummy[0].addr, 0, cast[pointer](op)))
  spin(150)
  fact("b.zero_recv_waits_without_data", not op.fired)
  var five = [byte 1, 2, 3, 4, 5]
  discard lp_send(p.c, five[0].addr, 5)
  let got = runUntil(
    proc(): bool =
      op.fired,
    3000,
  )
  fact(
    "b.zero_recv_completes_on_data",
    orTimeout(got, errText(op.err) & " bytes=" & $op.bytes),
  )
  discard lp_nonblock(p.a, 1)
  var buf: array[16, byte]
  fact("b.data_still_queued_after_zero_recv", lp_recv(p.a, buf[0].addr, 16))
  op.rearm()
  discard lp_wsarecv(p.a, dummy[0].addr, 0, cast[pointer](op))
  discard lp_shutdown_send(p.c)
  let got2 = runUntil(
    proc(): bool =
      op.fired,
    3000,
  )
  fact("b.zero_recv_completes_on_eof", orTimeout(got2, errText(op.err)))
  fact("b.recv_after_eof", lp_recv(p.a, buf[0].addr, 16))
  # Zero-byte send with a full send path (a -> c, c not reading).
  var chunk = newSeq[byte](65536)
  var queued = 0
  while true:
    let r = lp_send(p.a, chunk[0].addr, cint(chunk.len))
    if r > 0:
      queued += int(r)
    else:
      fact("b.fill_stopped", -r)
      break
    if queued > 64 shl 20:
      fact("b.fill_stopped", "64MiB without blocking")
      break
  fact("b.fill_queued_bytes", queued)
  let sop = newOp()
  fact("b.zero_send_post", lp_wsasend(p.a, chunk[0].addr, 0, cast[pointer](sop)))
  spin(150)
  fact("b.zero_send_waits_when_full", not sop.fired)
  # Drain the client.
  var drained = 0
  discard lp_nonblock(p.c, 1)
  var rb = newSeq[byte](65536)
  let t = Moment.now()
  while drained < queued and msSince(t) < 5000:
    let r = lp_recv(p.c, rb[0].addr, cint(rb.len))
    if r > 0:
      drained += r
    else:
      spin(1)
  let sgot = runUntil(
    proc(): bool =
      sop.fired,
    3000,
  )
  fact("b.zero_send_after_drain", orTimeout(sgot, errText(sop.err)))
  discard lp_close(p.c)
  discard lp_close(p.a)
  discard lp_close(p.l)

# ------------------------------------------- readiness echo, for (c) and (d)

type
  Mech = enum
    mEvent
    mAfd

  Peer = ref object of RootObj
    s: uint
    server: bool
    toSend: seq[byte]
    sendOff: int
    got: seq[byte]
    want: int
    shut, eof, done: bool
    err: string
    wakeups: int
    ev: pointer
    wh: WaitableHandle
    base: uint
    op: OpRef
    armed: bool

var gAfd: pointer
var gByWait: Table[pointer, Peer]
var rbuf = newSeq[byte](65536)

proc pump(p: Peer) =
  inc p.wakeups
  while not p.eof:
    let r = lp_recv(p.s, rbuf[0].addr, cint(rbuf.len))
    if r > 0:
      if p.server:
        p.toSend.add rbuf.toOpenArray(0, int(r) - 1)
      else:
        p.got.add rbuf.toOpenArray(0, int(r) - 1)
    elif r == 0:
      p.eof = true
    elif -r == WouldBlock:
      break
    else:
      p.err = "recv " & $(-r)
      return
  while p.sendOff < p.toSend.len:
    let n = min(p.toSend.len - p.sendOff, 65536)
    let r = lp_send(p.s, p.toSend[p.sendOff].addr, cint(n))
    if r > 0:
      p.sendOff += int(r)
    elif -r == WouldBlock:
      break
    else:
      p.err = "send " & $(-r)
      return
  if p.server and p.sendOff == p.toSend.len:
    p.toSend.setLen(0)
    p.sendOff = 0
  if not p.shut and p.sendOff == p.toSend.len and (not p.server or p.eof):
    discard lp_shutdown_send(p.s)
    p.shut = true
  p.done = p.shut and p.eof and (p.server or p.got.len == p.want)

proc onEventReady(arg: pointer) {.gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    let op = cast[PtrCustomOverlapped](arg)
    let p = gByWait.getOrDefault(op.data.udata)
    if p == nil or p.done:
      return
    var errs: array[10, cint]
    let bits = lp_enum_events(p.s, p.ev, errs[0].addr)
    if bits < 0:
      p.err = "enum " & $(-bits)
      return
    pump(p)

proc afdArm(p: Peer) =
  if p.done or p.armed or p.err.len > 0:
    return
  var ev = AfdDisconnect or AfdAbort or AfdLocalClose
  if not p.eof:
    ev = ev or AfdReceive
  if p.sendOff < p.toSend.len:
    ev = ev or AfdSend
  p.op.rearm()
  let r = lp_afd_poll(gAfd, p.base, culong(ev), p.op.info[0].addr, cast[pointer](p.op))
  if r != 0:
    p.err = "afd poll " & $r
  else:
    p.armed = true

proc onAfdReady(arg: pointer) {.gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    let op = cast[ptr Op](arg)
    let p = cast[Peer](op.owner)
    p.armed = false
    if int(op.data.errCode) != OkCode:
      p.err = "afd completion " & $int(op.data.errCode)
      return
    pump(p)
    afdArm(p)

proc attach(p: Peer, mech: Mech): string =
  if lp_nonblock(p.s, 1) != 0:
    return "nonblock"
  case mech
  of mEvent:
    p.ev = lp_event()
    let r = lp_eventselect(p.s, p.ev, FdRead or FdWrite or FdClose)
    if r != 0:
      return "eventselect " & $r
    let wh = registerWaitable(
      HANDLE(cast[uint](p.ev)),
      ULONG(WT_EXECUTEINWAITTHREAD),
      InfiniteDuration,
      onEventReady,
      nil,
    )
    if wh.isErr:
      return "registerWaitable " & $int(wh.error)
    p.wh = wh.get()
    gByWait[cast[pointer](p.wh)] = p
  of mAfd:
    var e: cint
    p.base = lp_base_handle(p.s, e.addr)
    if p.base == BadSock:
      return "base handle " & $e
    p.op = newOp(onAfdReady)
    p.op.owner = cast[pointer](p)

proc echoReady(mech: Mech, pairs, size: int, label: string, signals = false) =
  let prefix = (if mech == mEvent: "c." else: "d.") & label
  var peers: seq[Peer]
  var socks: seq[uint]
  for i in 0 ..< pairs:
    let p = mkPair(label)
    if p.err.len > 0:
      fact(prefix & "_setup", "pair " & $i & " " & p.err)
      return
    socks.add [p.l, p.a, p.c]
    let srv = Peer(s: p.a, server: true)
    let cli = Peer(s: p.c, toSend: payload(size, i + 1), want: size)
    for q in [srv, cli]:
      gObjs.add q
      let r = attach(q, mech)
      if r.len > 0:
        fact(prefix & "_setup", "pair " & $i & " " & r)
        return
      peers.add q
  if signals:
    startSignals()
  let t = Moment.now()
  for q in peers:
    pump(q)
    if mech == mAfd:
      afdArm(q)
  let fin = runUntil(
    proc(): bool =
      for q in peers:
        if q.err.len > 0:
          return true
        if not q.done:
          return false
      true,
    120000,
  )
  let ms = msSince(t)
  if signals:
    endSignals(prefix)
  var ok, bad = 0
  var firstErr = ""
  var wakeups = 0
  for i, q in peers:
    wakeups += q.wakeups
    if q.err.len > 0 and firstErr.len == 0:
      firstErr = q.err
    if not q.server:
      if q.done and q.got == q.toSend:
        inc ok
      else:
        inc bad
  let res =
    if firstErr.len > 0:
      firstErr
    elif not fin:
      "timeout ok=" & $ok
    elif bad == 0:
      "ok"
    else:
      "mismatch bad=" & $bad
  fact(prefix, res)
  fact(prefix & "_pairs_ok", ok)
  fact(prefix & "_ms", ms)
  fact(prefix & "_wakeups", wakeups)
  for q in peers:
    if mech == mEvent and q.wh != nil:
      discard closeWaitable(q.wh)
  for s in socks:
    discard lp_close(s)
  spin(100) # let the closes' completions drain while the Ops are alive

# ------------------------------------------------- (d) AFD poll semantics

proc afdSemantics() =
  var e: cint
  gAfd = lp_afd_open(e.addr)
  fact(
    "d.afd_open",
    if gAfd == nil:
      "err=" & $e
    else:
      "ok",
  )
  if gAfd == nil:
    return
  fact("d.afd_register", reg(cast[uint](gAfd)))
  let p = mkPair("ds")
  if p.err.len > 0:
    fact("d.setup", p.err)
    return
  var be: cint
  let ba = lp_base_handle(p.a, be.addr)
  let bc = lp_base_handle(p.c, be.addr)
  fact("d.base_is_socket", ba == p.a and bc == p.c)
  let op = newOp()
  fact(
    "d.poll_post",
    lp_afd_poll(
      gAfd, ba, culong(AfdReceive or AfdDisconnect), op.info[0].addr, cast[pointer](op)
    ),
  )
  spin(150)
  fact("d.recv_poll_waits_without_data", not op.fired)
  var five = [byte 1, 2, 3, 4, 5]
  discard lp_send(p.c, five[0].addr, 5)
  var got = runUntil(
    proc(): bool =
      op.fired,
    3000,
  )
  fact("d.recv_poll_on_data", orTimeout(got, evs(op)))
  # Level-triggered: data still queued, so a new poll completes at once.
  op.rearm()
  discard lp_afd_poll(gAfd, ba, culong(AfdReceive), op.info[0].addr, cast[pointer](op))
  got = runUntil(
    proc(): bool =
      op.fired,
    1000,
  )
  fact("d.recv_poll_level_triggered", got)
  discard lp_nonblock(p.a, 1)
  var buf: array[16, byte]
  discard lp_recv(p.a, buf[0].addr, 16)
  # Send readiness: empty buffer completes at once; full buffer waits.
  op.rearm()
  discard lp_afd_poll(gAfd, bc, culong(AfdSend), op.info[0].addr, cast[pointer](op))
  got = runUntil(
    proc(): bool =
      op.fired,
    1000,
  )
  fact("d.send_poll_when_empty", orTimeout(got, evs(op)))
  discard lp_nonblock(p.c, 1)
  var chunk = newSeq[byte](65536)
  var queued = 0
  while queued < 64 shl 20:
    let r = lp_send(p.c, chunk[0].addr, cint(chunk.len))
    if r > 0:
      queued += int(r)
    else:
      break
  fact("d.fill_queued_bytes", queued)
  op.rearm()
  discard lp_afd_poll(gAfd, bc, culong(AfdSend), op.info[0].addr, cast[pointer](op))
  spin(150)
  fact("d.send_poll_waits_when_full", not op.fired)
  var drained = 0
  var rb = newSeq[byte](65536)
  let t = Moment.now()
  while drained < queued and msSince(t) < 5000 and not op.fired:
    let r = lp_recv(p.a, rb[0].addr, cint(rb.len))
    if r > 0:
      drained += int(r)
    else:
      spin(1)
  got = runUntil(
    proc(): bool =
      op.fired,
    3000,
  )
  fact("d.send_poll_after_drain", orTimeout(got, evs(op) & " drained=" & $drained))
  while true:
    let r = lp_recv(p.a, rb[0].addr, cint(rb.len))
    if r <= 0:
      break
  # Peer shutdown and close.
  op.rearm()
  discard lp_afd_poll(
    gAfd,
    ba,
    culong(AfdReceive or AfdDisconnect or AfdAbort),
    op.info[0].addr,
    cast[pointer](op),
  )
  discard lp_shutdown_send(p.c)
  got = runUntil(
    proc(): bool =
      op.fired,
    3000,
  )
  fact("d.poll_on_peer_shutdown", orTimeout(got, evs(op)))
  # Closing a socket with a pending poll.
  op.rearm()
  discard lp_afd_poll(
    gAfd, ba, culong(AfdLocalClose or AfdSend), op.info[0].addr, cast[pointer](op)
  )
  let op2 = newOp()
  discard lp_afd_poll(
    gAfd,
    bc,
    culong(AfdLocalClose or AfdReceive or AfdAbort or AfdDisconnect),
    op2.info[0].addr,
    cast[pointer](op2),
  )
  spin(50)
  op.rearm()
  discard
    lp_afd_poll(gAfd, ba, culong(AfdLocalClose), op.info[0].addr, cast[pointer](op))
  discard lp_close(p.a)
  got = runUntil(
    proc(): bool =
      op.fired,
    3000,
  )
  fact("d.poll_on_local_close", orTimeout(got, evs(op)))
  got = runUntil(
    proc(): bool =
      op2.fired,
    3000,
  )
  fact("d.poll_on_peer_close", orTimeout(got, evs(op2)))
  discard lp_close(p.c)
  discard lp_close(p.l)

# ----------------- (d) more: two polls, cancel, accept, an inherited listener

proc afdMore() =
  let p = mkPair("dm")
  if p.err.len > 0:
    fact("d.more_setup", p.err)
    return
  # Two outstanding polls on one socket: receive and send interest apart.
  let rop = newOp()
  let sop = newOp()
  discard
    lp_afd_poll(gAfd, p.a, culong(AfdReceive), rop.info[0].addr, cast[pointer](rop))
  discard lp_afd_poll(gAfd, p.a, culong(AfdSend), sop.info[0].addr, cast[pointer](sop))
  var got = runUntil(
    proc(): bool =
      sop.fired,
    1000,
  )
  fact("d.two_polls_send_completes", orTimeout(got, evs(sop)))
  fact("d.two_polls_recv_still_waits", not rop.fired)
  var one = [byte 9]
  discard lp_send(p.c, one[0].addr, 1)
  got = runUntil(
    proc(): bool =
      rop.fired,
    3000,
  )
  fact("d.two_polls_recv_completes", orTimeout(got, evs(rop)))
  var b: array[4, byte]
  discard lp_recv(p.a, b[0].addr, 4)
  # Cancelling a pending poll (to drop interest without closing the socket).
  rop.rearm()
  discard
    lp_afd_poll(gAfd, p.a, culong(AfdReceive), rop.info[0].addr, cast[pointer](rop))
  spin(20)
  fact("d.cancel_call", lp_cancel(gAfd, cast[pointer](rop)))
  got = runUntil(
    proc(): bool =
      rop.fired,
    3000,
  )
  fact("d.cancel_completion", orTimeout(got, errText(rop.err)))
  discard lp_close(p.a)
  discard lp_close(p.c)
  # Accept readiness on a listener.
  let lp = sockPath("dl")
  let l = lp_socket()
  discard lp_bind_listen(l, lp.cstring, 16)
  discard lp_nonblock(l, 1)
  let aop = newOp()
  discard lp_afd_poll(gAfd, l, culong(AfdAccept), aop.info[0].addr, cast[pointer](aop))
  spin(100)
  fact("d.accept_poll_waits", not aop.fired)
  let c = lp_socket()
  discard lp_nonblock(c, 1)
  discard lp_connect(c, lp.cstring)
  got = runUntil(
    proc(): bool =
      aop.fired,
    3000,
  )
  fact("d.accept_poll_on_connect", orTimeout(got, evs(aop)))
  let x = lp_accept(l)
  fact(
    "d.accept_after_poll",
    if x == BadSock:
      "err=" & $lp_lasterr()
    else:
      "ok",
  )
  discard lp_close(x)
  discard lp_close(c)
  discard lp_close(l)
  spin(50)

# ------------------------------- (c) and (d): accept and connect readiness

var gEvFired: Table[pointer, int]

proc onEvFlag(arg: pointer) {.gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    let op = cast[PtrCustomOverlapped](arg)
    gEvFired.mgetOrPut(op.data.udata, 0) += 1

proc acceptConnectReady() =
  # (c): FD_ACCEPT on a listener and FD_CONNECT on a non-blocking connect.
  let lp = sockPath("ca")
  let l = lp_socket()
  discard lp_bind_listen(l, lp.cstring, 16)
  let lev = lp_event()
  fact("c.accept_eventselect", lp_eventselect(l, lev, FdAccept))
  let lwh = registerWaitable(
      HANDLE(cast[uint](lev)),
      ULONG(WT_EXECUTEINWAITTHREAD),
      InfiniteDuration,
      onEvFlag,
      nil,
    )
    .get()
  let lkey = cast[pointer](lwh)
  let c = lp_socket()
  let cev = lp_event()
  fact("c.connect_eventselect", lp_eventselect(c, cev, FdConnect or FdWrite))
  let cwh = registerWaitable(
      HANDLE(cast[uint](cev)),
      ULONG(WT_EXECUTEINWAITTHREAD),
      InfiniteDuration,
      onEvFlag,
      nil,
    )
    .get()
  let ckey = cast[pointer](cwh)
  let cr = lp_connect(c, lp.cstring)
  fact(
    "c.connect_call",
    if cr == WouldBlock:
      "wouldblock"
    else:
      $cr,
  )
  var got = runUntil(
    proc(): bool =
      gEvFired.getOrDefault(lkey) > 0,
    3000,
  )
  fact("c.accept_event", got)
  var errs: array[10, cint]
  let lbits = lp_enum_events(l, lev, errs[0].addr)
  fact("c.accept_bits", "0x" & toHex(lbits, 2) & " err=" & $errs[3])
  let x = lp_accept(l)
  fact(
    "c.accept_after_event",
    if x == BadSock:
      "err=" & $lp_lasterr()
    else:
      "ok",
  )
  got = runUntil(
    proc(): bool =
      gEvFired.getOrDefault(ckey) > 0,
    3000,
  )
  fact("c.connect_event", got)
  let cbits = lp_enum_events(c, cev, errs[0].addr)
  fact("c.connect_bits", "0x" & toHex(cbits, 2) & " err=" & $errs[4])
  discard closeWaitable(lwh)
  discard closeWaitable(cwh)
  discard lp_close(x)
  discard lp_close(c)
  discard lp_close(l)
  # (c): a connect to a path with no listener.
  let gone = sockPath("cg")
  let c2 = lp_socket()
  let c2ev = lp_event()
  discard lp_eventselect(c2, c2ev, FdConnect)
  let r2 = lp_connect(c2, gone.cstring)
  fact(
    "c.connect_missing_path",
    if r2 == WouldBlock:
      "wouldblock"
    else:
      $r2,
  )
  discard lp_close(c2)
  # (d): a non-blocking connect completes as send readiness.
  let dp = sockPath("dc")
  let dl = lp_socket()
  discard lp_bind_listen(dl, dp.cstring, 16)
  let dc = lp_socket()
  discard lp_nonblock(dc, 1)
  let dr = lp_connect(dc, dp.cstring)
  fact(
    "d.connect_call",
    if dr == WouldBlock:
      "wouldblock"
    else:
      $dr,
  )
  let op = newOp()
  discard lp_afd_poll(
    gAfd, dc, culong(AfdSend or 0x100'u32), op.info[0].addr, cast[pointer](op)
  )
  got = runUntil(
    proc(): bool =
      op.fired,
    3000,
  )
  fact("d.connect_poll", orTimeout(got, evs(op)))
  discard lp_close(dc)
  discard lp_close(dl)
  spin(50)

proc inheritedListener() =
  ## The parent binds, listens and registers the listener on its own port (as
  ## variant (a) would); a child that inherits it polls it with AFD.
  let lp = sockPath("il")
  let l = lp_socket()
  discard lp_bind_listen(l, lp.cstring, 16)
  fact("inherit.parent_register_listener", reg(l))
  fact("inherit.mark_inheritable", lp_inherit(l, 1))
  let cmd =
    "\"" & getAppFilename() & "\" child " & $l & " " & $GetCurrentProcessId() & " \"" &
    dir & "\""
  let child = lp_spawn(cmd.cstring)
  fact("inherit.spawn", child != nil)
  if child == nil:
    return
  discard lp_inherit(l, 0)
  let c = lp_socket()
  discard lp_nonblock(c, 1)
  discard lp_connect(c, lp.cstring)
  discard lp_writable(c, 3000)
  discard lp_nonblock(c, 0)
  var one = [byte 42]
  discard lp_send(c, one[0].addr, 1)
  fact("inherit.child_exit", lp_wait(child, 15000))
  discard lp_close(c)
  discard lp_close(l)

proc childMain() =
  let l = uint(parseBiggestUInt(paramStr(2)))
  let parent = parseBiggestUInt(paramStr(3))
  dir = paramStr(4)
  discard lp_init()
  discard getThreadDispatcher()
  fact("child.register_inherited_listener", reg(l))
  var e: cint
  gAfd = lp_afd_open(e.addr)
  fact(
    "child.afd_open",
    if gAfd == nil:
      "err=" & $e
    else:
      "ok",
  )
  if gAfd == nil:
    quit 2
  discard reg(cast[uint](gAfd))
  let base = lp_base_handle(l, e.addr)
  fact("child.base_is_socket", base == l)
  discard lp_nonblock(l, 1)
  let aop = newOp()
  fact(
    "child.accept_poll_post",
    lp_afd_poll(gAfd, base, culong(AfdAccept), aop.info[0].addr, cast[pointer](aop)),
  )
  var got = runUntil(
    proc(): bool =
      aop.fired,
    5000,
  )
  fact("child.accept_poll", orTimeout(got, evs(aop)))
  let x = lp_accept(l)
  fact(
    "child.accept",
    if x == BadSock:
      "err=" & $lp_lasterr()
    else:
      "ok",
  )
  if x == BadSock:
    quit 3
  fact("child.peerpid_is_parent", uint64(lp_peerpid(x)) == parent)
  let rop = newOp()
  discard lp_afd_poll(gAfd, x, culong(AfdReceive), rop.info[0].addr, cast[pointer](rop))
  got = runUntil(
    proc(): bool =
      rop.fired,
    3000,
  )
  fact("child.recv_poll", orTimeout(got, evs(rop)))
  var b: array[4, byte]
  let n = lp_recv(x, b[0].addr, 4)
  fact("child.recv", $n & " byte0=" & $b[0])
  discard lp_close(x)
  quit 0

# ----------------------------------------------------------------------- main

proc main() =
  if paramCount() < 1:
    quit "usage: loopprobe <dir>"
  if paramStr(1) == "child":
    childMain()
  dir = paramStr(1)
  createDir(dir)
  fact("wsastartup", lp_init())
  fact("pid", GetCurrentProcessId())
  discard getThreadDispatcher()
  # (a)
  echoA(1, "1B")
  echoA(65536, "64K")
  startSignals()
  echoA(8 shl 20, "8M")
  endSignals("a")
  acceptExTest()
  connectExTest()
  # (b)
  zeroByteTest()
  # (c)
  echoReady(mEvent, 1, 1, "echo_1B")
  echoReady(mEvent, 1, 8 shl 20, "echo_8M", signals = true)
  echoReady(mEvent, 200, 1024, "scale200_1K")
  # (d)
  afdSemantics()
  if gAfd != nil:
    echoReady(mAfd, 1, 1, "echo_1B")
    echoReady(mAfd, 1, 8 shl 20, "echo_8M", signals = true)
    echoReady(mAfd, 200, 1024, "scale200_1K")
    echoReady(mAfd, 200, 256 * 1024, "scale200_256K")
    afdMore()
    acceptConnectReady()
    inheritedListener()
  echoReady(mEvent, 200, 256 * 1024, "scale200_256K")
  fact("done", 1)

main()
