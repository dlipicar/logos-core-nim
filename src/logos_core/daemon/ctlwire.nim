## `logos-core-nim.ctl.v1`'s wire (Tier 4b step 4b-6; DECISIONS G296;
## BOOTSTRAP l.390): the frames, their bounds and the codecs, shared by the
## logosctl module and the shell. docs/DAEMON.md §7.
##
## A frame is a 4-byte big-endian length and one deterministic-CBOR value of
## at most `MaxFrameBytes`. The shell sends an `lcn.ctl_message`; the module
## answers each with one `lcn.ctl_reply`. Every wait is bounded by poll(2):
## sockets from `sock.nim` are non-blocking, close-on-exec, and never raise
## SIGPIPE.

{.push raises: [], gcsafe.}

import std/[monotimes, times]
import results
import logos_sdk/cbor
import ../transport/io/[peercred, sock]
import ./ctl_types

export results, ctl_types

when defined(posix):
  import std/posix except Stat

const
  CtlProtocol* = "logos-core-nim.ctl.v1"
  MaxFrameBytes* = 33_554_432 ## [IMPL] 32 MiB each way: a 16 MiB value and its envelope
  HeaderBytes = 4

type
  FrameErrorKind* = enum
    feEof ## the peer closed before a frame began
    feTimeout ## nothing arrived before the deadline
    fePartial ## a frame began and did not end: closed, or the deadline passed
    feTooLarge ## the length exceeds the bound
    feIo ## a socket error

  FrameError* = object
    kind*: FrameErrorKind
    message*: string

  Peer* = object ## A connected peer's credentials, as provenance.
    uid*: uint32
    pid*: Opt[int32]

func frameError(kind: FrameErrorKind, message: string): FrameError =
  FrameError(kind: kind, message: message)

func `$`*(e: FrameError): string =
  e.message

proc remaining(deadline: MonoTime): int =
  max(0, int(inMilliseconds(deadline - getMonoTime())))

when defined(posix):
  proc waitFd(fd: cint, events: cshort, deadline: MonoTime): Result[bool, string] =
    ## True when `fd` is ready for `events`, a hang-up or an error; false at
    ## the deadline.
    while true:
      var p = TPollfd(fd: fd, events: events)
      let n = poll(addr p, 1, cint(remaining(deadline)))
      if n > 0:
        return ok(true)
      if n == 0:
        return ok(false)
      if errno != EINTR:
        return err("poll: " & $strerror(errno))

proc readExact(
    fd: cint, buf: var openArray[byte], deadline: MonoTime, started: bool
): Result[void, FrameError] =
  ## Fills `buf`. `started` says a frame already began, so a close or a
  ## timeout is partial.
  when defined(posix):
    var got = 0
    while got < buf.len:
      let n = sockRecv(fd, addr buf[got], csize_t(buf.len - got))
      if n > 0:
        got += int(n)
        continue
      if n == 0:
        if got == 0 and not started:
          return err(frameError(feEof, "the peer closed the connection"))
        return err(frameError(fePartial, "the peer closed the connection mid-frame"))
      if not wouldBlock(n):
        return err(frameError(feIo, "recv: " & $strerror(cint(-n))))
      let ready = waitFd(fd, POLLIN, deadline).valueOr:
        return err(frameError(feIo, error))
      if not ready:
        if got == 0 and not started:
          return err(frameError(feTimeout, "no request before the idle timeout"))
        return err(frameError(fePartial, "a partial frame at the timeout"))
    ok()
  else:
    err(frameError(feIo, "unix-stream sockets are not supported on this platform"))

proc readFrame*(
    fd: cint, timeoutMs: int, maxBytes = MaxFrameBytes
): Result[seq[byte], FrameError] =
  ## One frame's value bytes, within `timeoutMs` of the call.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  var header: array[HeaderBytes, byte]
  ?readExact(fd, header, deadline, false)
  let len =
    (int(header[0]) shl 24) or (int(header[1]) shl 16) or (int(header[2]) shl 8) or
    int(header[3])
  if len > maxBytes:
    return err(
      frameError(
        feTooLarge, "a frame of " & $len & " bytes exceeds " & $maxBytes & " bytes"
      )
    )
  var body = newSeq[byte](len)
  if len > 0:
    ?readExact(fd, body, deadline, true)
  ok(body)

proc writeAll(
    fd: cint, data: openArray[byte], deadline: MonoTime
): Result[void, string] =
  when defined(posix):
    var sent = 0
    while sent < data.len:
      let n = sockSend(fd, unsafeAddr data[sent], csize_t(data.len - sent))
      if n >= 0:
        sent += int(n)
        continue
      if not wouldBlock(n):
        return err("send: " & $strerror(cint(-n)))
      let ready = ?waitFd(fd, POLLOUT, deadline)
      if not ready:
        return err("send: the peer did not read before the deadline")
    ok()
  else:
    err("unix-stream sockets are not supported on this platform")

proc writeFrame*(
    fd: cint, value: openArray[byte], timeoutMs: int
): Result[void, string] =
  ## One frame: the length, then `value`.
  if value.len > MaxFrameBytes:
    return
      err("a frame of " & $value.len & " bytes exceeds " & $MaxFrameBytes & " bytes")
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  let n = uint32(value.len)
  let header = [byte(n shr 24), byte(n shr 16), byte(n shr 8), byte(n)]
  ?writeAll(fd, header, deadline)
  writeAll(fd, value, deadline)

# Messages and replies --------------------------------------------------------------

func deploymentOf*(production: bool): LcnCtlDeployment =
  if production:
    LcnCtlDeployment(kind: LcnCtlDeploymentKind.Production)
  else:
    LcnCtlDeployment(kind: LcnCtlDeploymentKind.Non_production)

func isProduction*(d: LcnCtlDeployment): bool =
  d.kind == LcnCtlDeploymentKind.Production

func deploymentText*(d: LcnCtlDeployment): string =
  if d.isProduction: "production" else: "non-production"

func reasonOf*(r: LcnCtlRefusedReasonChoiceKind): string =
  case r
  of LcnCtlRefusedReasonChoiceKind.Busy: "busy"
  of LcnCtlRefusedReasonChoiceKind.Closing: "closing"
  of LcnCtlRefusedReasonChoiceKind.Command: "command"
  of LcnCtlRefusedReasonChoiceKind.Protocol: "protocol"
  of LcnCtlRefusedReasonChoiceKind.Too_large: "too-large"

func methodName*(m: LcnCtlMethodKind): string =
  ## The Runtime Control method's bare name.
  case m
  of LcnCtlMethodKind.Apply_configuration: "apply_configuration"
  of LcnCtlMethodKind.Create_module: "create_module"
  of LcnCtlMethodKind.Get_configuration: "get_configuration"
  of LcnCtlMethodKind.Get_configuration_schema: "get_configuration_schema"
  of LcnCtlMethodKind.Get_configuration_summary: "get_configuration_summary"
  of LcnCtlMethodKind.Get_execution_summary: "get_execution_summary"
  of LcnCtlMethodKind.Get_permission_settings: "get_permission_settings"
  of LcnCtlMethodKind.Get_readiness: "get_readiness"
  of LcnCtlMethodKind.Get_self: "get_self"
  of LcnCtlMethodKind.List_modules: "list_modules"
  of LcnCtlMethodKind.List_routes: "list_routes"
  of LcnCtlMethodKind.Recover_module: "recover_module"
  of LcnCtlMethodKind.Retire_module: "retire_module"
  of LcnCtlMethodKind.Shutdown_runtime: "shutdown_runtime"
  of LcnCtlMethodKind.Start_module: "start_module"
  of LcnCtlMethodKind.Stop_module: "stop_module"
  of LcnCtlMethodKind.Update_configuration: "update_configuration"

func methodOf*(name: string): Opt[LcnCtlMethodKind] =
  for m in LcnCtlMethodKind:
    if methodName(m) == name:
      return Opt.some(m)
  Opt.none(LcnCtlMethodKind)

func infoMessage*(): LcnCtlMessage =
  LcnCtlMessage(
    command: LcnCtlCommand(
      kind: LcnCtlCommandKind.lcn_Ctl_info_command,
      arm_lcn_Ctl_info_command: LcnCtlInfoCommand(),
    )
  )

func rcMessage*(
    m: LcnCtlMethodKind, params: seq[byte], deadlineMs = Opt.none(uint32)
): LcnCtlMessage =
  LcnCtlMessage(
    command: LcnCtlCommand(
      kind: LcnCtlCommandKind.lcn_Ctl_rc_command,
      arm_lcn_Ctl_rc_command: LcnCtlRcCommand(
        `method`: LcnCtlMethod(kind: m), params: params, deadline_ms: deadlineMs
      ),
    )
  )

func okReply*(production: bool, value: Opt[seq[byte]]): LcnCtlReply =
  LcnCtlReply(
    deployment: deploymentOf(production),
    outcome: LcnCtlOutcome(
      kind: LcnCtlOutcomeKind.lcn_Ctl_ok, arm_lcn_Ctl_ok: LcnCtlOk(result: value)
    ),
  )

func rcErrorReply*(
    production: bool, code: uint8, message: Opt[string], detail: Opt[seq[byte]]
): LcnCtlReply =
  LcnCtlReply(
    deployment: deploymentOf(production),
    outcome: LcnCtlOutcome(
      kind: LcnCtlOutcomeKind.lcn_Ctl_rc_error,
      arm_lcn_Ctl_rc_error: LcnCtlRcError(code: code, message: message, detail: detail),
    ),
  )

func refusedReply*(
    production: bool, reason: LcnCtlRefusedReasonChoiceKind, message = ""
): LcnCtlReply =
  LcnCtlReply(
    deployment: deploymentOf(production),
    outcome: LcnCtlOutcome(
      kind: LcnCtlOutcomeKind.lcn_Ctl_refused,
      arm_lcn_Ctl_refused: LcnCtlRefused(
        reason: LcnCtlRefusedReasonChoice(kind: reason),
        message: (if message.len > 0: Opt.some(message)
        else: Opt.none(string)),
      ),
    ),
  )

type MessageError* = object ## Why a frame is not a command the module runs.
  reason*: LcnCtlRefusedReasonChoiceKind ## `protocol` or `command`
  message*: string

proc decodeMessage*(bytes: openArray[byte]): Result[LcnCtlMessage, MessageError] =
  ## [G296] A frame the module accepts: deterministic CBOR naming this
  ## protocol (else `protocol`), and a command of the closed set (else
  ## `command`).
  let v = decodeCbor(bytes).valueOr:
    return err(
      MessageError(reason: LcnCtlRefusedReasonChoiceKind.Protocol, message: error.msg)
    )
  if v.kind != ckMap:
    return err(
      MessageError(
        reason: LcnCtlRefusedReasonChoiceKind.Protocol, message: "not a CBOR map"
      )
    )
  let p = v.lookup("protocol")
  if p.isNone or p.get.kind != ckText or p.get.text != CtlProtocol:
    return err(
      MessageError(
        reason: LcnCtlRefusedReasonChoiceKind.Protocol,
        message: "not a " & CtlProtocol & " message",
      )
    )
  let m = LcnCtlMessage.fromCbor(v).valueOr:
    return
      err(MessageError(reason: LcnCtlRefusedReasonChoiceKind.Command, message: error))
  ok(m)

# The shell's side ------------------------------------------------------------------

proc peerOf*(fd: cint): Result[Peer, string] =
  let c = ?peerCred(fd)
  ok(Peer(uid: c.uid, pid: c.pid))

type CredFn* = proc(fd: cint): Result[Peer, string] {.nimcall, gcsafe, raises: [].}
  ## Reads a connected peer's credentials; tests inject another.

proc connectCtl*(
    path: string, timeoutMs: int, credOf: CredFn = peerOf
): Result[cint, string] =
  ## [K20; P6-11] Connects to the socket at `path` and checks, before anything
  ## is sent, that the listener belongs to this user.
  when defined(posix):
    if not fitsSunPath(path):
      return err(path & " does not fit sun_path")
    let fd = unixSocket()
    if fd < 0:
      return err("socket: " & $strerror(cint(-fd)))
    let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
    let c = sockConnect(fd, cstring(path))
    if c < 0:
      if -c == sock.EINPROGRESS or wouldBlock(c):
        let ready = waitFd(fd, POLLOUT, deadline).valueOr:
          discard fdClose(fd)
          return err(error)
        let r = connectResult(fd)
        if not ready or r < 0:
          discard fdClose(fd)
          return
            err(path & ": " & (if ready: $strerror(cint(-r))
              else: "connect timed out"))
      else:
        discard fdClose(fd)
        return err(path & ": " & $strerror(cint(-c)))
    let peer = credOf(fd).valueOr:
      discard fdClose(fd)
      return err(path & ": " & error)
    if peer.uid != effectiveUid():
      discard fdClose(fd)
      return err(
        path & " is served by uid " & $peer.uid & ", not this user (uid " &
          $effectiveUid() & "); nothing was sent"
      )
    ok(fd)
  else:
    err("logosctl's socket is not supported on this platform")

proc roundTrip*(
    fd: cint, m: LcnCtlMessage, timeoutMs: int
): Result[LcnCtlReply, string] =
  ## One message and its reply. A refusal written as the connection was
  ## accepted (busy, closing) is read even when the write failed.
  let bytes = ?m.encode
  let wrote = writeFrame(fd, bytes, timeoutMs)
  let r = readFrame(fd, if wrote.isOk: timeoutMs else: 1000).valueOr:
    if wrote.isErr:
      return err(wrote.error)
    case error.kind
    of feEof, fePartial:
      return err("the daemon closed the connection")
    of feTimeout:
      return err("no reply within " & $timeoutMs & " ms")
    else:
      return err(error.message)
  LcnCtlReply.decode(r)

proc closeFd*(fd: cint) =
  if fd >= 0:
    discard fdClose(fd)

{.pop.}
