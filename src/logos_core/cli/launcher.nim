## The CLI's launcher (Tier 5 step N-2; DECISIONS G344, G349; BOOTSTRAP
## l.384-390): logosctl's side of `call`, `describe`, `subscribe` and
## `events`. docs/DAEMON.md §7a.
##
## The launcher hands its terminal to the lcn_call instance and names the
## command; it holds no binding, ticket or route, and no payload passes
## through it or logosd.
##
## - **Connect.** To lcn_call's socket, checking the listener's uid before
##   anything is sent (`connectCtl`).
## - **Activate** (G344). When the socket is absent or refuses, through the
##   logosctl instance: `list_modules {module: "lcn_call"}` names its record;
##   `unloaded` → `start_module`, `error` → `recover_module` with the execution
##   revision, `loaded` or `stopping` → wait, `ready` → the socket again; with
##   backoff (20 to 500 ms) until the timeout. No record: this logosd has no
##   CLI module.
## - **Send.** One request, its descriptors (stdout, stderr, each `@FILE`) on
##   the frame's first byte. `busy` is retried until the timeout.
## - **Wait.** For `done`, with no deadline of its own: the command has its
##   (`deadline_ms`), a stream none. A readable `cancelFd` (SIGINT or SIGTERM)
##   half-closes the connection, which cancels the command; lcn_call answers
##   130. A connection that ends with no `done` leaves the outcome unknown (2).

{.push raises: [], gcsafe.}

import std/[monotimes, os, strutils, times]
import results
import logos_sdk/iface/outcome
import logos_sdk/kit/rc_types
import ../daemon/[ctl_types, ctlwire]
import ./[cli_types, wire]

when defined(posix):
  import std/posix except Stat

export results

const
  CliModule = "lcn_call"
  CancelGraceMs* = 10_000 ## [IMPL] the wait for `done` after a cancel

type
  Launch* = object ## One command to hand over.
    cliSocket*: string ## lcn_call's socket
    ctlSocket*: string ## the logosctl instance's, for activation
    message*: LcnCliMessage ## `fds` is filled in from the descriptors below
    stdoutFd*, stderrFd*: cint
    files*: seq[cint] ## one per `@FILE` argument, at indices 2, 3, …
    timeoutMs*: int ## connection, activation and busy retries
    cancelFd*: cint ## readable: the user interrupted; -1: none
    credOf*: CredFn ## the listener's credentials; nil: `peerOf`

  LaunchFailure* = object ## What the launcher prints itself.
    exit*: int
    code*: string
    message*: string

func failure(exit: int, message: string, code = ""): LaunchFailure =
  LaunchFailure(exit: exit, code: code, message: message)

proc left(deadline: MonoTime): int =
  max(1, int(inMilliseconds(deadline - getMonoTime())))

proc pause(ms: var int, deadline: MonoTime): bool =
  ## Sleeps `ms` (then doubles it, at most 500) unless that passes the deadline.
  if getMonoTime() + initDuration(milliseconds = ms) >= deadline:
    return false
  sleep(ms)
  ms = min(ms * 2, 500)
  true

proc connectCli(l: Launch, deadline: MonoTime): Result[cint, string] =
  let cred = if l.credOf.isNil: peerOf else: l.credOf
  connectCtl(l.cliSocket, min(left(deadline), l.timeoutMs), cred)

# Activation (G344) ---------------------------------------------------------------------

proc ctlCall[Req, Resp](
    l: Launch, m: LcnCtlMethodKind, req: Req, resp: typedesc[Resp], deadline: MonoTime
): Result[Resp, LaunchFailure] =
  ## One Runtime Control call through the logosctl instance.
  let params = req.encode.valueOr:
    return err(failure(ExitRefused, "the request has no encoding: " & error))
  let cred = if l.credOf.isNil: peerOf else: l.credOf
  let fd = connectCtl(l.ctlSocket, left(deadline), cred).valueOr:
    return err(failure(ExitUnreachable, "no daemon: " & error))
  defer:
    closeFd(fd)
  let ms = min(left(deadline), 60_000)
  let r = roundTrip(fd, rcMessage(m, params, Opt.some(uint32(ms))), ms).valueOr:
    return err(failure(ExitUnreachable, "the daemon: " & error))
  case r.outcome.kind
  of LcnCtlOutcomeKind.lcn_Ctl_ok:
    let v = Resp.decode(r.outcome.arm_lcn_Ctl_ok.result.get(@[])).valueOr:
      return err(failure(ExitRc, "the response does not decode: " & error, $ecModule))
    ok(v)
  of LcnCtlOutcomeKind.lcn_Ctl_rc_error:
    let e = r.outcome.arm_lcn_Ctl_rc_error
    err(failure(ExitRc, e.message.get(""), $errorCode(int64(e.code)).get(ecModule)))
  of LcnCtlOutcomeKind.lcn_Ctl_refused:
    let e = r.outcome.arm_lcn_Ctl_refused
    err(
      failure(
        ExitUnreachable,
        "the daemon refused (" & reasonOf(e.reason.kind) & ")" &
          (if e.message.isSome: ": " & e.message.get else: ""),
      )
    )

proc record(
    l: Launch, deadline: MonoTime
): Result[LogosNSRuntimeControlModuleRecord, LaunchFailure] =
  let r = ?l.ctlCall(
    LcnCtlMethodKind.List_modules,
    LogosNSRuntimeControlListModulesRequest(module: Opt.some(CliModule)),
    LogosNSRuntimeControlListModulesResponse,
    deadline,
  )
  for m in r.modules:
    if m.module == CliModule and m.instance == Opt.some(CliModule):
      return ok(m)
  err(failure(ExitUnreachable, "this logosd has no CLI module (lcn_call)"))

proc activate(l: Launch, deadline: MonoTime): Result[cint, LaunchFailure] =
  ## [G344] Starts or recovers lcn_call through the logosctl instance, then
  ## connects to its socket.
  var ms = 20
  var acted = false
  var lastError = ""
  while true:
    let fd = l.connectCli(deadline)
    if fd.isOk:
      return ok(fd.get)
    lastError = fd.error
    let rec = ?l.record(deadline)
    case rec.state.kind
    of LogosNSRuntimeControlStateKind.Unloaded:
      if not acted:
        acted = true
        discard ?l.ctlCall(
          LcnCtlMethodKind.Start_module,
          LogosNSRuntimeControlStartModuleRequest(
            module: CliModule, instance: Opt.some(CliModule)
          ),
          LogosNSRuntimeControlStartModuleResponse,
          deadline,
        )
    of LogosNSRuntimeControlStateKind.Error:
      if acted:
        # Started or recovered here and failed: the Loader's classification.
        return err(
          failure(
            ExitRc,
            "lcn_call did not start" &
              (if rec.reason.isSome: ": " & rec.reason.get else: ""),
            rec.failure.get($ecNotReady),
          )
        )
      if rec.execution.isNone:
        return err(failure(ExitRc, "lcn_call failed and has no execution revision"))
      acted = true
      discard ?l.ctlCall(
        LcnCtlMethodKind.Recover_module,
        LogosNSRuntimeControlRecoverModuleRequest(
          module: CliModule,
          instance: CliModule,
          expected_execution_revision: rec.execution.get.revision,
        ),
        LogosNSRuntimeControlRecoverModuleResponse,
        deadline,
      )
    of LogosNSRuntimeControlStateKind.Loaded, LogosNSRuntimeControlStateKind.Stopping,
        LogosNSRuntimeControlStateKind.Ready:
      discard
    if not pause(ms, deadline):
      return err(
        failure(
          ExitUnreachable,
          "lcn_call is not reachable within the timeout (" & lastError & ")",
        )
      )

# The command ----------------------------------------------------------------------------

proc waitDone(fd, cancelFd: cint): Result[int, LaunchFailure] =
  ## [G344] `done`, or the half-close on a cancel.
  when defined(posix):
    var cancelled = false
    var until = MonoTime()
    while true:
      var p: array[2, TPollfd]
      p[0] = TPollfd(fd: fd, events: POLLIN)
      p[1] = TPollfd(fd: cancelFd, events: POLLIN)
      let watch = not cancelled and cancelFd >= 0
      let timeout =
        if cancelled:
          cint(max(0, int(inMilliseconds(until - getMonoTime()))))
        else:
          cint(-1)
      let n = poll(addr p[0], Tnfds(if watch: 2 else: 1), timeout)
      if n < 0:
        if errno == EINTR:
          continue
        return err(failure(ExitUnreachable, "poll: " & $strerror(errno)))
      if n == 0 and cancelled:
        return ok(ExitInterrupted) # lcn_call did not answer the cancel in time
      if watch and p[1].revents != 0:
        cancelled = true
        until = getMonoTime() + initDuration(milliseconds = CancelGraceMs)
        discard shutdown(SocketHandle(fd), SHUT_WR)
        continue
      if p[0].revents != 0:
        let r = readReply(fd, 1_000).valueOr:
          if cancelled:
            return ok(ExitInterrupted)
          return err(
            failure(
              ExitUnreachable,
              "the outcome is unknown: lcn_call ended the connection without an answer (" &
                error.message & ")",
            )
          )
        case r.outcome.kind
        of LcnCliOutcomeKind.lcn_Cli_done:
          return ok(int(r.outcome.arm_lcn_Cli_done.exit))
        else:
          return err(failure(ExitUnreachable, "the outcome is unknown: a second reply"))
  else:
    err(failure(ExitUnreachable, "not supported on this platform"))

proc launch*(l: Launch): Result[int, LaunchFailure] =
  ## [G344] Hands the command over and returns its exit code; a failure the
  ## launcher prints itself is an error.
  var msg = l.message
  var fds = @[l.stdoutFd, l.stderrFd]
  msg.fds = @[role(LcnCliFdRoleKind.Stdout), role(LcnCliFdRoleKind.Stderr)]
  for f in l.files:
    fds.add(f)
    msg.fds.add(role(LcnCliFdRoleKind.File))
  if fds.len > MaxFds:
    return err(failure(ExitRefused, "at most " & $(MaxFds - 2) & " @FILE arguments"))
  let bytes = msg.encode.valueOr:
    return err(failure(ExitRefused, error))
  let deadline = getMonoTime() + initDuration(milliseconds = l.timeoutMs)
  var ms = 20
  while true:
    let fd = ?l.activate(deadline)
    let wrote = writeRequest(fd, bytes, fds, left(deadline))
    let reply = readReply(
      fd,
      if wrote.isOk:
        left(deadline)
      else:
        1_000,
    )
    if reply.isErr:
      closeFd(fd)
      return err(
        failure(
          ExitUnreachable,
          "lcn_call did not take the command: " &
            (if wrote.isErr: wrote.error else: reply.error.message),
        )
      )
    let r = reply.get
    case r.outcome.kind
    of LcnCliOutcomeKind.lcn_Cli_accepted:
      defer:
        closeFd(fd)
      return waitDone(fd, l.cancelFd)
    of LcnCliOutcomeKind.lcn_Cli_done:
      closeFd(fd)
      return err(failure(ExitUnreachable, "lcn_call answered done before accepting"))
    of LcnCliOutcomeKind.lcn_Cli_refused:
      closeFd(fd)
      let e = r.outcome.arm_lcn_Cli_refused
      let text =
        "lcn_call refused (" & reasonText(e.reason.kind) & ")" &
        (if e.message.isSome: ": " & e.message.get else: "")
      case e.reason.kind
      of LcnCliRefusedReasonChoiceKind.Busy:
        if not pause(ms, deadline):
          return err(failure(ExitUnreachable, text & " until the timeout"))
      of LcnCliRefusedReasonChoiceKind.Closing:
        return err(failure(ExitUnreachable, text))
      else:
        return err(failure(ExitRefused, text))

{.pop.}
