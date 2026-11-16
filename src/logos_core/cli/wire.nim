## `logos-core-nim.cli.v1`'s wire (Tier 5 step N-2; DECISIONS G344, G345;
## BOOTSTRAP l.384-390): the launcher's request frame with its descriptors,
## the replies, their bounds and checks, and the exit statuses both sides
## share. docs/DAEMON.md §7a.
##
## Frames are ctl.v1's (`daemon/ctlwire.nim`): a 4-byte big-endian length and
## one deterministic-CBOR value. The request frame carries the launcher's
## descriptors as SCM_RIGHTS on its first byte; lcn_call reads every byte of
## it with recvmsg, so a descriptor is never left behind in the socket, and
## closes every descriptor it received when it refuses the frame.

{.push raises: [], gcsafe.}

import std/[monotimes, times]
import results
import ../cbor
import ../transport/io/sock
import ../daemon/ctlwire
import ./cli_types

export results, cli_types
export
  readFrame, writeFrame, connectCtl, closeFd, FrameError, FrameErrorKind, CredFn, Peer,
  peerOf

when defined(posix):
  import std/posix except Stat

const
  CliProtocol* = "logos-core-nim.cli.v1"
  MaxRequestBytes* = 1_179_648
    ## [IMPL] 1 MiB of argument text and 128 KiB for the rest of the request
  MaxReplyBytes* = 4096 ## [IMPL] a reply is a status and at most 512 bytes of text
  MaxFds* = 16 ## [G344] stdout, stderr and at most 14 `@FILE` arguments
  MaxArgs* = 256
  MaxEventNames* = 16
  LocalNode* = "local" ## [G347] this Runtime, through lcn_call's own binding
  HeaderBytes = 4

  # [G349] The launcher's exit statuses.
  ExitOk* = 0 ## done
  ExitRefused* = 1 ## refused before anything was called
  ExitUnreachable* = 2 ## no daemon, lcn_call unreachable or busy, or the outcome unknown
  ExitRc* = 4 ## a Runtime Control failure
  ExitProvider* = 5 ## the provider's error channel answered the call
  ExitStreamEnded* = 6 ## lcn_call ended the stream
  ExitInterrupted* = 130 ## the launcher cancelled

type
  Request* = object ## A request frame as lcn_call read it.
    bytes*: seq[byte]
    fds*: seq[cint] ## the descriptors, in arrival order; the caller closes them

  RequestError* = object
    kind*: FrameErrorKind
    message*: string

func requestError(kind: FrameErrorKind, message: string): RequestError =
  RequestError(kind: kind, message: message)

func `$`*(e: RequestError): string =
  e.message

proc remaining(deadline: MonoTime): int =
  max(0, int(inMilliseconds(deadline - getMonoTime())))

proc closeAll*(fds: var seq[cint]) =
  ## Closes every descriptor in `fds` and empties it.
  for fd in fds:
    if fd >= 0:
      discard fdClose(fd)
  fds.setLen(0)

when defined(posix):
  proc waitFd(fd: cint, events: cshort, deadline: MonoTime): Result[bool, string] =
    while true:
      var p = TPollfd(fd: fd, events: events)
      let n = poll(addr p, 1, cint(remaining(deadline)))
      if n > 0:
        return ok(true)
      if n == 0:
        return ok(false)
      if errno != EINTR:
        return err("poll: " & $strerror(errno))

  proc recvSome(
      fd: cint,
      buf: var openArray[byte],
      got: var int,
      fds: var seq[cint],
      deadline: MonoTime,
      started: bool,
  ): Result[void, RequestError] =
    ## Fills `buf` from `got`, collecting the descriptors that arrive.
    while got < buf.len:
      var arrived: array[MaxFds, cint]
      var n = cint(0)
      var dropped = cint(0)
      let room = cint(MaxFds - fds.len)
      let r = sockRecvFds(
        fd,
        addr buf[got],
        csize_t(buf.len - got),
        addr arrived[0],
        room,
        addr n,
        addr dropped,
      )
      for i in 0 ..< int(n):
        fds.add(arrived[i])
      if dropped > 0:
        return err(
          requestError(
            feTooLarge, "more than " & $MaxFds & " descriptors, or cut off: refused"
          )
        )
      if r > 0:
        got += int(r)
        continue
      if r == 0:
        if got == 0 and not started:
          return err(requestError(feEof, "the peer closed the connection"))
        return err(requestError(fePartial, "the peer closed the connection mid-frame"))
      if not wouldBlock(r):
        return err(requestError(feIo, "recvmsg: " & $strerror(cint(-r))))
      let ready = waitFd(fd, POLLIN, deadline).valueOr:
        return err(requestError(feIo, error))
      if not ready:
        if got == 0 and not started:
          return err(requestError(feTimeout, "no request before the idle timeout"))
        return err(requestError(fePartial, "a partial frame at the timeout"))
    ok()

proc readRequest*(
    fd: cint, timeoutMs: int, maxBytes = MaxRequestBytes
): Result[Request, RequestError] =
  ## [G344] The request frame and its descriptors, within `timeoutMs`. On any
  ## error every descriptor that arrived is already closed.
  when defined(posix):
    let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
    var fds: seq[cint] = @[]
    var header: array[HeaderBytes, byte]
    var got = 0
    let h = recvSome(fd, header, got, fds, deadline, false)
    if h.isErr:
      closeAll(fds)
      return err(h.error)
    let len =
      (int(header[0]) shl 24) or (int(header[1]) shl 16) or (int(header[2]) shl 8) or
      int(header[3])
    if len > maxBytes:
      closeAll(fds)
      return err(
        requestError(
          feTooLarge, "a frame of " & $len & " bytes exceeds " & $maxBytes & " bytes"
        )
      )
    var body = newSeq[byte](len)
    got = 0
    if len > 0:
      let b = recvSome(fd, body, got, fds, deadline, true)
      if b.isErr:
        closeAll(fds)
        return err(b.error)
    ok(Request(bytes: body, fds: fds))
  else:
    err(requestError(feIo, "unix-stream sockets are not supported on this platform"))

proc writeRequest*(
    fd: cint, value: openArray[byte], fds: openArray[cint], timeoutMs: int
): Result[void, string] =
  ## [G344] The launcher's side: one frame with `fds` on its first byte.
  when defined(posix):
    if value.len > MaxRequestBytes:
      return err(
        "a request of " & $value.len & " bytes exceeds " & $MaxRequestBytes & " bytes"
      )
    if fds.len > MaxFds:
      return err("more than " & $MaxFds & " descriptors")
    let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
    let n = uint32(value.len)
    var frame = newSeqOfCap[byte](HeaderBytes + value.len)
    frame.add([byte(n shr 24), byte(n shr 16), byte(n shr 8), byte(n)])
    frame.add(value)
    var local = newSeq[cint](fds.len)
    for i, f in fds:
      local[i] = f
    var sent = 0
    while sent < frame.len:
      let r =
        if sent == 0:
          sockSendFds(
            fd,
            addr frame[0],
            csize_t(frame.len),
            (if local.len > 0: addr local[0] else: nil),
            cint(local.len),
          )
        else:
          sockSend(fd, addr frame[sent], csize_t(frame.len - sent))
      if r >= 0:
        sent += int(r)
        continue
      if not wouldBlock(r):
        return err("send: " & $strerror(cint(-r)))
      let ready = ?waitFd(fd, POLLOUT, deadline)
      if not ready:
        return err("send: lcn_call did not read before the deadline")
    ok()
  else:
    err("unix-stream sockets are not supported on this platform")

# Requests ---------------------------------------------------------------------------

func validNodeName*(name: string): bool =
  ## [G347] `[a-z][a-z0-9_-]{0,62}`.
  if name.len < 1 or name.len > 63 or name[0] notin {'a' .. 'z'}:
    return false
  for c in name:
    if c notin {'a' .. 'z', '0' .. '9', '_', '-'}:
      return false
  true

func roleText*(r: LcnCliFdRoleKind): string =
  case r
  of LcnCliFdRoleKind.Stdout: "stdout"
  of LcnCliFdRoleKind.Stderr: "stderr"
  of LcnCliFdRoleKind.File: "file"

func role*(k: LcnCliFdRoleKind): LcnCliFdRole =
  LcnCliFdRole(kind: k)

func targetOf*(m: LcnCliMessage): string =
  ## [G347] The named node, or the default (`local` in N-2).
  m.target.get(LocalNode)

func isJson*(m: LcnCliMessage): bool =
  m.output.kind == LcnCliOutputKind.Json

func opName*(c: LcnCliCommand): string =
  case c.kind
  of LcnCliCommandKind.lcn_Cli_call_command: "call"
  of LcnCliCommandKind.lcn_Cli_describe_command: "describe"
  of LcnCliCommandKind.lcn_Cli_subscribe_command: "subscribe"
  of LcnCliCommandKind.lcn_Cli_events_command: "events"
  of LcnCliCommandKind.lcn_Cli_rc_command: "rc"

func checkMessage*(m: LcnCliMessage, received: int): Result[void, string] =
  ## [G344] The bounds cli.cddl gives in comments (G10 has no occurrence
  ## bounds), the descriptor roles against what arrived, and the file
  ## arguments' indexes. The target name is checked when the command runs.
  if m.fds.len < 2 or m.fds.len > MaxFds:
    return err("fds names " & $m.fds.len & " descriptors, not 2 to " & $MaxFds)
  if m.fds.len != received:
    return err("fds names " & $m.fds.len & " descriptors and " & $received & " arrived")
  if m.fds[0].kind != LcnCliFdRoleKind.Stdout or m.fds[1].kind != LcnCliFdRoleKind.Stderr:
    return err("the first two descriptors must be stdout and stderr")
  for i in 2 ..< m.fds.len:
    if m.fds[i].kind != LcnCliFdRoleKind.File:
      return err("descriptor " & $i & " must be a file")
  let c = m.command
  case c.kind
  of LcnCliCommandKind.lcn_Cli_call_command:
    let call = c.arm_lcn_Cli_call_command
    if call.args.isSome and call.json.isSome:
      return err("args and json are exclusive")
    var used: seq[bool] = newSeq[bool](m.fds.len)
    if call.args.isSome:
      let args = call.args.get
      if args.len > MaxArgs:
        return err("more than " & $MaxArgs & " arguments")
      for a in args:
        if a.kind == LcnCliArgKind.lcn_Cli_file_arg:
          let i = int(a.arm_lcn_Cli_file_arg.fd)
          if i < 2 or i >= m.fds.len:
            return err(
              "argument " & a.arm_lcn_Cli_file_arg.name & " names no file descriptor"
            )
          if used[i]:
            return err("descriptor " & $i & " is named twice")
          used[i] = true
    for i in 2 ..< m.fds.len:
      if not used[i]:
        return err("descriptor " & $i & " is no argument's")
  of LcnCliCommandKind.lcn_Cli_events_command:
    let e = c.arm_lcn_Cli_events_command
    if e.names.isSome and (e.names.get.len < 1 or e.names.get.len > MaxEventNames):
      return err("names lists 1 to " & $MaxEventNames & " events")
    if m.fds.len != 2:
      return err("events takes no file")
  of LcnCliCommandKind.lcn_Cli_describe_command,
      LcnCliCommandKind.lcn_Cli_subscribe_command, LcnCliCommandKind.lcn_Cli_rc_command:
    if m.fds.len != 2:
      return err(c.opName & " takes no file")
  ok()

proc decodeMessage*(bytes: openArray[byte]): Result[LcnCliMessage, string] =
  ## [G344] Deterministic CBOR naming this protocol, of cli.cddl's shape.
  let v = decodeCbor(bytes).valueOr:
    return err(error.msg)
  if v.kind != ckMap:
    return err("not a CBOR map")
  let p = v.lookup("protocol")
  if p.isNone or p.get.kind != ckText or p.get.text != CliProtocol:
    return err("not a " & CliProtocol & " message")
  LcnCliMessage.fromCbor(v)

# Replies ----------------------------------------------------------------------------

func acceptedReply*(): LcnCliReply =
  LcnCliReply(
    outcome: LcnCliOutcome(
      kind: LcnCliOutcomeKind.lcn_Cli_accepted, arm_lcn_Cli_accepted: LcnCliAccepted()
    )
  )

func doneReply*(exit: int): LcnCliReply =
  LcnCliReply(
    outcome: LcnCliOutcome(
      kind: LcnCliOutcomeKind.lcn_Cli_done,
      arm_lcn_Cli_done: LcnCliDone(exit: uint8(exit and 0xFF)),
    )
  )

func clip(s: string, n: int): string =
  ## At most `n` bytes, never splitting a UTF-8 sequence.
  if s.len <= n:
    return s
  var e = n
  while e > 0 and (byte(s[e]) and 0xC0) == 0x80:
    dec e
  s[0 ..< e]

func refusedReply*(reason: LcnCliRefusedReasonChoiceKind, message = ""): LcnCliReply =
  LcnCliReply(
    outcome: LcnCliOutcome(
      kind: LcnCliOutcomeKind.lcn_Cli_refused,
      arm_lcn_Cli_refused: LcnCliRefused(
        reason: LcnCliRefusedReasonChoice(kind: reason),
        message:
          (if message.len > 0: Opt.some(clip(message, 512))
          else: Opt.none(string)),
      ),
    )
  )

func reasonText*(r: LcnCliRefusedReasonChoiceKind): string =
  case r
  of LcnCliRefusedReasonChoiceKind.Busy: "busy"
  of LcnCliRefusedReasonChoiceKind.Closing: "closing"
  of LcnCliRefusedReasonChoiceKind.Protocol: "protocol"
  of LcnCliRefusedReasonChoiceKind.Too_large: "too-large"

proc writeReply*(fd: cint, r: LcnCliReply, timeoutMs: int): Result[void, string] =
  writeFrame(fd, ?r.encode, timeoutMs)

proc readReply*(fd: cint, timeoutMs: int): Result[LcnCliReply, FrameError] =
  ## One reply, within `timeoutMs`.
  let bytes = ?readFrame(fd, timeoutMs, MaxReplyBytes)
  let r = LcnCliReply.decode(bytes).valueOr:
    return err(FrameError(kind: feIo, message: "the reply does not decode: " & error))
  ok(r)

{.pop.}
