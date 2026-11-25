## The remote control channel in tests (Tier 5 step 5-7a-1; DECISIONS G410,
## G411): a socket pair, frames over a chronos transport on each end, a
## `SignClient` at a TLS process's end, and logosd's end answering it with its
## signing service or relaying it to a key holder. Each end records the kinds
## it wrote and read, the channel's trace.

import std/posix
import chronos
import results
import ../../src/logos_core/daemon/signsvc

export chronos, results, signsvc

type RchEnd* = ref object
  t*: StreamTransport
  fd*: cint
  reader: FrameReader
  queued: seq[LcnRchMessage]
  eof*: bool
  sent*: seq[LcnRchMessageKind] ## every message this end wrote
  got*: seq[LcnRchMessageKind] ## every message this end read

proc socketPair*(): (cint, cint) =
  ## A connected AF_UNIX stream pair, close-on-exec.
  var fds: array[2, cint]
  doAssert socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0
  for fd in fds:
    discard fcntl(fd, F_SETFD, FD_CLOEXEC)
  (fds[0], fds[1])

proc endOf*(fd: cint): RchEnd =
  ## `fd` (now non-blocking) as one end of a channel on this thread's loop.
  let fl = fcntl(fd, F_GETFL)
  discard fcntl(fd, F_SETFL, fl or O_NONBLOCK)
  RchEnd(t: fromPipe(AsyncFD(fd)), fd: fd, reader: newRchReader())

proc sendBytes*(e: RchEnd, data: seq[byte]): Future[bool] {.async: (raises: []).} =
  ## Raw bytes, for a test that writes what no conforming end would.
  try:
    var d = data
    return (await e.t.write(addr d[0], d.len)) == d.len
  except CatchableError:
    return false

proc send*(e: RchEnd, m: LcnRchMessage): Future[bool] {.async: (raises: []).} =
  e.sent.add(m.kind)
  return await e.sendBytes(frameOf(m).get)

proc receive*(e: RchEnd): Future[Opt[LcnRchMessage]] {.async: (raises: []).} =
  ## The next message; none at the end of the channel, after a frame that
  ## does not decode, or when the wait is cancelled (the channel stays usable).
  while e.queued.len == 0:
    if e.eof:
      return Opt.none(LcnRchMessage)
    var buf: array[4096, byte]
    let n =
      try:
        await e.t.readOnce(addr buf[0], buf.len)
      except CancelledError:
        return Opt.none(LcnRchMessage)
      except TransportError:
        0
    if n == 0:
      e.eof = true
      return Opt.none(LcnRchMessage)
    let bodies = e.reader.feed(buf.toOpenArray(0, n - 1)).valueOr:
      e.eof = true
      return Opt.none(LcnRchMessage)
    for b in bodies:
      let m = decodeMessage(b).valueOr:
        e.eof = true
        return Opt.none(LcnRchMessage)
      e.queued.add(m)
  let m = e.queued[0]
  e.queued.delete(0)
  e.got.add(m.kind)
  return Opt.some(m)

proc close*(e: RchEnd) {.async: (raises: []).} =
  await e.t.closeWait()

# A TLS process's end ---------------------------------------------------------------------

proc clientOn*(e: RchEnd, role: TlsRole): SignClient =
  ## A `SignClient` writing to `e`; `pumpAnswers` delivers its answers.
  let c = newSignClient(
    role,
    proc(id: uint64, alg: uint16, input: seq[byte]): bool {.gcsafe, raises: [].} =
      asyncSpawn (
        proc() {.async: (raises: []).} =
          discard await e.send(signRequest(id, alg, input))
      )()
      true,
  )
  c

proc pumpAnswers*(e: RchEnd, c: SignClient, faults: ref int) {.async: (raises: []).} =
  ## Delivers each answer `e` reads to `c` until the channel ends, then
  ## closes `c`. A message that is no answer, or names no request, counts as
  ## a fault and ends the pump, as it ends a process's channel.
  while true:
    let m = (await e.receive()).valueOr:
      break
    if not m.isAnswer or not c.deliver(m.answerId, m.answerOf):
      inc faults[]
      break
  c.close()

# logosd's end ------------------------------------------------------------------------------

proc serveService*(
    e: RchEnd, svc: SignService, role: TlsRole, frozenNs = -1'i64
) {.async: (raises: []).} =
  ## logosd's end in the default mode: each sign request answered by `svc`
  ## for a process of `role`, until the channel ends or carries anything else.
  ## With `frozenNs` set, every answer is at that monotonic time: the limit
  ## never refills, so a burst's count does not depend on how fast it is served.
  var p = newProcessSigning(role)
  while true:
    let m = (await e.receive()).valueOr:
      break
    if m.kind != LcnRchMessageKind.lcn_Rch_sign:
      break
    let now =
      if frozenNs >= 0:
        frozenNs
      else:
        monoNs()
    if not await e.send(svc.answer(p, m.arm_lcn_Rch_sign, now)):
      break

proc serveRelay*(
    e: RchEnd, holder: RchEnd, role: TlsRole, relay: ref HolderRelay
) {.async: (raises: []).} =
  ## logosd's end in key-holder mode, for one process (origin 1): each request
  ## relayed to `holder` or refused by logosd itself, each answer from the
  ## holder relayed back until the holder's channel ends.
  var p = newProcessSigning(role)
  asyncSpawn (
    proc() {.async: (raises: []).} =
      while true:
        let a = (await holder.receive()).valueOr:
          break
        let (origin, m) = relay[].returned(a).valueOr:
          break
        if origin == 1:
          discard await e.send(m)
  )()
  while true:
    let m = (await e.receive()).valueOr:
      break
    if m.kind != LcnRchMessageKind.lcn_Rch_sign:
      break
    let ask = relay[].relay(1, p, m.arm_lcn_Rch_sign)
    if ask.isOk:
      if not await holder.send(ask.get):
        break
    elif not await e.send(ask.error):
      break
