## logosctl: the client of logosd's logosctl instance, and the owner's offline
## tool for a session (Tier 4b step 4b-6; DECISIONS G88, G89, D26; decision
## 9). docs/DAEMON.md §7, §8.
##
##   logosctl [--session-dir DIR] [--json | --text] [--timeout MS] <command> …
##
## [G89] Output is JSON with `--json`, or when stdout is not a terminal;
## `--text` [IMPL] keeps text output in a pipe.
## Online commands go through the socket: each is one or more Runtime Control
## calls the logosctl instance makes through its own binding. The shell
## encodes their requests with the generated `rc_types` codecs (D26) and
## renders the responses' CBOR (G89). Offline commands read the session, and
## those that write hold its lock, so they are refused while logosd runs.
## Policy, grants and trust change through no online command (BOOTSTRAP
## l.380-382): only the owner's files, offline. `audit evidence` reads the
## call-evidence store and exports a record as call evidence, offline and
## read-only, while logosd runs or not (G301; DAEMON.md §9). `state list` and
## `state purge` read the Runtime's store under the session's lock and then
## the store's; a purge removes a retired instance's preserved state (G143,
## I96 part 7c; DAEMON.md §11).
##
## `call` and `describe` are not logosctl instance commands: the shell is the
## CLI module's launcher (Tier 5 step N-2b; G344, G349; DAEMON.md §7a). It
## hands its stdout, stderr and each `@FILE` to the `lcn_call` instance, which
## makes the calls through its own binding and writes the result to them; no
## argument, response or event passes through logosd. The launcher starts
## `lcn_call` through the logosctl instance when its socket does not answer.
## SIGINT or SIGTERM cancels the command; a second one ends the shell at once.
##
## | Exit | Meaning |
## |---|---|
## | 0 | done |
## | 1 | usage, a refused frame or command, an offline command that failed |
## | 2 | no daemon, busy, or the outcome unknown |
## | 4 | the Runtime Control call failed: its code and message |
## | 5 | `call`: the provider's error channel answered (G349) |
## | 6 | a stream `lcn_call` ended (N-2c) |
## | 130 | interrupted |

{.push raises: [].}

import std/[json, os, parseopt, sets, strutils, sysrand, tables]
import results
import ./logos_core/daemon/version

proc say(text: string) =
  try:
    stderr.writeLine(text)
  except IOError:
    discard

proc show(text: string) =
  try:
    stdout.writeLine(text)
  except IOError:
    discard

when defined(posix):
  import std/[monotimes, posix, times]
  import logos_sdk/base/hex
  import logos_sdk/cbor
  import ./logos_core/durable
  import logos_sdk/iface/outcome
  import logos_sdk/kit/[rc_arms, rc_types], ./logos_core/runtime/stateadmin
  import
    ./logos_core/daemon/[
      compose, credential, ctlwire, evexport, evkey, evstore, remoteexposure,
      remotetrust, render, session, sessioninit, signsvc, trustfile,
    ]
  import ./logos_core/cli/[cli_types, launcher]
  from logos_sdk/codegen/nimrt import wipeTyped

  const
    Usage =
      """usage: logosctl [--session-dir DIR] [--json | --text] [--timeout MS] <command> ...

online (through logosd's socket):
  status
  module ls [--module M]
  module status MODULE [--instance I]
  module wait MODULE [--instance I] [--state unloaded|loaded|ready|stopping]
  module summary INSTANCE
  module create MODULE [--request-key K]
  module start|stop MODULE [--instance I] [--if-revision N]
  module recover|retire INSTANCE [--revision N]
  route ls [--module M]
  permissions get INSTANCE
  config schema|summary|get INSTANCE
  config stage INSTANCE @VALUE [--revision N --schema HEX]
  config discard INSTANCE [--revision N --schema HEX]
  config apply INSTANCE [--revision N]
  daemon stop [--wait]

online, through the lcn_call instance (it writes the result itself):
  call MODULE METHOD [NAME=VALUE | NAME=@FILE | NAME=@-]... [--request JSON]
       [--instance I] [--contract ROOT] [--node NAME]
  describe MODULE [--instance I] [--contract ROOT] [--node NAME]
  subscribe MODULE EVENT [--count N] [--for DURATION]
       [--instance I] [--contract ROOT] [--node NAME]
  events [NAME]... [--count N] [--for DURATION] [--node NAME]

offline (the session's files; writers hold its lock):
  init [--config @FILE] [--policy @FILE] [--module-config INSTANCE=@FILE]... [--development]
  init --print-template
  daemon config get [--format diag|cbor] [--out FILE]
  daemon config check [@FILE]
  daemon config set @FILE
  daemon config module-config INSTANCE (@FILE | --remove)
  trust show
  trust anchor add --kid KID --key HEX|@FILE [--development] NAME...
  trust anchor remove --kid KID
  trust anchor add-names|remove-names --kid KID NAME...
  trust development on|off
  trust reestablish --revision N
  trust evidence-keys ls|rotate
  remote trust init
  remote trust show
  remote trust reestablish --revision N
  remote trust anchor add CERT [--id HEX]
  remote trust anchor remove --id HEX
  remote trust enroll add @RECORD
  remote trust enroll revoke RUNTIME [--profile tls-tcp|quic]
  remote trust import @PEER
  remote credential new [--days N]
  remote credential show
  remote credential rotate [--days N]
  remote exposure list
  remote exposure reset (--listener ADDR [--provider ID] | --all)
  audit evidence ls
  audit evidence export --seq N [--out FILE]
  state list
  state purge INSTANCE [--yes]
  state purge --assignment A [--yes]
  version

KID is text, or hex: and hex digits, as lcn-pkg sign --kid takes it; HEX is the
public key's 96 hex digits, or @FILE holding them (lcn-pkg keygen's line too).
remote trust: CERT is a DER certificate file, the anchor's id its BLAKE3-256
unless --id names one; @RECORD is one logos.runtime_enrollment
remote_runtime_enrollment and @PEER a logos-core-nim.remote-peer.v1 file, each
.cbor or .diag. Every change applies at the next start of logosd.
remote credential: this Runtime's TLS key and self-signed certificate (valid
--days, default 3650), and peer.cbor, the anchor and enrollment each peer
imports; rotate writes the next one, taken up at the next start of logosd
with remote.enabled (a cutover).
remote exposure: the listener and export fields Runtime Control turned off,
which stay off across restarts until the configuration entry changes, Runtime
Control enables them, or reset removes them (at the next start). ADDR is the
address as list prints it, quoted (\"tls-tcp HOST:PORT\" and its optional
fields); --provider names an export of that listener."""
    DefaultTimeoutMs = 65_000
    ExitOk = 0
    ExitUsage = 1
    ExitUnreachable = 2
    ExitRc = 4
    ExitInterrupted = 130
    MaxFileArgs = 14 ## [G344] 16 descriptors, stdout and stderr included
    NoValue = [
      "json", "text", "wait", "development", "remove", "print-template", "help",
      "version", "yes", "all",
    ]

  type
    Cli = object
      sessionFlag: string
      json: bool
      timeoutMs: int
      args: seq[string]
      opts: Table[string, seq[string]]
      flags: HashSet[string]

    Fail = object
      exit: int
      code: string
      message: string
      requestKey: string
      result: JsonNode ## the response, for a typed refusal (`--json`)

    Done = object
      deployment: string
      command: string
      requestKey: string
      result: JsonNode
      text: string
      raw: bool ## the bytes went to stdout themselves: nothing else is printed

  func fail(exit: int, message: string, code = ""): Fail =
    Fail(exit: exit, message: message, code: code)

  func usage(message: string): Fail =
    fail(ExitUsage, message & "\n" & Usage)

  proc opt(c: Cli, name: string): Opt[string] =
    let xs = c.opts.getOrDefault(name)
    if xs.len > 0:
      return Opt.some(xs[^1])
    Opt.none(string)

  proc optAll(c: Cli, name: string): seq[string] =
    c.opts.getOrDefault(name)

  proc uintOpt(c: Cli, name: string): Result[Opt[uint64], Fail] =
    let v = c.opt(name)
    if v.isNone:
      return ok(Opt.none(uint64))
    try:
      ok(Opt.some(parseBiggestUInt(v.get).uint64))
    except ValueError:
      err(usage("--" & name & " takes a non-negative integer"))

  proc durationOpt(c: Cli, name: string): Result[Opt[uint32], Fail] =
    ## [G349] `--for`: milliseconds, or a number with `ms`, `s`, `m` or `h`.
    let v = c.opt(name)
    if v.isNone:
      return ok(Opt.none(uint32))
    var text = v.get
    var unit = 1'u64
    for (suffix, ms) in [
      ("ms", 1'u64), ("s", 1_000'u64), ("m", 60_000'u64), ("h", 3_600_000'u64)
    ]:
      if text.endsWith(suffix) and text.len > suffix.len:
        text = text[0 ..< text.len - suffix.len]
        unit = ms
        break
    var n: uint64
    try:
      n = parseBiggestUInt(text).uint64
    except ValueError:
      return err(usage("--" & name & " takes a duration such as 500ms, 30s or 2m"))
    if n == 0 or n > high(uint32).uint64 div unit:
      return err(usage("--" & name & " is 1 ms to 49 days"))
    ok(Opt.some(uint32(n * unit)))

  proc countOpt(c: Cli): Result[Opt[uint32], Fail] =
    let n = ?c.uintOpt("count")
    if n.isSome and (n.get < 1 or n.get > high(uint32).uint64):
      return err(usage("--count is 1 to " & $high(uint32)))
    ok(
      n.map(
        proc(x: uint64): uint32 =
          uint32(x)
      )
    )

  proc arg(c: Cli, i: int, what: string): Result[string, Fail] =
    if i < c.args.len:
      return ok(c.args[i])
    err(usage("missing " & what))

  # Value files ------------------------------------------------------------------------

  proc readValue(spec: string): Result[seq[byte], Fail] =
    ## [G89] `@FILE`: `.cbor` (deterministic CBOR, checked) or `.diag`
    ## (parsed, then encoded deterministically).
    if not spec.startsWith("@"):
      return err(usage("a value is given as @FILE, got " & spec))
    let path = spec[1 .. ^1]
    var text: string
    try:
      text = readFile(path)
    except IOError as e:
      return err(fail(ExitUsage, path & ": " & e.msg))
    if path.endsWith(".cbor"):
      let v = decodeCbor(text).valueOr:
        return err(fail(ExitUsage, path & " is not deterministic CBOR: " & error.msg))
      return ok(encodeCbor(v))
    if path.endsWith(".diag"):
      let v = parseDiag(text).valueOr:
        return err(fail(ExitUsage, path & ": " & error))
      # The notation can spell what the wire refuses: held to the `.cbor` rule.
      let bytes = encodeCbor(v)
      discard decodeCbor(bytes).valueOr:
        return err(fail(ExitUsage, path & " is not deterministic CBOR: " & error.msg))
      return ok(bytes)
    err(usage(path & ": a value file ends in .cbor or .diag"))

  proc writeOut(path: string, data: openArray[byte]): Result[void, Fail] =
    ## [IMPL] `--out`: a new file, 0600; an existing one is refused.
    let fd =
      posix.open(cstring(path), O_WRONLY or O_CREAT or O_EXCL or O_CLOEXEC, 0o600)
    if fd < 0:
      return err(fail(ExitUsage, path & ": " & $strerror(errno)))
    var off = 0
    while off < data.len:
      let n = posix.write(fd, unsafeAddr data[off], data.len - off)
      if n <= 0:
        discard posix.close(fd)
        return err(fail(ExitUsage, path & ": " & $strerror(errno)))
      off += n
    discard fsync(fd)
    discard posix.close(fd)
    ok()

  # Deployment -----------------------------------------------------------------------

  proc offlineDeployment(s: Session): string =
    let t = readTrust(s)
    if t.isErr:
      return "unknown"
    if t.get.file.development: "non-production" else: "production"

  # The socket ------------------------------------------------------------------------

  type Client = object
    fd: cint
    path: string
    timeoutMs: int
    deadline: MonoTime ## --timeout from the first connection: busy retries end here
    deployment: string

  proc socketOf(s: Session): string =
    let r = readDaemonConfig(s)
    if r.isOk:
      let dc = r.get[0]
      if dc.ctl.isSome and dc.ctl.get.socket_dir.isSome:
        return s.socketPath(dc.ctl.get.socket_dir.get)
    s.socketPath()

  proc connect(s: Session, c: Cli): Result[Client, Fail] =
    let path = socketOf(s)
    let fd = connectCtl(path, c.timeoutMs).valueOr:
      return err(fail(ExitUnreachable, "no daemon: " & error))
    ok(
      Client(
        fd: fd,
        path: path,
        timeoutMs: c.timeoutMs,
        deadline: getMonoTime() + initDuration(milliseconds = c.timeoutMs),
        deployment: "unknown",
      )
    )

  proc close(cl: var Client) =
    closeFd(cl.fd)
    cl.fd = -1

  func isBusy(r: LcnCtlReply): bool =
    r.outcome.kind == LcnCtlOutcomeKind.lcn_Ctl_refused and
      r.outcome.arm_lcn_Ctl_refused.reason.kind == LcnCtlRefusedReasonChoiceKind.Busy

  proc exchangeOnce(
      cl: var Client, bytes: seq[byte]
  ): Result[LcnCtlReply, (Fail, bool)] =
    ## A busy refusal is written as the connection is accepted, before the
    ## command is read, so a failed write still reads what the daemon said.
    let wrote = writeFrame(cl.fd, bytes, cl.timeoutMs)
    let frame = readFrame(cl.fd, if wrote.isOk: cl.timeoutMs else: 1000).valueOr:
      if wrote.isErr:
        return err(
          (
            fail(ExitUnreachable, "the daemon did not take the command: " & wrote.error),
            false,
          )
        )
      # [IMPL] The client's own words, as `roundTrip`'s: `readFrame`'s texts
      # are the server's ("no request before the idle timeout").
      let why =
        case error.kind
        of feTimeout:
          "no reply within " & $cl.timeoutMs & " ms"
        of feEof, fePartial:
          "no reply: the daemon closed the connection"
        else:
          "no reply: " & error.message
      return err((fail(ExitUnreachable, why), true))
    let r = LcnCtlReply.decode(frame).valueOr:
      return
        err((fail(ExitUnreachable, "the reply does not decode: " & error), wrote.isOk))
    ok(r)

  proc exchange(cl: var Client, m: LcnCtlMessage): Result[LcnCtlReply, (Fail, bool)] =
    ## One message and its reply. The flag says the message was sent, so an
    ## error leaves the outcome unknown. [IMPL] A busy refusal ran nothing:
    ## the shell connects again and retries, with backoff, until --timeout.
    let bytes = m.encode.valueOr:
      return err((fail(ExitUsage, error), false))
    var pause = 20
    while true:
      let r = ?cl.exchangeOnce(bytes)
      cl.deployment = r.deployment.deploymentText
      if not r.isBusy or
          getMonoTime() + initDuration(milliseconds = pause) >= cl.deadline:
        return ok(r)
      sleep(pause)
      pause = min(pause * 2, 500)
      closeFd(cl.fd)
      let left = max(1, inMilliseconds(cl.deadline - getMonoTime()).int)
      cl.fd = connectCtl(cl.path, min(left, cl.timeoutMs)).valueOr:
        cl.fd = -1
        return err((fail(ExitUnreachable, "no daemon: " & error), false))

  proc outcomeOf(r: LcnCtlReply): Result[seq[byte], Fail] =
    case r.outcome.kind
    of LcnCtlOutcomeKind.lcn_Ctl_ok:
      ok(r.outcome.arm_lcn_Ctl_ok.result.get(@[]))
    of LcnCtlOutcomeKind.lcn_Ctl_rc_error:
      let e = r.outcome.arm_lcn_Ctl_rc_error
      let code = errorCode(int64(e.code)).get(ecModule)
      err(fail(ExitRc, e.message.get(""), $code))
    of LcnCtlOutcomeKind.lcn_Ctl_refused:
      let e = r.outcome.arm_lcn_Ctl_refused
      let reason = reasonOf(e.reason.kind)
      let exit = if reason in ["busy", "closing"]: ExitUnreachable else: ExitUsage
      err(
        fail(
          exit,
          "refused (" & reason & ")" &
            (if e.message.isSome: ": " & e.message.get else: ""),
        )
      )

  proc call(
      cl: var Client, m: LcnCtlMethodKind, params: seq[byte]
  ): Result[seq[byte], Fail] =
    let deadline = Opt.some(uint32(min(cl.timeoutMs, 60_000)))
    let r = cl.exchange(rcMessage(m, params, deadline)).valueOr:
      return err(error[0])
    outcomeOf(r)

  proc callTyped[Req, Resp](
      cl: var Client, m: LcnCtlMethodKind, req: Req, resp: typedesc[Resp]
  ): Result[(Resp, seq[byte]), Fail] =
    let params = req.encode.valueOr:
      return err(fail(ExitUsage, "the request has no encoding: " & error))
    let bytes = ?cl.call(m, params)
    let v = Resp.decode(bytes).valueOr:
      return err(fail(ExitRc, "the response does not decode: " & error, $ecModule))
    ok((v, bytes))

  proc refusedFail(e: LogosNSRuntimeControlError, bytes: seq[byte]): Fail =
    ## [SPEC RUNTIME l.1818-1822; re-pin P4a] A response's error arm: exit 4,
    ## as any Runtime Control refusal, with the code as the schema spells it
    ## [IMPL; no exit code is defined for typed errors].
    result = fail(
      ExitRc,
      if e.current_revision.isSome:
        "current revision " & $e.current_revision.get
      else:
        "the Runtime refused the request",
      e.codeText,
    )
    result.result = jsonOfBytes(bytes)

  proc callArm[Req, Resp](
      cl: var Client, m: LcnCtlMethodKind, req: Req, resp: typedesc[Resp]
  ): Result[(Resp, seq[byte]), Fail] =
    ## `callTyped` for a response with an error arm (`kit/rc_arms`): the
    ## error arm is a failure, so the result arm is there.
    let (x, bytes) = ?cl.callTyped(m, req, resp)
    let e = x.refusal
    if e.isSome:
      return err(refusedFail(e.get, bytes))
    ok((x, bytes))

  proc info(cl: var Client): Result[LcnCtlDaemonInfo, Fail] =
    let r = cl.exchange(infoMessage()).valueOr:
      return err(error[0])
    let bytes = ?outcomeOf(r)
    LcnCtlDaemonInfo.decode(bytes).mapErr(
      proc(e: string): Fail =
        fail(ExitRc, "daemon-info does not decode: " & e, $ecModule)
    )

  proc target(
      cl: var Client, instance: string
  ): Result[LogosNSRuntimeModuleInstanceAddress, Fail] =
    let i = ?cl.info()
    ok(
      LogosNSRuntimeModuleInstanceAddress(
        module_instance_id: instance, runtime_instance_id: i.runtime_instance_id
      )
    )

  proc listModules(
      cl: var Client, module, instance: Opt[string]
  ): Result[seq[LogosNSRuntimeControlModuleRecord], Fail] =
    var all: seq[LogosNSRuntimeControlModuleRecord]
    var cursor = Opt.none(LogosNSRuntimeControlCursor)
    while true:
      let req = LogosNSRuntimeControlListModulesRequest(
        cursor: cursor, module: module, instance: instance
      )
      let (r, _) = ?cl.callTyped(
        LcnCtlMethodKind.List_modules, req, LogosNSRuntimeControlListModulesResponse
      )
      all.add(r.modules)
      if r.next_cursor.isNone:
        break
      cursor = r.next_cursor
    ok(all)

  proc recordsJson(xs: seq[LogosNSRuntimeControlModuleRecord]): JsonNode =
    result = newJArray()
    for x in xs:
      result.add(jsonOf(x.toCbor))

  func stateText(s: LogosNSRuntimeControlState): string =
    ($s.kind).toLowerAscii

  proc moduleRows(xs: seq[LogosNSRuntimeControlModuleRecord]): string =
    var rows: seq[seq[string]]
    for x in xs:
      let v = x.toCbor
      var failure = v.textField("failure", "")
      if x.reason.isSome:
        failure.add(
          (if failure.len > 0: " " else: "") & declaredText(v.textField("reason"))
        )
      rows.add(
        @[
          x.instance.get("-"),
          x.module,
          stateText(x.state),
          (if x.execution.isSome: $x.execution.get.revision else: "-"),
          failure,
        ]
      )
    table(["INSTANCE", "MODULE", "STATE", "REVISION", "FAILURE"], rows)

  # Online commands ------------------------------------------------------------------

  proc done(cl: Client, command: string, value: JsonNode, text: string): Done =
    Done(deployment: cl.deployment, command: command, result: value, text: text)

  proc cmdStatus(cl: var Client): Result[Done, Fail] =
    let i = ?cl.info()
    let xs = ?cl.listModules(Opt.none(string), Opt.none(string))
    var counts = initOrderedTable[string, int]()
    var failed: seq[LogosNSRuntimeControlModuleRecord]
    for x in xs:
      let k = stateText(x.state)
      counts[k] = counts.getOrDefault(k) + 1
      if x.state.kind == LogosNSRuntimeControlStateKind.Error or x.failure.isSome:
        failed.add(x)
    var cj = newJObject()
    var parts: seq[string]
    for k, n in counts:
      cj[k] = newJInt(n)
      parts.add(k & " " & $n)
    let r = %*{"daemon": jsonOf(i.toCbor), "counts": cj, "failed": recordsJson(failed)}
    var text = table(
      ["FIELD", "VALUE"],
      [
        @["runtime", i.runtime_instance_id],
        @["version", i.version],
        @["deployment", cl.deployment],
        @["trust revision", $i.trust_revision],
        @["socket", i.socket],
        @["instances", parts.join(", ")],
      ],
    )
    if failed.len > 0:
      text.add("\n\nfailed:\n" & moduleRows(failed))
    ok(cl.done("status", r, text))

  proc keyOf(c: Cli): Result[string, Fail] =
    let k = c.opt("request-key")
    if k.isSome:
      return ok(k.get)
    var b: array[16, byte]
    if not urandom(b):
      return err(fail(ExitUsage, "no randomness for a request key"))
    ok("lcli-" & toHex(b).toLowerAscii)

  proc cmdWait(cl: var Client, c: Cli): Result[Done, Fail] =
    ## [G349; plan §3.7] `module wait`: `get_readiness` until the state is
    ## reached (0), the instance is in `error` (4) or the timeout (2). It polls
    ## every 100 ms, backing off to 1 s.
    let module = ?c.arg(2, "MODULE")
    let wanted = c.opt("state").get("ready")
    var want = LogosNSRuntimeControlStateKind.Ready
    block found:
      for k in LogosNSRuntimeControlStateKind:
        if k != LogosNSRuntimeControlStateKind.Error and ($k).toLowerAscii == wanted:
          want = k
          break found
      return err(usage("--state is unloaded, loaded, ready or stopping"))
    var ms = 100
    while true:
      let (r, bytes) = ?cl.callTyped(
        LcnCtlMethodKind.Get_readiness,
        LogosNSRuntimeControlGetReadinessRequest(
          module: module, instance: c.opt("instance")
        ),
        LogosNSRuntimeControlGetReadinessResponse,
      )
      if r.state.kind == want:
        return ok(cl.done("module wait", jsonOfBytes(bytes), stateText(r.state)))
      if r.state.kind == LogosNSRuntimeControlStateKind.Error:
        var f = fail(
          ExitRc,
          module & " is in error" &
            (if r.reason.isSome: ": " & declaredText(r.reason.get)
            else: ""),
          r.failure.get(""),
        )
        f.result = jsonOfBytes(bytes)
        return err(f)
      if getMonoTime() + initDuration(milliseconds = ms) >= cl.deadline:
        return err(
          fail(
            ExitUnreachable,
            module & " did not reach " & wanted & " within " & $c.timeoutMs &
              " ms (last state " & stateText(r.state) & ")",
          )
        )
      sleep(ms)
      ms = min(ms * 2, 1000)

  proc cmdModule(cl: var Client, c: Cli): Result[Done, Fail] =
    let sub = ?c.arg(1, "a module command")
    case sub
    of "wait":
      cl.cmdWait(c)
    of "ls":
      let xs = ?cl.listModules(c.opt("module"), Opt.none(string))
      ok(cl.done("module ls", %*{"modules": recordsJson(xs)}, moduleRows(xs)))
    of "status":
      let module = ?c.arg(2, "MODULE")
      let req = LogosNSRuntimeControlGetReadinessRequest(
        module: module, instance: c.opt("instance")
      )
      let (_, bytes) = ?cl.callTyped(
        LcnCtlMethodKind.Get_readiness, req, LogosNSRuntimeControlGetReadinessResponse
      )
      ok(cl.done("module status", jsonOfBytes(bytes), diagOf(bytes)))
    of "summary":
      let instance = ?c.arg(2, "INSTANCE")
      let target = ?cl.target(instance)
      let req = LogosNSRuntimeControlGetExecutionSummaryRequest(target: target)
      let (_, bytes) = ?cl.callTyped(
        LcnCtlMethodKind.Get_execution_summary, req,
        LogosNSRuntimeControlGetExecutionSummaryResponse,
      )
      ok(cl.done("module summary", jsonOfBytes(bytes), diagOf(bytes)))
    of "create":
      let module = ?c.arg(2, "MODULE")
      let key = ?keyOf(c)
      let req =
        LogosNSRuntimeControlCreateModuleRequest(module: module, request_key: key)
      let params = req.encode.valueOr:
        return err(fail(ExitUsage, error))
      let deadline = Opt.some(uint32(min(cl.timeoutMs, 60_000)))
      let r = cl.exchange(rcMessage(LcnCtlMethodKind.Create_module, params, deadline))
      if r.isErr:
        var f = r.error[0]
        if r.error[1]:
          f.requestKey = key
          say("logosctl: the outcome is unknown; retry with --request-key " & key)
        return err(f)
      let bytes = outcomeOf(r.get).valueOr:
        var f = error
        f.requestKey = key
        return err(f)
      let made = LogosNSRuntimeControlCreateModuleResponse.decode(bytes).valueOr:
        return err(fail(ExitRc, "the response does not decode: " & error, $ecModule))
      if made.refusal.isSome:
        var f = refusedFail(made.refusal.get, bytes)
        f.requestKey = key
        return err(f)
      let x = made.accepted.get
      var d = cl.done(
        "module create",
        jsonOfBytes(bytes),
        "created " & x.instance & " (" & x.module & ")\nrequest key " & key,
      )
      d.requestKey = key
      ok(d)
    of "start", "stop":
      let module = ?c.arg(2, "MODULE")
      let rev = ?c.uintOpt("if-revision")
      if sub == "start":
        let req = LogosNSRuntimeControlStartModuleRequest(
          module: module, instance: c.opt("instance"), expected_execution_revision: rev
        )
        let (r, bytes) = ?cl.callArm(
          LcnCtlMethodKind.Start_module, req, LogosNSRuntimeControlStartModuleResponse
        )
        let x = r.accepted.get
        ok(
          cl.done(
            "module start",
            jsonOfBytes(bytes),
            x.instance.get(module) & ": " & stateText(x.state),
          )
        )
      else:
        let req = LogosNSRuntimeControlStopModuleRequest(
          module: module, instance: c.opt("instance"), expected_execution_revision: rev
        )
        let (r, bytes) = ?cl.callArm(
          LcnCtlMethodKind.Stop_module, req, LogosNSRuntimeControlStopModuleResponse
        )
        let x = r.accepted.get
        ok(
          cl.done(
            "module stop",
            jsonOfBytes(bytes),
            x.instance.get(module) & ": " & stateText(x.state),
          )
        )
    of "recover", "retire":
      let instance = ?c.arg(2, "INSTANCE")
      let xs = ?cl.listModules(Opt.none(string), Opt.some(instance))
      if xs.len == 0:
        return err(fail(ExitUsage, "no instance " & instance))
      let rec = xs[0]
      var rev = ?c.uintOpt("revision")
      if rev.isNone:
        if rec.execution.isNone:
          return err(
            fail(ExitUsage, instance & " has no execution revision; give --revision")
          )
        rev = Opt.some(rec.execution.get.revision)
      if sub == "recover":
        let req = LogosNSRuntimeControlRecoverModuleRequest(
          instance: instance, module: rec.module, expected_execution_revision: rev.get
        )
        let (r, bytes) = ?cl.callArm(
          LcnCtlMethodKind.Recover_module, req,
          LogosNSRuntimeControlRecoverModuleResponse,
        )
        let x = r.accepted.get
        ok(
          cl.done(
            "module recover", jsonOfBytes(bytes), x.instance & ": " & stateText(x.state)
          )
        )
      else:
        let target = ?cl.target(instance)
        let req = LogosNSRuntimeControlRetireModuleRequest(
          target: target, expected_execution_revision: rev.get
        )
        let (_, bytes) = ?cl.callArm(
          LcnCtlMethodKind.Retire_module, req, LogosNSRuntimeControlRetireModuleResponse
        )
        # [BCP l.395] Retirement keeps the state.
        ok(
          cl.done(
            "module retire",
            jsonOfBytes(bytes),
            instance & ": retired; its state directory is kept",
          )
        )
    else:
      err(usage("unknown module command " & sub))

  proc cmdRoute(cl: var Client, c: Cli): Result[Done, Fail] =
    let sub = ?c.arg(1, "a route command")
    if sub != "ls":
      return err(usage("unknown route command " & sub))
    var all = newJArray()
    var rows: seq[seq[string]]
    var cursor = Opt.none(LogosNSRuntimeControlCursor)
    while true:
      let req =
        LogosNSRuntimeControlListRoutesRequest(cursor: cursor, module: c.opt("module"))
      let (r, _) = ?cl.callTyped(
        LcnCtlMethodKind.List_routes, req, LogosNSRuntimeControlListRoutesResponse
      )
      for x in r.routes:
        let v = x.toCbor
        all.add(jsonOf(v))
        rows.add(
          @[
            x.route,
            x.module,
            x.consumer.module_instance_id,
            x.instance.get("-"),
            v.textField("state"),
          ]
        )
      if r.next_cursor.isNone:
        break
      cursor = r.next_cursor
    ok(
      cl.done(
        "route ls",
        %*{"routes": all},
        table(["ROUTE", "MODULE", "CONSUMER", "PROVIDER", "STATE"], rows),
      )
    )

  proc schemaGuard(
      cl: var Client, c: Cli, t: LogosNSRuntimeModuleInstanceAddress
  ): Result[(uint64, LogosNSModuleConfigurationSchemaCommitment), Fail] =
    ## `--revision N --schema HEX` (the schema root then its subtree root, 128
    ## hex digits), or both from `get_configuration_summary`.
    let rev = ?c.uintOpt("revision")
    let schema = c.opt("schema")
    if rev.isSome and schema.isSome:
      let b = hex.fromHex(schema.get).valueOr:
        return err(usage("--schema: " & error))
      if b.len != 64:
        return err(
          usage("--schema takes the schema root and its subtree root: 128 hex digits")
        )
      return ok(
        (
          rev.get,
          LogosNSModuleConfigurationSchemaCommitment(
            schema_root: b[0 ..< 32], schema_subtree_root: b[32 ..< 64]
          ),
        )
      )
    if rev.isSome or schema.isSome:
      return err(usage("--revision and --schema go together"))
    let (s, _) = ?cl.callTyped(
      LcnCtlMethodKind.Get_configuration_summary,
      LogosNSRuntimeControlGetConfigurationSummaryRequest(target: t),
      LogosNSRuntimeControlGetConfigurationSummaryResponse,
    )
    if s.state.schema_commitment.isNone:
      return err(fail(ExitUsage, t.module_instance_id & " has no configuration schema"))
    ok((s.state.state_revision, s.state.schema_commitment.get))

  proc cmdConfig(cl: var Client, c: Cli): Result[Done, Fail] =
    let sub = ?c.arg(1, "a config command")
    let instance = ?c.arg(2, "INSTANCE")
    let t = ?cl.target(instance)
    case sub
    of "schema":
      let (_, bytes) = ?cl.callTyped(
        LcnCtlMethodKind.Get_configuration_schema,
        LogosNSRuntimeControlGetConfigurationSchemaRequest(target: t),
        LogosNSRuntimeControlGetConfigurationSchemaResponse,
      )
      ok(cl.done("config schema", jsonOfBytes(bytes), diagOf(bytes)))
    of "summary":
      let (_, bytes) = ?cl.callTyped(
        LcnCtlMethodKind.Get_configuration_summary,
        LogosNSRuntimeControlGetConfigurationSummaryRequest(target: t),
        LogosNSRuntimeControlGetConfigurationSummaryResponse,
      )
      ok(cl.done("config summary", jsonOfBytes(bytes), diagOf(bytes)))
    of "get":
      let (_, bytes) = ?cl.callTyped(
        LcnCtlMethodKind.Get_configuration,
        LogosNSRuntimeControlGetConfigurationRequest(target: t),
        LogosNSRuntimeControlGetConfigurationResponse,
      )
      ok(cl.done("config get", jsonOfBytes(bytes), diagOf(bytes)))
    of "stage", "discard":
      let (rev, schema) = ?cl.schemaGuard(c, t)
      var req: LogosNSRuntimeControlUpdateConfigurationRequest
      if sub == "stage":
        let value = ?readValue(?c.arg(3, "@VALUE"))
        req = LogosNSRuntimeControlUpdateConfigurationRequest(
          kind: LogosNSRuntimeControlUpdateConfigurationRequestKind.Stage,
          arm_Stage: LogosNSRuntimeControlUpdateConfigurationRequestARStageMap(
            target: t,
            expected_state_revision: rev,
            expected_schema_commitment: schema,
            value: value,
          ),
        )
      else:
        req = LogosNSRuntimeControlUpdateConfigurationRequest(
          kind: LogosNSRuntimeControlUpdateConfigurationRequestKind.Discard,
          arm_Discard: LogosNSRuntimeControlUpdateConfigurationRequestARDiscardMap(
            target: t, expected_state_revision: rev, expected_schema_commitment: schema
          ),
        )
      let (r, bytes) = ?cl.callArm(
        LcnCtlMethodKind.Update_configuration, req,
        LogosNSRuntimeControlUpdateConfigurationResponse,
      )
      let x = r.accepted.get
      ok(
        cl.done(
          "config " & sub,
          jsonOfBytes(bytes),
          instance & ": state revision " & $x.state_revision,
        )
      )
    of "apply":
      var rev = ?c.uintOpt("revision")
      if rev.isNone:
        let (s, _) = ?cl.callTyped(
          LcnCtlMethodKind.Get_configuration_summary,
          LogosNSRuntimeControlGetConfigurationSummaryRequest(target: t),
          LogosNSRuntimeControlGetConfigurationSummaryResponse,
        )
        rev = Opt.some(s.state.state_revision)
      let (r, bytes) = ?cl.callArm(
        LcnCtlMethodKind.Apply_configuration,
        LogosNSRuntimeControlApplyConfigurationRequest(
          target: t, expected_state_revision: rev.get
        ),
        LogosNSRuntimeControlApplyConfigurationResponse,
      )
      let x = r.accepted.get
      ok(
        cl.done(
          "config apply",
          jsonOfBytes(bytes),
          instance & ": applied value revision " & $x.applied_value_revision,
        )
      )
    else:
      err(usage("unknown config command " & sub))

  proc cmdStop(cl: var Client, c: Cli, s: Session): Result[Done, Fail] =
    let path = socketOf(s)
    let (_, bytes) = ?cl.callTyped(
      LcnCtlMethodKind.Shutdown_runtime,
      LogosNSRuntimeControlShutdownRuntimeRequest(),
      LogosNSRuntimeControlShutdownRuntimeResponse,
    )
    var text = "shutdown accepted"
    if "wait" in c.flags:
      cl.close()
      let until = getMonoTime() + initDuration(milliseconds = c.timeoutMs)
      var st: Stat
      while lstat(cstring(path), st) == 0:
        if getMonoTime() >= until:
          return err(
            fail(
              ExitUnreachable, "the daemon did not stop within " & $c.timeoutMs & " ms"
            )
          )
        sleep(50)
      text = "stopped"
    ok(cl.done("daemon stop", jsonOfBytes(bytes), text))

  proc online(c: Cli, s: Session): Result[Done, Fail] =
    var cl = ?connect(s, c)
    defer:
      cl.close()
    case c.args[0]
    of "status":
      cl.cmdStatus()
    of "module":
      cl.cmdModule(c)
    of "route":
      cl.cmdRoute(c)
    of "permissions":
      let sub = ?c.arg(1, "a permissions command")
      if sub != "get":
        return err(usage("unknown permissions command " & sub))
      let t = ?cl.target(?c.arg(2, "INSTANCE"))
      let (_, bytes) = ?cl.callTyped(
        LcnCtlMethodKind.Get_permission_settings,
        LogosNSRuntimeControlGetPermissionSettingsRequest(target: t),
        LogosNSRuntimeControlGetPermissionSettingsResponse,
      )
      ok(cl.done("permissions get", jsonOfBytes(bytes), diagOf(bytes)))
    of "config":
      cl.cmdConfig(c)
    of "daemon":
      cl.cmdStop(c, s)
    else:
      err(usage("unknown command " & c.args[0]))

  # The launcher (Tier 5 step N-2b; G344, G349) ---------------------------------------

  var cancelPipe = [cint(-1), cint(-1)]
  var signals = 0

  proc onSignal(sig: cint) {.noconv.} =
    ## The first SIGINT or SIGTERM cancels the command (the launcher half-closes
    ## and waits for `done`); a second ends the shell at once.
    inc signals
    if signals > 1:
      exitnow(ExitInterrupted)
    var one = 1'u8
    discard posix.write(cancelPipe[1], addr one, 1)

  proc cancelOnSignals(): Result[cint, Fail] =
    ## A descriptor that becomes readable on SIGINT or SIGTERM.
    if pipe(cancelPipe) != 0:
      return err(fail(ExitUsage, "pipe: " & $strerror(errno)))
    for f in cancelPipe:
      discard fcntl(f, F_SETFD, FD_CLOEXEC)
    discard fcntl(cancelPipe[1], F_SETFL, fcntl(cancelPipe[1], F_GETFL) or O_NONBLOCK)
    var sa: Sigaction
    sa.sa_handler = onSignal
    discard sigemptyset(sa.sa_mask)
    sa.sa_flags = SA_RESTART
    for sig in [SIGINT, SIGTERM]:
      discard sigaction(sig, sa, nil)
    ok(cancelPipe[0])

  proc cliSocketOf(s: Session): string =
    ## [G344] lcn_call's socket, from the daemon configuration's `cli`.
    let r = readDaemonConfig(s)
    var dir = ""
    if r.isOk and r.get[0].cli.isSome and r.get[0].cli.get.socket_dir.isSome:
      dir = r.get[0].cli.get.socket_dir.get
    cliSocketPath(s, dir)

  proc providerOf(c: Cli, module: string): Result[LcnCliProvider, Fail] =
    var p = LcnCliProvider(module: module, instance: c.opt("instance"))
    let root = c.opt("contract")
    if root.isSome:
      let b = hex.fromHex(root.get)
      if b.isErr or b.get.len != 32:
        return err(usage("--contract takes a contract root, 64 hex digits"))
      p.contract = Opt.some(b.get)
    ok(p)

  proc argsOf(c: Cli, files: var seq[cint]): Result[seq[LcnCliArg], Fail] =
    ## [D26 (a); G349] `NAME=VALUE`, or `NAME=@FILE` (`@-`: stdin) passed as a
    ## descriptor; lcn_call types each from the method's request rule.
    ##
    ## [N-2d] The launcher has no schema, so it treats every argument as one
    ## that may be marked: a malformed one is named by its position, never
    ## echoed, and the copies made here are wiped (`launch` wipes the
    ## message). The process's own argv is not erased: lcn_call refuses an
    ## inline value for a marked request.
    var args: seq[LcnCliArg]
    var stdinUsed = false
    for k in 3 ..< c.args.len:
      template a(): untyped =
        c.args[k]

      let eq = a.find('=')
      if eq <= 0:
        return err(
          usage(
            "argument " & $(k - 2) & " after the method is not NAME=VALUE or NAME=@FILE"
          )
        )
      let name = a[0 ..< eq]
      if a.len <= eq + 1 or a[eq + 1] != '@':
        args.add(
          LcnCliArg(
            kind: LcnCliArgKind.lcn_Cli_text_arg,
            arm_lcn_Cli_text_arg: LcnCliTextArg(name: name, value: a[eq + 1 .. ^1]),
          )
        )
        continue
      let value = a[eq + 1 .. ^1]
      if files.len >= MaxFileArgs:
        return err(usage("at most " & $MaxFileArgs & " @FILE arguments"))
      let path = value[1 .. ^1]
      var fd = cint(0)
      if path == "-":
        if stdinUsed:
          return err(usage("@- (stdin) can be given once"))
        stdinUsed = true
      else:
        fd = posix.open(cstring(path), O_RDONLY or O_CLOEXEC)
        if fd < 0:
          return err(fail(ExitUsage, path & ": " & $strerror(errno)))
      files.add(fd)
      # The message's descriptors are stdout, stderr, then the files.
      args.add(
        LcnCliArg(
          kind: LcnCliArgKind.lcn_Cli_file_arg,
          arm_lcn_Cli_file_arg: LcnCliFileArg(name: name, fd: uint8(files.len + 1)),
        )
      )
    ok(args)

  proc commandOf(c: Cli, files: var seq[cint]): Result[LcnCliCommand, Fail] =
    if c.args[0] == "events":
      # [G346, G349] The target's Runtime Control events; no names: the
      # events rule's three.
      let names = c.args[1 .. ^1]
      if names.len > 16:
        return err(usage("events takes at most 16 names"))
      let count = ?c.countOpt()
      let forMs = ?c.durationOpt("for")
      var cmd = LcnCliEventsCommand(count: count, for_ms: forMs)
      if names.len > 0:
        cmd.names = Opt.some(names)
      return ok(
        LcnCliCommand(
          kind: LcnCliCommandKind.lcn_Cli_events_command,
          arm_lcn_Cli_events_command: cmd,
        )
      )
    let module = ?c.arg(1, "MODULE")
    let provider = ?c.providerOf(module)
    if c.args[0] == "subscribe":
      let event = ?c.arg(2, "EVENT")
      if c.args.len > 3:
        return err(usage("subscribe takes one MODULE and one EVENT"))
      let count = ?c.countOpt()
      let forMs = ?c.durationOpt("for")
      return ok(
        LcnCliCommand(
          kind: LcnCliCommandKind.lcn_Cli_subscribe_command,
          arm_lcn_Cli_subscribe_command: LcnCliSubscribeCommand(
            provider: provider, event: event, count: count, for_ms: forMs
          ),
        )
      )
    if c.args[0] == "describe":
      if c.args.len > 2:
        return err(usage("describe takes one MODULE"))
      return ok(
        LcnCliCommand(
          kind: LcnCliCommandKind.lcn_Cli_describe_command,
          arm_lcn_Cli_describe_command: LcnCliDescribeCommand(provider: provider),
        )
      )
    let meth = ?c.arg(2, "METHOD")
    var call =
      LcnCliCallCommand(`method`: meth, provider: provider, json: c.opt("request"))
    let args = ?c.argsOf(files)
    if args.len > 0:
      if call.json.isSome:
        return err(usage("--request and NAME=VALUE arguments exclude each other"))
      call.args = Opt.some(args)
    ok(
      LcnCliCommand(
        kind: LcnCliCommandKind.lcn_Cli_call_command, arm_lcn_Cli_call_command: call
      )
    )

  proc cmdLaunch(c: Cli, s: Session): Result[int, Fail] =
    ## [G344] Hands the command to lcn_call; its exit status, or a failure the
    ## shell prints itself.
    var files: seq[cint]
    defer:
      for f in files:
        if f > 0:
          discard posix.close(f)
    var command = ?c.commandOf(files)
    let cancelFd = ?cancelOnSignals()
    var l = Launch(
      cliSocket: cliSocketOf(s),
      ctlSocket: socketOf(s),
      message: LcnCliMessage(
        target: c.opt("node"),
        output: LcnCliOutput(
          kind: if c.json: LcnCliOutputKind.Json else: LcnCliOutputKind.Text
        ),
        # [G349] A stream has no deadline; `--timeout` bounds activation.
        deadline_ms: (
          if c.args[0] in ["subscribe", "events"]: Opt.none(uint32)
          else: Opt.some(uint32(c.timeoutMs))
        ),
        command: move command,
      ),
      stdoutFd: 1,
      stderrFd: 2,
      files: files,
      timeoutMs: c.timeoutMs,
      cancelFd: cancelFd,
    )
    let r = launch(l)
    wipeTyped(l.message) # [N-2d] the arguments' values
    if r.isErr:
      return err(fail(r.error.exit, r.error.message, r.error.code))
    ok(r.get)

  # Offline commands -----------------------------------------------------------------

  proc offline(s: Session, command: string, r: JsonNode, text: string): Done =
    Done(deployment: offlineDeployment(s), command: command, result: r, text: text)

  proc locked(s: Session): Result[DurableLock, Fail] =
    checkSession(s).isOkOr:
      return err(fail(ExitUsage, error))
    lockSession(s).mapErr(
      proc(e: string): Fail =
        fail(ExitUsage, e)
    )

  proc check(s: Session, bytes: openArray[byte]): Result[Prepared, Fail] =
    let t = readTrust(s).valueOr:
      return err(fail(ExitUsage, "the trust file: " & error))
    # [IMPL] Whether logosd was built with test hooks is logosd's to say at
    # start; the shell checks everything else, the development switch included.
    prepareDaemon(s, bytes, t, hooksBuild = true, exe = getAppFilename()).mapErr(
      proc(e: string): Fail =
        fail(ExitUsage, e)
    )

  proc configTemplate(): string =
    ## [E3] `init --print-template`: a daemon-config in diagnostic notation
    ## with one operator module, hosted; its artifact's path and hash are the
    ## operator's to fill in.
    """{
  "format": "logos-core-nim.daemon-config.v1",
  "runtime": {"runtime_instance_id": "assigned-by-init"},
  "policy": {"kind": "capability-authority", "source": "operator", "recovery": true, "rules": []},
  "modules": [
    {
      "instance": "example",
      "module": "example_module",
      "implementation": {
        "strategy": "hosted_dynamic",
        "placement": "process",
        "artifact": {
          "id": "example_module",
          "local_path": "/absolute/path/to/libexample_module.so",
          "hash": h'0000000000000000000000000000000000000000000000000000000000000000',
          "hash_suite": "logos.hash-suite.blake3-256"
        }
      }
    }
  ],
  "orchestration": {"start": ["example"]}
}"""

  proc cmdInit(c: Cli, s: Session): Result[Done, Fail] =
    if "print-template" in c.flags:
      return ok(
        Done(
          deployment: "production",
          command: "init",
          result: newJString(configTemplate()),
          text: configTemplate(),
        )
      )
    var o = InitOptions(development: "development" in c.flags, exe: getAppFilename())
    let cfg = c.opt("config")
    if cfg.isSome:
      let bytes = ?readValue(cfg.get)
      o.config = Opt.some(
        ?decodeDaemonConfig(bytes).mapErr(
          proc(e: string): Fail =
            fail(ExitUsage, "--config: " & e)
        )
      )
    let pol = c.opt("policy")
    if pol.isSome:
      let bytes = ?readValue(pol.get)
      let v = decodeCbor(bytes).valueOr:
        return err(fail(ExitUsage, "--policy: " & error.msg))
      if v.kind != ckArray:
        return err(fail(ExitUsage, "--policy: an array of lcn.ap_rule"))
      for x in v.items:
        o.rules.add(
          ?LcnApRule.fromCbor(x).mapErr(
            proc(e: string): Fail =
              fail(ExitUsage, "--policy: " & e)
          )
        )
    for spec in c.optAll("module-config"):
      let i = spec.find('=')
      if i <= 0:
        return err(usage("--module-config takes INSTANCE=@FILE"))
      let value = ?readValue(spec[i + 1 .. ^1])
      o.moduleConfigs.add((spec[0 ..< i], value))
    let r = initSession(s, o).valueOr:
      return err(fail(ExitUsage, error))
    let kid = toHex(r.key.binding.kid).toLowerAscii
    let j = %*{
      "session": s.dir,
      "runtime_instance_id": r.runtimeId,
      "evidence_kid": kid,
      "trust_revision": r.trust.file.revision,
      "development": r.trust.file.development,
    }
    ok(
      s.offline(
        "init",
        j,
        "session " & s.dir & "\nruntime " & r.runtimeId & "\nevidence kid " & kid &
          "\ntrust revision " & $r.trust.file.revision &
          (if r.trust.file.development: " (development switch on)" else: ""),
      )
    )

  proc cmdDaemonConfig(c: Cli, s: Session): Result[Done, Fail] =
    let sub = ?c.arg(2, "a daemon config command")
    case sub
    of "get":
      let (_, bytes) = readDaemonConfig(s).valueOr:
        return err(fail(ExitUsage, error))
      let outPath = c.opt("out")
      let format = c.opt("format").get("diag")
      if format notin ["diag", "cbor"]:
        return err(usage("--format is diag or cbor"))
      if outPath.isSome:
        let data =
          if format == "cbor":
            bytes
          else:
            let d = diagOf(bytes)
            @(d.toOpenArrayByte(0, d.high))
        ?writeOut(outPath.get, data)
        return ok(
          s.offline(
            "daemon config get", %*{"out": outPath.get}, "written to " & outPath.get
          )
        )
      ok(s.offline("daemon config get", %*{"config": valueJson(bytes)}, diagOf(bytes)))
    of "check":
      let bytes =
        if c.args.len > 3:
          ?readValue(c.args[3])
        else:
          (
            ?readDaemonConfig(s).mapErr(
              proc(e: string): Fail =
                fail(ExitUsage, e)
            )
          )[1]
      discard ?check(s, bytes)
      ok(
        s.offline(
          "daemon config check",
          %*{"valid": true},
          "the daemon-config passes logosd's checks",
        )
      )
    of "set":
      let bytes = ?readValue(?c.arg(3, "@FILE"))
      var lock = ?locked(s)
      defer:
        lock.release()
      let (cur, _) = readDaemonConfig(s).valueOr:
        return err(fail(ExitUsage, error))
      let dc = decodeDaemonConfig(bytes).valueOr:
        return err(fail(ExitUsage, error))
      if dc.runtime.runtime_instance_id != cur.runtime.runtime_instance_id:
        return err(
          fail(
            ExitUsage,
            "runtime.runtime_instance_id is fixed at init (" &
              cur.runtime.runtime_instance_id & "); a new id needs a new session",
          )
        )
      discard ?check(s, bytes)
      writeAtomic(s.dir, DaemonConfigName, bytes).isOkOr:
        return err(fail(ExitUsage, error))
      ok(
        s.offline(
          "daemon config set",
          %*{"written": true},
          "written; it applies at the next start",
        )
      )
    of "module-config":
      let instance = ?c.arg(3, "INSTANCE")
      var value = Opt.none(seq[byte])
      if "remove" notin c.flags:
        value = Opt.some(?readValue(?c.arg(4, "@FILE or --remove")))
      var lock = ?locked(s)
      defer:
        lock.release()
      var (dc, _) = readDaemonConfig(s).valueOr:
        return err(fail(ExitUsage, error))
      var found = false
      if dc.modules.isSome:
        for m in dc.modules.get.mitems:
          if m.instance == instance:
            m.provisioned_configuration = value
            found = true
      if not found:
        return err(fail(ExitUsage, "no operator instance " & instance))
      let bytes = dc.encode.valueOr:
        return err(fail(ExitUsage, error))
      discard ?check(s, bytes)
      writeAtomic(s.dir, DaemonConfigName, bytes).isOkOr:
        return err(fail(ExitUsage, error))
      ok(
        s.offline(
          "daemon config module-config",
          %*{"instance": instance},
          "written; it applies at the next start",
        )
      )
    else:
      err(usage("unknown daemon config command " & sub))

  proc keysJson(xs: seq[EvidenceKeyInfo], current: string): (JsonNode, string) =
    var a = newJArray()
    var rows: seq[seq[string]]
    for x in xs:
      let kid = toHex(x.binding.kid).toLowerAscii
      let state =
        if x.binding.retired_ms.isSome:
          "retired"
        elif kid == current:
          "current"
        else:
          "unused"
      a.add(
        %*{
          "kid": kid,
          "runtime_instance_id": x.binding.runtime_instance_id,
          "public_key": toHex(x.binding.public_key).toLowerAscii,
          "created_ms": x.binding.created_ms,
          "state": state,
        }
      )
      rows.add(
        @[
          kid,
          x.binding.runtime_instance_id,
          $x.binding.created_ms,
          state,
          toHex(x.binding.public_key).toLowerAscii,
        ]
      )
    (a, table(["KID", "RUNTIME", "CREATED_MS", "STATE", "PUBLIC_KEY"], rows))

  proc currentKid(s: Session, xs: seq[EvidenceKeyInfo]): string =
    ## The key daemon-config names, else the newest key not retired.
    let r = readDaemonConfig(s)
    if r.isOk:
      let dc = r.get[0]
      if dc.call_audit.isSome and dc.call_audit.get.evidence.isSome:
        return toHex(dc.call_audit.get.evidence.get.kid).toLowerAscii
    for i in countdown(xs.high, 0):
      if xs[i].binding.retired_ms.isNone:
        return toHex(xs[i].binding.kid).toLowerAscii
    ""

  proc trustEvidenceKeys(
      s: Session, files: openArray[LcnPackageTrust]
  ): Result[seq[seq[byte]], string] =
    ## [G397] What logosd's start compares for key separation: the session's
    ## evidence keys, the configured one included, read only when one of
    ## `files` names an anchor.
    var anchors = false
    for f in files:
      if f.signing.anchors.len > 0:
        anchors = true
    if not anchors:
      return ok(newSeq[seq[byte]]())
    let (dc, _) = ?readDaemonConfig(s)
    if dc.call_audit.isSome and dc.call_audit.get.evidence.isSome:
      let e = dc.call_audit.get.evidence.get
      return sessionEvidenceKeys(s, e.secret_key_file, e.kid)
    sessionEvidenceKeys(s)

  proc kidOpt(c: Cli): Result[seq[byte], Fail] =
    ## [G397; I41] `--kid KID`: text, or `hex:` and hex digits, as
    ## `lcn-pkg sign --kid` takes it, so the operator passes the value the
    ## producer signed with.
    let v = c.opt("kid")
    if v.isNone:
      return err(usage("--kid KID is required"))
    if v.get.startsWith("hex:"):
      return hex.fromHex(v.get[4 .. ^1]).mapErr(
          proc(e: string): Fail =
            usage("--kid hex: takes hex digits: " & e)
        )
    ok(@(v.get.toOpenArrayByte(0, v.get.high)))

  proc keyOpt(c: Cli): Result[seq[byte], Fail] =
    ## [G397; IMPL] `--key HEX`: the public key's 96 hex digits, or `@FILE`
    ## holding them alone or as the `public key: <hex>` line `lcn-pkg keygen`
    ## prints; surrounding whitespace is ignored and nothing else is taken.
    const Line = "public key:"
    let v = c.opt("key")
    if v.isNone:
      return err(usage("--key HEX is required"))
    var text = v.get
    if text.startsWith("@"):
      try:
        text = readFile(text[1 .. ^1])
      except IOError as e:
        return err(fail(ExitUsage, text[1 .. ^1] & ": " & e.msg))
    text = text.strip
    if text.startsWith(Line):
      text = text[Line.len .. ^1].strip
    let key = hex.fromHex(text)
    if key.isErr or key.get.len != 48:
      return err(
        fail(
          ExitUsage,
          "--key: a public key is 96 hex digits (48 bytes), alone or as lcn-pkg keygen's \"public key:\" line",
        )
      )
    ok(key.get)

  proc trustCommit(
      s: Session, cur: TrustFileState, next: LcnPackageTrust
  ): Result[TrustChange, Fail] =
    ## [G397] Every writer's last step: logosd's checks, the unchanged rule.
    let keys = trustEvidenceKeys(s, [cur.file, next]).valueOr:
      return err(fail(ExitUsage, "the evidence keys: " & error))
    commitTrust(s, cur, next, keys).mapErr(
      proc(e: string): Fail =
        fail(ExitUsage, e)
    )

  proc trustWritten(
      s: Session, command: string, ch: TrustChange, what: string, extra: JsonNode
  ): Done =
    ## [G397; Q16] A writer's answer: the revision written, or unchanged.
    let rev = $ch.state.file.revision
    var j = %*{"revision": ch.state.file.revision, "changed": ch.changed}
    for k, v in extra.pairs:
      j[k] = v
    let text =
      if ch.changed:
        "trust revision " & rev & ": " & what & "; it applies at the next start"
      else:
        "unchanged at trust revision " & rev & ": nothing was written"
    s.offline(command, j, text)

  proc cmdTrust(c: Cli, s: Session): Result[Done, Fail] =
    let sub = ?c.arg(1, "a trust command")
    case sub
    of "show":
      let t = readTrust(s).valueOr:
        return err(fail(ExitUsage, error))
      let mark = readMark(s).valueOr:
        return err(fail(ExitUsage, error))
      # [G397] The file is decoded without the rules, so a refused one shows,
      # with the reason logosd's start would give.
      let refusal = block:
        let keys = trustEvidenceKeys(s, [t.file])
        if keys.isErr:
          Opt.some("the evidence keys: " & keys.error)
        else:
          let v = validateTrust(t.file, keys.get)
          if v.isErr:
            Opt.some(v.error)
          else:
            Opt.none(string)
      # [G396] A start applies the rules before continuity, so a file they
      # refuse never reaches it.
      let continuity = block:
        let d = decide(t, mark)
        if refusal.isSome:
          "not reached: a start refuses the file before continuity (see refusal)"
        elif d.isErr:
          "refused: " & d.error
        elif d.get == cAccept:
          "accepted (the revision in use)"
        else:
          "accepted at the next start (a higher revision)"
      var j = trustJson(t.file)
      j["file"] = %t.present
      j["continuity"] = %continuity
      if refusal.isSome:
        j["refusal"] = %refusal.get
      if mark.isSome:
        j["mark"] = %*{
          "revision": mark.get.revision, "digest": toHex(mark.get.digest).toLowerAscii
        }
      var rows = @[
        @[
          "revision",
          $t.file.revision & (if t.present: "" else: " (the floor; no file)"),
        ]
      ]
      rows.add(trustRows(t.file))
      rows.add(@["mark", (if mark.isSome: $mark.get.revision else: "none")])
      rows.add(@["continuity", continuity])
      if refusal.isSome:
        rows.add(@["refusal", refusal.get])
      var text = table(["FIELD", "VALUE"], rows)
      if t.file.signing.anchors.len > 0:
        text.add("\n\n" & anchorsTable(t.file))
      ok(s.offline("trust show", j, text))
    of "anchor":
      let op = ?c.arg(2, "add, remove, add-names or remove-names")
      if op notin ["add", "remove", "add-names", "remove-names"]:
        return err(usage("unknown trust anchor command " & op))
      let kid = ?c.kidOpt
      let names =
        if c.args.len > 3:
          c.args[3 .. ^1]
        else:
          newSeq[string]()
      var key: seq[byte]
      if op == "add":
        key = ?c.keyOpt
      if op == "remove" and names.len > 0:
        return
          err(usage("trust anchor remove takes no NAME; remove-names removes names"))
      if op != "remove" and names.len == 0:
        return err(usage("trust anchor " & op & " needs at least one NAME"))
      var lock = ?locked(s)
      defer:
        lock.release()
      let cur = readTrust(s).valueOr:
        return err(fail(ExitUsage, error))
      let next =
        case op
        of "add":
          cur.file.withAnchor(
            LcnTrustAnchor(
              kid: kid,
              public_key: key,
              packages: names,
              development: "development" in c.flags,
            )
          )
        of "remove":
          cur.file.withoutAnchor(kid)
        of "add-names":
          cur.file.withNames(kid, names)
        else:
          cur.file.withoutNames(kid, names)
      let f = next.valueOr:
        return err(fail(ExitUsage, error))
      let ch = ?trustCommit(s, cur, f)
      let what =
        case op
        of "add": "anchor added"
        of "remove": "anchor removed"
        of "add-names": "names added"
        else: "names removed"
      ok(
        s.trustWritten(
          "trust anchor " & op,
          ch,
          what & " (kid " & toHex(kid) & ")",
          %*{"kid": toHex(kid)},
        )
      )
    of "development":
      let v = ?c.arg(2, "on or off")
      if v notin ["on", "off"]:
        return err(usage("trust development takes on or off"))
      var lock = ?locked(s)
      defer:
        lock.release()
      let cur = readTrust(s).valueOr:
        return err(fail(ExitUsage, error))
      let ch = ?trustCommit(s, cur, cur.file.withDevelopment(v == "on"))
      # [G137] The anchors the file marks `development`: those that enter or
      # leave force with a change, and are in or out of force without one.
      var marked = 0
      for a in ch.state.file.signing.anchors:
        if a.development:
          inc marked
      let anchors =
        $marked & " development anchor" & (if marked == 1: " " else: "s ") &
        (if v == "on": "enter" else: "leave") & (if marked == 1: "s" else: "") & " force"
      ok(
        s.trustWritten(
          "trust development",
          ch,
          "development switch " & v & ", " & anchors,
          %*{"development": ch.state.file.development, "development_anchors": marked},
        )
      )
    of "reestablish":
      let rev = ?c.uintOpt("revision")
      if rev.isNone:
        return err(usage("trust reestablish needs --revision N"))
      var lock = ?locked(s)
      defer:
        lock.release()
      let cur = readTrust(s).valueOr:
        return err(fail(ExitUsage, error))
      let keys = trustEvidenceKeys(s, [cur.file]).valueOr:
        return err(fail(ExitUsage, "the evidence keys: " & error))
      let t = reestablish(s, rev.get, keys).valueOr:
        return err(fail(ExitUsage, error))
      ok(
        s.offline(
          "trust reestablish",
          %*{"revision": t.file.revision},
          "the mark records revision " & $t.file.revision,
        )
      )
    of "evidence-keys":
      let op = ?c.arg(2, "ls or rotate")
      case op
      of "ls":
        let xs = listEvidenceKeys(s.keysDir).valueOr:
          return err(fail(ExitUsage, error))
        let (j, text) = keysJson(xs, currentKid(s, xs))
        ok(s.offline("trust evidence-keys ls", %*{"keys": j}, text))
      of "rotate":
        var lock = ?locked(s)
        defer:
          lock.release()
        var (dc, _) = readDaemonConfig(s).valueOr:
          return err(fail(ExitUsage, error))
        let xs = listEvidenceKeys(s.keysDir).valueOr:
          return err(fail(ExitUsage, error))
        let cur = currentKid(s, xs)
        if cur.len == 0:
          return err(fail(ExitUsage, "no current evidence key"))
        let old = hex.fromHex(cur).valueOr:
          return err(fail(ExitUsage, error))
        let fresh = rotateEvidenceKey(s.keysDir, old, dc.runtime.runtime_instance_id).valueOr:
          return err(fail(ExitUsage, error))
        if dc.call_audit.isSome and dc.call_audit.get.evidence.isSome:
          var a = dc.call_audit.get
          var e = a.evidence.get
          e.kid = fresh.binding.kid
          e.secret_key_file = fresh.keyFile
          a.evidence = Opt.some(e)
          dc.call_audit = Opt.some(a)
          let bytes = dc.encode.valueOr:
            return err(fail(ExitUsage, error))
          writeAtomic(s.dir, DaemonConfigName, bytes).isOkOr:
            return err(fail(ExitUsage, error))
        let kid = toHex(fresh.binding.kid).toLowerAscii
        ok(
          s.offline(
            "trust evidence-keys rotate",
            %*{"kid": kid},
            "new evidence key " & kid & "; it applies at the next start",
          )
        )
      else:
        err(usage("unknown evidence-keys command " & op))
    else:
      err(usage("unknown trust command " & sub))

  # Remote trust (G408) -----------------------------------------------------------------

  func lowerHex(b: openArray[byte]): string =
    anchorName(b)

  proc recordJson(r: Enrollment): JsonNode =
    let k = keyOf(r)
    result = %*{
      "runtime": k.runtime,
      "profile": k.profile,
      "revision": revisionOf(r),
      "status": (if r.active: "active" else: "revoked"),
    }
    if r.active:
      result["anchor"] = %lowerHex(r.arm_Active.trust_anchor)
      var keys = newJArray()
      for key in keysOf(r):
        keys.add(%lowerHex(key))
      result["keys"] = keys

  proc recordRow(r: Enrollment, note = ""): seq[string] =
    let k = keyOf(r)
    @[
      k.runtime,
      k.profile,
      $revisionOf(r),
      (if r.active: "active" else: "revoked") & note,
      (if r.active: lowerHex(r.arm_Active.trust_anchor) else: ""),
      (if r.active: $keysOf(r).len else: ""),
    ]

  proc linesJson(xs: openArray[string]): JsonNode =
    result = newJArray()
    for x in xs:
      result.add(%x)

  proc reportText(report, conflicts: openArray[string]): string =
    ## [G324 extended] The loader report, as logosd logs it at its start.
    for x in conflicts:
      result.add("\nremote-trust-report: " & x)
    for x in report:
      result.add("\nremote-trust-report: " & x)

  func profileArg(p: string): string =
    ## `tls-tcp` and `quic` stand for the profiles' full names.
    if p.startsWith("logos.remote."):
      p
    else:
      "logos.remote." & p

  proc remoteWritten(
      s: Session,
      command: string,
      ch: RemoteChange,
      what: string,
      extra: JsonNode,
      after = "",
  ): Done =
    ## [G408] A writer's answer: the revision written, or unchanged, and the
    ## loader report of the input it leaves.
    let rev = $ch.state.file.revision
    var j = %*{
      "revision": ch.state.file.revision,
      "changed": ch.changed,
      "report": linesJson(ch.report),
      "conflicts": linesJson(ch.conflicts),
    }
    for k, v in extra.pairs:
      j[k] = v
    var text =
      if ch.changed:
        "remote trust revision " & rev & ": " & what & "; " & AppliesAtNextStart & after
      else:
        "unchanged at remote trust revision " & rev & ": nothing was written"
    text.add(reportText(ch.report, ch.conflicts))
    s.offline(command, j, text)

  proc remoteCurrent(s: Session): Result[RemoteTrustState, Fail] =
    let t = readRemoteTrust(s).valueOr:
      return err(fail(ExitUsage, error))
    if t.isNone:
      return err(
        fail(
          ExitUsage, "there is no " & RemoteTrustFile & "; remote trust init makes one"
        )
      )
    ok(t.get)

  proc remoteCommit(
      s: Session, cur: RemoteTrustState, next: Result[LcnRemoteTrust, string]
  ): Result[RemoteChange, Fail] =
    let f = next.valueOr:
      return err(fail(ExitUsage, error))
    commitRemoteTrust(s, cur, f).mapErr(
      proc(e: string): Fail =
        fail(ExitUsage, e)
    )

  proc readDer(path: string): Result[seq[byte], Fail] =
    let bytes = readBounded(path, MaxRemoteTrustBytes).valueOr:
      return err(fail(ExitUsage, path & ": " & error))
    if bytes.isNone:
      return err(fail(ExitUsage, path & ": no such file"))
    ok(bytes.get)

  proc idOpt(c: Cli): Result[Opt[seq[byte]], Fail] =
    let v = c.opt("id")
    if v.isNone:
      return ok(Opt.none(seq[byte]))
    let id = hex.fromHex(v.get).valueOr:
      return err(usage("--id takes hex digits: " & error))
    if id.len notin 1 .. 128:
      return err(usage("--id is 1 to 128 bytes"))
    ok(Opt.some(id))

  proc cmdRemoteTrust(c: Cli, s: Session): Result[Done, Fail] =
    let sub = ?c.arg(2, "a remote trust command")
    case sub
    of "init":
      var lock = ?locked(s)
      defer:
        lock.release()
      let t = initRemoteTrust(s).valueOr:
        return err(fail(ExitUsage, error))
      ok(
        s.offline(
          "remote trust init",
          %*{"revision": t.file.revision},
          "remote trust revision " & $t.file.revision &
            ": an empty remote trust input and its mark; logosd reads them only with " &
            "remote.enabled, and " & AppliesAtNextStart,
        )
      )
    of "show":
      let t = readRemoteTrust(s).valueOr:
        return err(fail(ExitUsage, error))
      let mark = readRemoteMark(s).valueOr:
        return err(fail(ExitUsage, error))
      var j = %*{"file": t.isSome}
      var rows: seq[seq[string]]
      if mark.isSome:
        j["mark"] =
          %*{"revision": mark.get.revision, "digest": lowerHex(mark.get.digest)}
      if t.isNone:
        rows.add(@["file", "none (remote trust init makes one)"])
        rows.add(@["mark", (if mark.isSome: $mark.get.revision else: "none")])
        return ok(s.offline("remote trust show", j, table(["FIELD", "VALUE"], rows)))
      let f = t.get.file
      j["revision"] = %f.revision
      j["digest"] = %lowerHex(t.get.digest)
      # [G408] Decoded without the rules, so a refused input shows, with the
      # reason logosd's start would give.
      let v = validateRemoteTrust(f, mark)
      let (continuity, refusal) =
        if v.isErr:
          ("refused", Opt.some(v.error))
        elif mark.isNone:
          ("refused", Opt.some(RemoteNotEstablished))
        elif v.get.advance:
          ("accepted at the next start (a higher revision)", Opt.none(string))
        else:
          ("accepted (the revision in use)", Opt.none(string))
      j["continuity"] = %continuity
      if refusal.isSome:
        j["refusal"] = %refusal.get
      var anchors = newJArray()
      var anchorRows: seq[seq[string]]
      for a in f.anchors:
        let problems = directAnchorProblems(a.certificate)
        anchors.add(
          %*{
            "id": lowerHex(a.id),
            "certificate_bytes": a.certificate.len,
            "problems": linesJson(problems),
          }
        )
        anchorRows.add(
          @[
            lowerHex(a.id),
            $a.certificate.len,
            (if problems.len == 0: "direct anchor"
            else: problems.join("; ")),
          ]
        )
      j["anchors"] = anchors
      var records = newJArray()
      var recordRows: seq[seq[string]]
      for r in f.enrollments:
        records.add(recordJson(r))
        recordRows.add(recordRow(r))
      j["enrollments"] = records
      rows.add(@["revision", $f.revision])
      rows.add(@["mark", (if mark.isSome: $mark.get.revision else: "none")])
      rows.add(@["continuity", continuity])
      if refusal.isSome:
        rows.add(@["refusal", refusal.get])
      var text = table(["FIELD", "VALUE"], rows)
      if anchorRows.len > 0:
        text.add("\n\n" & table(["ANCHOR", "BYTES", "CHECK"], anchorRows))
      if recordRows.len > 0:
        text.add(
          "\n\n" &
            table(
              ["RUNTIME", "PROFILE", "REVISION", "STATUS", "ANCHOR", "KEYS"], recordRows
            )
        )
      if v.isOk:
        j["report"] = linesJson(v.get.report)
        j["conflicts"] = linesJson(v.get.conflicts)
        text.add(reportText(v.get.report, v.get.conflicts))
      ok(s.offline("remote trust show", j, text))
    of "reestablish":
      let rev = ?c.uintOpt("revision")
      if rev.isNone:
        return err(usage("remote trust reestablish needs --revision N"))
      var lock = ?locked(s)
      defer:
        lock.release()
      let st = reestablishRemote(s, rev.get).valueOr:
        return err(fail(ExitUsage, error))
      ok(
        s.offline(
          "remote trust reestablish",
          %*{"revision": st.accepted.revision, "report": linesJson(st.report)},
          "the remote trust mark records revision " & $st.accepted.revision & "; " &
            AppliesAtNextStart & reportText(st.report, []),
        )
      )
    of "anchor":
      let op = ?c.arg(3, "add or remove")
      case op
      of "add":
        let path = ?c.arg(4, "the anchor's DER certificate file")
        let der = ?readDer(path)
        let id = (?c.idOpt).get(anchorIdOf(der))
        var lock = ?locked(s)
        defer:
          lock.release()
        let cur = ?remoteCurrent(s)
        let ch = ?remoteCommit(
          s, cur, cur.file.withRemoteAnchor(LcnRemoteAnchor(id: id, certificate: der))
        )
        ok(
          s.remoteWritten(
            "remote trust anchor add",
            ch,
            "anchor " & lowerHex(id) & " added",
            %*{"id": lowerHex(id)},
          )
        )
      of "remove":
        let id = (?c.idOpt).valueOr:
          return err(usage("remote trust anchor remove needs --id HEX"))
        var lock = ?locked(s)
        defer:
          lock.release()
        let cur = ?remoteCurrent(s)
        let ch = ?remoteCommit(s, cur, cur.file.withoutRemoteAnchor(id))
        ok(
          s.remoteWritten(
            "remote trust anchor remove",
            ch,
            "anchor " & lowerHex(id) & " withdrawn",
            %*{"id": lowerHex(id)},
          )
        )
      else:
        err(usage("unknown remote trust anchor command " & op))
    of "enroll":
      let op = ?c.arg(3, "add or revoke")
      case op
      of "add":
        let spec = ?c.arg(4, "the record, @FILE")
        let bytes = ?readValue(spec)
        let rec = Enrollment.decode(bytes).valueOr:
          return err(
            fail(
              ExitUsage, spec[1 .. ^1] & " is not a remote_runtime_enrollment: " & error
            )
          )
        var lock = ?locked(s)
        defer:
          lock.release()
        let cur = ?remoteCurrent(s)
        let ch = ?remoteCommit(s, cur, cur.file.withEnrollment(rec))
        ok(
          s.remoteWritten(
            "remote trust enroll add",
            ch,
            $keyOf(rec) & " enrolled at revision " & $revisionOf(rec),
            %*{"record": recordJson(rec)},
          )
        )
      of "revoke":
        let runtime = ?c.arg(4, "the Runtime id")
        let profile = profileArg(c.opt("profile").get(TlsTcpProfile))
        var lock = ?locked(s)
        defer:
          lock.release()
        let cur = ?remoteCurrent(s)
        let ch = ?remoteCommit(s, cur, cur.file.withRevocation(runtime, profile))
        ok(
          s.remoteWritten(
            "remote trust enroll revoke",
            ch,
            "Runtime " & runtime & " (" & profile & ") revoked",
            %*{"runtime": runtime, "profile": profile},
            after = "; " & RevokeCloses,
          )
        )
      else:
        err(usage("unknown remote trust enroll command " & op))
    of "import":
      let spec = ?c.arg(3, "the peer file, @FILE")
      let bytes = ?readValue(spec)
      let peer = decodePeer(bytes).valueOr:
        return err(fail(ExitUsage, spec[1 .. ^1] & ": " & error))
      if c.opt("node").isSome or c.opt("address").isSome:
        return err(
          usage("remote trust import --node comes with the lcn_call nodes (5-7a-4)")
        )
      var lock = ?locked(s)
      defer:
        lock.release()
      let cur = ?remoteCurrent(s)
      let ch = ?remoteCommit(s, cur, cur.file.withPeer(peer))
      ok(
        s.remoteWritten(
          "remote trust import",
          ch,
          "anchor " & lowerHex(peer.anchor.id) & " and " & $keyOf(peer.enrollment) &
            " at revision " & $revisionOf(peer.enrollment) & " imported",
          %*{"id": lowerHex(peer.anchor.id), "record": recordJson(peer.enrollment)},
        )
      )
    else:
      err(usage("unknown remote trust command " & sub))

  # Remote credential (G409) --------------------------------------------------------------

  proc isoTime(t: int64): string =
    try:
      fromUnix(t).utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    except CatchableError:
      $t

  proc credentialJson(i: CredentialInfo): JsonNode =
    %*{
      "runtime": keyOf(i.peer.enrollment).runtime,
      "revision": i.revisionOf,
      "certificate_sha256": lowerHex(i.certificateSha256),
      "anchor_id": lowerHex(i.anchorId),
      "spki": lowerHex(i.spki),
      "certificate": lowerHex(i.certificate),
      "not_before": isoTime(i.notBefore),
      "not_after": isoTime(i.notAfter),
      "peer_file": i.peerFile,
    }

  proc credentialRows(i: CredentialInfo, what: string): seq[seq[string]] =
    @[
      @[what, i.dir],
      @["runtime", keyOf(i.peer.enrollment).runtime],
      @["enrollment revision", $i.revisionOf],
      @["certificate sha-256", lowerHex(i.certificateSha256)],
      @["anchor id", lowerHex(i.anchorId)],
      @["key (spki)", lowerHex(i.spki)],
      @["valid", isoTime(i.notBefore) & " to " & isoTime(i.notAfter)],
      @["peer file", i.peerFile],
    ]

  proc daysOpt(c: Cli): Result[int, Fail] =
    let v = c.opt("days")
    if v.isNone:
      return ok(DefaultValidityDays)
    let n =
      try:
        parseInt(v.get)
      except ValueError:
        return err(usage("--days takes a number of days"))
    if n notin 1 .. MaxValidityDays:
      return err(usage("--days is 1 to " & $MaxValidityDays))
    ok(n)

  proc cmdRemoteCredential(c: Cli, s: Session): Result[Done, Fail] =
    let sub = ?c.arg(2, "new, show or rotate")
    case sub
    of "new", "rotate":
      let days = ?daysOpt(c)
      var lock = ?locked(s)
      defer:
        lock.release()
      let (dc, _) = readDaemonConfig(s).valueOr:
        return err(fail(ExitUsage, error))
      let runtime = dc.runtime.runtime_instance_id
      let made = (
        if sub == "new":
          newCredential(s, runtime, days)
        else:
          rotateCredential(s, runtime, days)
      ).valueOr:
        return err(fail(ExitUsage, error))
      let give =
        "give each peer " & made.peerFile &
        " (logosctl remote trust import @peer.cbor there)"
      let text =
        if sub == "new":
          "a TLS credential for Runtime " & runtime & ", enrolled at revision 1; " & give &
            "; logosd uses it at its next start with remote.enabled"
        else:
          "the next TLS credential, enrolled at revision " & $made.revisionOf &
            " with the new key alone, is in remote/" & NextCredentialName & "; " & give &
            "; logosd takes it up at its next start with remote.enabled. A rotation " &
            "is a cutover: connections with a peer fail until it holds the new record"
      ok(
        s.offline(
          "remote credential " & sub,
          credentialJson(made),
          text & "\n" & table(["FIELD", "VALUE"], credentialRows(made, "credential")),
        )
      )
    of "show":
      let cur = currentCredential(s).valueOr:
        return err(fail(ExitUsage, error))
      let next = pendingCredential(s).valueOr:
        return err(fail(ExitUsage, error))
      let count = readHolderCount(s).valueOr:
        return err(fail(ExitUsage, error))
      var j = %*{"credential": nil, "pending": nil, "key_holder": nil}
      var rows: seq[seq[string]]
      if cur.isSome:
        j["credential"] = credentialJson(cur.get)
        rows.add(credentialRows(cur.get, "credential"))
      else:
        rows.add(@["credential", "none (remote credential new makes one)"])
      if next.isSome:
        j["pending"] = credentialJson(next.get)
        rows.add(credentialRows(next.get, "pending rotation"))
      if count.isSome:
        j["key_holder"] = %*{"signed": count.get.signed, "refused": count.get.refused}
        rows.add(
          @[
            "key holder",
            $count.get.signed & " signed, " & $count.get.refused & " refused",
          ]
        )
      ok(s.offline("remote credential show", j, table(["FIELD", "VALUE"], rows)))
    else:
      err(usage("unknown remote credential command " & sub))

  proc exposureJson(e: LcnRemoteExposureEntry): JsonNode =
    let a = addressOf(e.listener)
    var off = newJArray()
    for f in e.offOf:
      off.add(%($f))
    %*{
      "listener": (if a.isOk: a.get.addressText else: "0x" & toHex(e.listener)),
      "provider": (if e.provider.isSome: %e.provider.get
      else: newJNull()),
      "off": off,
      "by": e.by,
      "at_ms": e.at_ms,
      "configuration_entry": e.config.isSome,
    }

  proc exposureRow(e: LcnRemoteExposureEntry): seq[string] =
    let a = addressOf(e.listener)
    @[
      (if a.isOk: a.get.addressText else: "0x" & toHex(e.listener)),
      e.provider.get("-"),
      offText(e.offOf),
      $fromUnix(int64(e.at_ms div 1000)).utc,
      e.by,
    ]

  proc cmdRemoteExposure(c: Cli, s: Session): Result[Done, Fail] =
    ## [G412; Q4] The durable disables, offline.
    let sub = ?c.arg(2, "list or reset")
    case sub
    of "list":
      let entries = readExposure(s).valueOr:
        return err(fail(ExitUsage, error))
      var a = newJArray()
      var rows: seq[seq[string]]
      for e in entries:
        a.add(exposureJson(e))
        rows.add(exposureRow(e))
      let text =
        if rows.len == 0:
          "no durable disable: each record starts as the configuration has it"
        else:
          table(["LISTENER", "PROVIDER", "OFF", "SINCE", "BY"], rows)
      ok(s.offline("remote exposure list", %*{"entries": a}, text))
    of "reset":
      let all = "all" in c.flags
      let listener = c.opt("listener")
      let provider = c.opt("provider")
      if all == listener.isSome or (all and provider.isSome):
        return err(
          usage("remote exposure reset takes --listener ADDR [--provider ID], or --all")
        )
      var lock = ?locked(s)
      defer:
        lock.release()
      let removed = resetExposure(s, listener.get(""), provider.get(""), all).valueOr:
        return err(fail(ExitUsage, error))
      if removed.len == 0 and not all:
        return err(
          fail(
            ExitUsage,
            "no durable disable of " &
              (if provider.isSome: "the export of " & provider.get & " on "
              else: "") & listener.get,
          )
        )
      var a = newJArray()
      var rows: seq[seq[string]]
      for e in removed:
        a.add(exposureJson(e))
        rows.add(exposureRow(e))
      let text =
        "removed " & $removed.len & " durable disable" &
        (if removed.len == 1: "" else: "s") & "; " & AppliesAtNextStart & (
          if rows.len > 0:
          "\n" & table(["LISTENER", "PROVIDER", "OFF", "SINCE", "BY"], rows)
          else: ""
        )
      ok(s.offline("remote exposure reset", %*{"removed": a}, text))
    else:
      err(usage("unknown remote exposure command " & sub))

  proc cmdRemote(c: Cli, s: Session): Result[Done, Fail] =
    let sub = ?c.arg(1, "a remote command")
    case sub
    of "trust":
      cmdRemoteTrust(c, s)
    of "credential":
      cmdRemoteCredential(c, s)
    of "exposure":
      cmdRemoteExposure(c, s)
    else:
      err(usage("unknown remote command " & sub))

  # Call evidence ------------------------------------------------------------------------

  proc segmentsJson(xs: seq[SegmentSummary]): (JsonNode, string) =
    var a = newJArray()
    var rows: seq[seq[string]]
    for x in xs:
      let producer = if x.header.isSome: x.header.get.producer else: ""
      let kid =
        if x.header.isSome:
          toHex(x.header.get.kid).toLowerAscii
        else:
          ""
      let boot =
        if x.header.isSome:
          $x.header.get.boot
        else:
          ""
      a.add(
        %*{
          "segment": x.name,
          "first_seq": x.first,
          "end_seq": x.endSeq,
          "records": x.records,
          "gaps": x.gaps,
          "dropped": x.dropped,
          "producer": producer,
          "kid": kid,
          "boot": (if x.header.isSome: %x.header.get.boot else: newJNull()),
          "damaged": x.damaged,
        }
      )
      rows.add(
        @[
          x.name,
          $x.first,
          $x.endSeq,
          $x.records,
          $x.dropped & (if x.damaged: " (damaged tail)" else: ""),
          producer,
          kid,
          boot,
        ]
      )
    (
      a,
      table(
        [
          "SEGMENT", "FIRST_SEQ", "END_SEQ", "RECORDS", "DROPPED", "PRODUCER", "KID",
          "BOOT",
        ],
        rows,
      ),
    )

  proc writeStdout(data: openArray[byte]): Result[void, Fail] =
    try:
      if data.len > 0:
        if stdout.writeBuffer(unsafeAddr data[0], data.len) != data.len:
          return err(fail(ExitUsage, "stdout: a short write"))
      flushFile(stdout)
      ok()
    except IOError as e:
      err(fail(ExitUsage, "stdout: " & e.msg))

  proc cmdAudit(c: Cli, s: Session): Result[Done, Fail] =
    let sub = ?c.arg(1, "an audit command")
    if sub != "evidence":
      return err(usage("unknown audit command " & sub))
    let op = ?c.arg(2, "ls or export")
    case op
    of "ls":
      let xs = summarize(s.evidenceDir).valueOr:
        return err(fail(ExitUsage, error))
      let (j, text) = segmentsJson(xs)
      ok(s.offline("audit evidence ls", %*{"segments": j}, text))
    of "export":
      let seqNo = ?c.uintOpt("seq")
      if seqNo.isNone:
        return err(usage("audit evidence export needs --seq N"))
      let outPath = c.opt("out")
      if outPath.isNone and isatty(1) != 0:
        return err(
          fail(
            ExitUsage,
            "call evidence is not written to a terminal: use --out FILE or a pipe",
          )
        )
      let container = exportStored(s, seqNo.get).valueOr:
        return err(fail(ExitUsage, error.message))
      if outPath.isSome:
        ?writeOut(outPath.get, container)
        return ok(
          s.offline(
            "audit evidence export",
            %*{"seq": seqNo.get, "out": outPath.get, "bytes": container.len},
            "seq " & $seqNo.get & ": call evidence written to " & outPath.get,
          )
        )
      ?writeStdout(container)
      var d = s.offline("audit evidence export", newJNull(), "")
      d.raw = true
      ok(d)
    else:
      err(usage("unknown audit evidence command " & op))

  proc stateFail(e: StateError): Fail =
    fail(ExitUsage, e.message, code = $e.code)

  proc entriesJson(xs: seq[StateEntry]): (JsonNode, string) =
    var j = newJArray()
    var lines: seq[string] = @[]
    for x in xs:
      j.add(
        %*{
          "name": x.name,
          "holder": $x.holder,
          "instance": x.instance,
          "present": x.present,
          "link": x.link,
          "bytes": x.bytes,
          "files": x.files,
          "origin": x.origin,
          "moved": x.moved,
        }
      )
      var line = x.name & "  " & $x.holder
      if x.instance.len > 0:
        line.add(" " & x.instance)
      if x.present:
        line.add("  " & $x.bytes & " bytes in " & $x.files & " files")
        if x.link:
          line.add(" (a symbolic link)")
      else:
        line.add("  no directory")
      if x.origin.len > 0:
        line.add("  " & x.origin)
      if x.moved.len > 0:
        line.add("  " & x.moved)
      lines.add(line)
    (j, (if lines.len == 0: "no module state" else: lines.join("\n")))

  proc cmdState(c: Cli, s: Session): Result[Done, Fail] =
    ## [G143; I96 part 7c] Offline: the session's lock, then the store's.
    let sub = ?c.arg(1, "list or purge")
    case sub
    of "list":
      var lock = ?locked(s)
      defer:
        lock.release()
      let xs = listState(s.storeDir, s.modulesDir).valueOr:
        return err(stateFail(error))
      let (j, text) = entriesJson(xs)
      ok(s.offline("state list", %*{"entries": j}, text))
    of "purge":
      let assignment = c.opt("assignment")
      let instance =
        if c.args.len > 2:
          Opt.some(c.args[2])
        else:
          Opt.none(string)
      if instance.isSome == assignment.isSome:
        return err(usage("state purge needs an instance or --assignment A"))
      var lock = ?locked(s)
      defer:
        lock.release()
      let (dc, _) = readDaemonConfig(s).valueOr:
        return err(fail(ExitUsage, error))
      var configured: seq[string] = @[]
      for m in dc.modules.get(@[]):
        if m.state_assignment.isSome:
          configured.add(m.state_assignment.get)
      if "yes" notin c.flags:
        if isatty(0) == 0:
          return
            err(fail(ExitUsage, "state purge deletes module state for good: add --yes"))
        let what =
          if instance.isSome:
            "the preserved state of retired instance " & instance.get
          else:
            "the state directory " & assignment.get
        say("logosctl: delete " & what & " for good? [y/N]")
        var answer = ""
        try:
          answer = stdin.readLine()
        except IOError:
          discard
        if answer.strip.toLowerAscii notin ["y", "yes"]:
          return err(fail(ExitUsage, "nothing purged"))
      let p = purgeState(s.storeDir, s.modulesDir, instance, assignment, configured).valueOr:
        return err(stateFail(error))
      let text =
        if p.removed:
          "purged " & p.dir & ": " & $p.bytes & " bytes in " & $p.files & " files"
        else:
          "nothing to purge: " & p.dir & " does not exist"
      ok(
        s.offline(
          "state purge",
          %*{
            "assignment": p.assignment,
            "dir": p.dir,
            "removed": p.removed,
            "bytes": p.bytes,
            "files": p.files,
          },
          text,
        )
      )
    else:
      err(usage("unknown state command " & sub))

  # Main --------------------------------------------------------------------------------

  proc parse(): Result[Cli, Fail] =
    var c = Cli(timeoutMs: DefaultTimeoutMs)
    var p = initOptParser(commandLineParams(), longNoVal = @NoValue)
    while true:
      p.next()
      case p.kind
      of cmdEnd:
        break
      of cmdLongOption, cmdShortOption:
        if p.key in NoValue:
          c.flags.incl(p.key)
        elif p.val.len == 0:
          return err(usage("--" & p.key & " takes a value"))
        else:
          c.opts.mgetOrPut(p.key, @[]).add(p.val)
      of cmdArgument:
        c.args.add(p.key)
    if "json" in c.flags and "text" in c.flags:
      return err(usage("--json and --text exclude each other"))
    c.json = "json" in c.flags or ("text" notin c.flags and isatty(1) == 0)
    let sd = c.opt("session-dir")
    if sd.isSome:
      c.sessionFlag = sd.get
    let t = ?c.uintOpt("timeout")
    if t.isSome:
      if t.get < 1 or t.get > 3_600_000'u64:
        return err(usage("--timeout is 1 to 3600000 ms"))
      c.timeoutMs = int(t.get)
    ok(c)

  proc emit(c: Cli, d: Done) =
    if d.raw:
      return
    if c.json:
      show(
        $envelope(d.deployment, d.command, true, requestKey = d.requestKey).withResult(
          d.result
        )
      )
    else:
      if d.deployment == "non-production":
        show("NON-PRODUCTION deployment: the development switch is on")
      if d.text.len > 0:
        show(d.text)

  proc emitFail(c: Cli, command, deployment: string, f: Fail) =
    if c.json:
      show(
        $envelope(deployment, command, false, f.code, f.message, f.requestKey)
          .withResult(f.result)
      )
    else:
      if deployment == "non-production":
        say("NON-PRODUCTION deployment: the development switch is on")
      say("logosctl: " & (if f.code.len > 0: f.code & ": " else: "") & f.message)

  proc main(): int =
    let c = parse().valueOr:
      say("logosctl: " & error.message)
      return error.exit
    if "version" in c.flags or (c.args.len > 0 and c.args[0] == "version"):
      show("logosctl " & lcnVersion)
      return ExitOk
    if "help" in c.flags or c.args.len == 0:
      show(Usage)
      return (if c.args.len == 0 and "help" notin c.flags: ExitUsage else: ExitOk)
    let s = resolveSession(c.sessionFlag).valueOr:
      c.emitFail(c.args[0], "unknown", fail(ExitUsage, error))
      return ExitUsage
    let command = c.args.join(" ")
    if c.args[0] in ["call", "describe", "subscribe", "events"]:
      let r = cmdLaunch(c, s)
      if r.isErr:
        if r.error.exit != ExitInterrupted:
          c.emitFail(command, "unknown", r.error)
        return r.error.exit
      return r.get
    let r =
      case c.args[0]
      of "init":
        cmdInit(c, s)
      of "trust":
        cmdTrust(c, s)
      of "remote":
        cmdRemote(c, s)
      of "audit":
        cmdAudit(c, s)
      of "state":
        cmdState(c, s)
      of "daemon":
        if c.args.len > 1 and c.args[1] == "config":
          cmdDaemonConfig(c, s)
        elif c.args.len > 1 and c.args[1] == "stop":
          online(c, s)
        else:
          Result[Done, Fail].err(usage("unknown daemon command"))
      else:
        online(c, s)
    if r.isErr:
      let deployment =
        if c.args[0] in ["init", "trust", "remote", "audit", "state"]:
          offlineDeployment(s)
        else:
          "unknown"
      c.emitFail(command, deployment, r.error)
      return r.error.exit
    c.emit(r.get)
    ExitOk

else:
  proc main(): int =
    if "version" in commandLineParams():
      show("logosctl " & lcnVersion)
      return 0
    say("logosctl: not supported on this platform (logosd's socket needs unix-stream)")
    2

when isMainModule:
  # [IMPL] Not `quit`: it saturates at `high(int8)` on POSIX (Nim's system.nim),
  # so 130 would leave as 127. exit(3) keeps the low 8 bits and still runs the
  # exit procedures and flushes stdio.
  proc cExit(code: cint) {.importc: "exit", header: "<stdlib.h>", noreturn.}
  cExit(cint(main()))

{.pop.}
