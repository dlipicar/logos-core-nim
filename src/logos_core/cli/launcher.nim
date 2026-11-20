## The CLI's launcher (Tier 5 step N-2; DECISIONS G344, G349; BOOTSTRAP
## l.389-395): logosctl's side of `call`, `describe`, `subscribe` and
## `events`. docs/DAEMON.md §7a.
##
## The launcher hands its terminal to the lcn_call instance and names the
## command; it holds no binding, ticket or route, and no payload passes
## through it or logosd.
##
## - **Connect.** To lcn_call's socket, checking the listener's uid before
##   anything is sent (`connectCtl`).
## - **Activate** (G344; plan §3.3). When the socket is absent or refuses,
##   through the logosctl instance: `list_modules {module: "lcn_call"}` names
##   its record, read again on every round:
##   - `unloaded` → `start_module`;
##   - `error` (`host-terminated` after an unclean end too, R l.3634) with
##     `requested` intent → `recover_module` with the execution revision; with
##     any other intent → `start_module` (R l.3512; recovery would be refused,
##     R l.3403);
##   - `loaded` or `stopping` → wait; `ready` → the socket again;
##   - NOT_READY from either request (cleanup unresolved, R l.578) → read
##     again; an `error` arm `stale-revision` (R l.1819) → read again; any
##     other `error` arm → 4;
##   - an attempt that this launcher's request began and that failed (a later
##     execution revision in `error`) → 4 with its classification.
##   It acts again whenever the record is `unloaded` or `error` again, with
##   backoff (20 to 500 ms) until the timeout, then 2 naming the last state
##   read; a readable `cancelFd` during a backoff is 130. It does not depend
##   on when `start_module` answers (TF-20): it waits for the socket. No
##   record: this logosd has no CLI module.
## - **Send.** One request, its descriptors (stdout, stderr, each `@FILE`) on
##   the frame's first byte; `deadline_ms` is what remains of the timeout
##   after activation. `busy` is retried until the timeout; `closing` goes
##   through activation again.
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
    cancelFd*: cint
      ## readable: the user interrupted (130 before the command is taken, the
      ## half-close after); -1: none
    credOf*: CredFn ## the listener's credentials; nil: `peerOf`

  LaunchFailure* = object ## What the launcher prints itself.
    exit*: int
    code*: string
    message*: string

func failure(exit: int, message: string, code = ""): LaunchFailure =
  LaunchFailure(exit: exit, code: code, message: message)

proc left(deadline: MonoTime): int =
  max(1, int(inMilliseconds(deadline - getMonoTime())))

type Paused = enum
  psSlept
  psDeadline ## the pause would pass the deadline
  psCancelled ## `cancelFd` is readable: the user interrupted

proc pause(ms: var int, deadline: MonoTime, cancelFd: cint): Paused =
  ## Waits `ms` (then doubles it, at most 500) unless that passes the
  ## deadline; a readable `cancelFd` ends the wait.
  if getMonoTime() + initDuration(milliseconds = ms) >= deadline:
    return psDeadline
  when defined(posix):
    if cancelFd >= 0:
      let until = getMonoTime() + initDuration(milliseconds = ms)
      ms = min(ms * 2, 500)
      while true:
        let wait = int(inMilliseconds(until - getMonoTime()))
        if wait <= 0:
          return psSlept
        var p = TPollfd(fd: cancelFd, events: POLLIN)
        let n = poll(addr p, 1, cint(wait))
        if n > 0:
          return psCancelled
        if n == 0 or errno != EINTR:
          return psSlept
  sleep(ms)
  ms = min(ms * 2, 500)
  psSlept

func interrupted(): LaunchFailure =
  failure(ExitInterrupted, "interrupted")

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

func revisionOf(rec: LogosNSRuntimeControlModuleRecord): uint64 =
  if rec.execution.isSome: rec.execution.get.revision else: 0

func errorText*(e: LogosNSRuntimeControlError): string =
  case e.code.kind
  of LogosNSRuntimeControlErrorCodeKind.Configuration_rejected:
    "configuration-rejected"
  of LogosNSRuntimeControlErrorCodeKind.Declaration_unavailable:
    "declaration-unavailable"
  of LogosNSRuntimeControlErrorCodeKind.Stale_revision:
    "stale-revision"

type
  ActKind* = enum
    akWait ## `loaded`, `stopping` or `ready`: read the record again later
    akStart ## `start_module`
    akRecover ## `recover_module` with `Act.revision`
    akFailed ## an attempt begun since this launcher's request failed: 4

  Act* = object
    kind*: ActKind
    revision*: uint64 ## the record's execution revision

  Answer* = enum
    anAccepted ## the Runtime accepted the request
    anReread ## read the record again (NOT_READY, R l.578; `stale-revision`, R l.1819)
    anFault ## any other answer: 4

func nextAct*(rec: LogosNSRuntimeControlModuleRecord, acted: Opt[uint64]): Act =
  ## [G344; plan §3.3] What the launcher does for the record it read. `acted`
  ## is the execution revision the record had when a request of this launcher
  ## was last accepted: an `error` at another revision is an attempt begun
  ## since, which failed.
  let rev = rec.revisionOf
  case rec.state.kind
  of LogosNSRuntimeControlStateKind.Loaded, LogosNSRuntimeControlStateKind.Stopping,
      LogosNSRuntimeControlStateKind.Ready:
    Act(kind: akWait, revision: rev)
  of LogosNSRuntimeControlStateKind.Unloaded:
    Act(kind: akStart, revision: rev)
  of LogosNSRuntimeControlStateKind.Error:
    if acted.isSome and rev != acted.get:
      Act(kind: akFailed, revision: rev)
    elif rec.execution.isSome and
        rec.execution.get.intent.kind ==
        LogosNSRuntimeControlExecutionStateIntentChoiceKind.Requested:
      # [R l.3403] Recovery needs `requested` intent; `host-terminated` after
      # an unclean end (R l.3634) is recovered here.
      Act(kind: akRecover, revision: rev)
    else:
      # [R l.3512] An explicit stop that a cleanup failure or an unclean end
      # interrupted (R l.577, l.1735): a start establishes `requested` intent.
      Act(kind: akStart, revision: rev)

func answerOf*(code: string): Answer =
  ## A start or recovery the Runtime refused with an invocation error.
  if code == $ecNotReady: anReread else: anFault

func answerOf*(e: LogosNSRuntimeControlError): Answer =
  ## A start or recovery answered with its `error` arm.
  if e.code.kind == LogosNSRuntimeControlErrorCodeKind.Stale_revision:
    anReread
  else:
    anFault

proc lifecycle(l: Launch, act: Act, deadline: MonoTime): Result[bool, LaunchFailure] =
  ## [G344; plan §3.3] One start or recovery: true when the Runtime accepted
  ## it, false when the record is to be read again.
  template answered(r: untyped, errKind: untyped): untyped =
    if r.isErr:
      if answerOf(r.error.code) == anReread:
        return ok(false)
      return err(r.error)
    if r.get.kind == errKind:
      let e = r.get.arm_Map_error.error
      if answerOf(e) == anReread:
        return ok(false)
      return err(
        failure(ExitRc, "lcn_call's activation answered " & e.errorText, e.errorText)
      )
    return ok(true)

  if act.kind == akRecover:
    let r = l.ctlCall(
      LcnCtlMethodKind.Recover_module,
      LogosNSRuntimeControlRecoverModuleRequest(
        module: CliModule,
        instance: CliModule,
        expected_execution_revision: act.revision,
      ),
      LogosNSRuntimeControlRecoverModuleResponse,
      deadline,
    )
    answered(r, LogosNSRuntimeControlRecoverModuleResponseKind.Map_error)
  else:
    let r = l.ctlCall(
      LcnCtlMethodKind.Start_module,
      LogosNSRuntimeControlStartModuleRequest(
        module: CliModule, instance: Opt.some(CliModule)
      ),
      LogosNSRuntimeControlStartModuleResponse,
      deadline,
    )
    answered(r, LogosNSRuntimeControlStartModuleResponseKind.Map_error)

proc activate(l: Launch, deadline: MonoTime): Result[cint, LaunchFailure] =
  ## [G344; plan §3.3] Starts or recovers lcn_call through the logosctl
  ## instance until its socket answers.
  var ms = 20
  var acted = Opt.none(uint64)
  var lastError, lastState = ""
  while true:
    let fd = l.connectCli(deadline)
    if fd.isOk:
      return ok(fd.get)
    lastError = fd.error
    let rec = ?l.record(deadline)
    lastState = ($rec.state.kind).toLowerAscii
    let act = nextAct(rec, acted)
    case act.kind
    of akWait:
      discard
    of akFailed:
      # The Loader's classification of the attempt.
      return err(
        failure(
          ExitRc,
          "lcn_call did not start" &
            (if rec.reason.isSome: ": " & rec.reason.get else: ""),
          rec.failure.get($ecNotReady),
        )
      )
    of akStart, akRecover:
      if ?l.lifecycle(act, deadline):
        acted = Opt.some(act.revision)
    case pause(ms, deadline, l.cancelFd)
    of psSlept:
      discard
    of psCancelled:
      return err(interrupted())
    of psDeadline:
      return err(
        failure(
          ExitUnreachable,
          "lcn_call is not reachable within the timeout (last state " & lastState & "; " &
            lastError & ")",
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
  let deadline = getMonoTime() + initDuration(milliseconds = l.timeoutMs)
  var ms = 20
  while true:
    let fd = ?l.activate(deadline)
    if l.message.deadline_ms.isSome:
      # [G344; plan §3.3] What remains of the timeout after activation.
      msg.deadline_ms =
        Opt.some(uint32(min(int64(l.message.deadline_ms.get), int64(left(deadline)))))
    let bytes = msg.encode.valueOr:
      closeFd(fd)
      return err(failure(ExitRefused, error))
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
      of LcnCliRefusedReasonChoiceKind.Busy, LcnCliRefusedReasonChoiceKind.Closing:
        # [G344; plan §3.3] `busy` is retried; `closing` goes through
        # activation again: wait on `stopping`, start from `unloaded`.
        case pause(ms, deadline, l.cancelFd)
        of psSlept:
          discard
        of psCancelled:
          return err(interrupted())
        of psDeadline:
          return err(failure(ExitUnreachable, text & " until the timeout"))
      else:
        return err(failure(ExitRefused, text))

{.pop.}
