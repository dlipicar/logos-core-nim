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
## read-only, while logosd runs or not (G301; DAEMON.md §9).
##
## | Exit | Meaning |
## |---|---|
## | 0 | done |
## | 1 | usage, a refused frame or command, an offline command that failed |
## | 2 | no daemon, busy, or the outcome unknown |
## | 4 | the Runtime Control call failed: its code and message |

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
  import ./logos_core/base/hex
  import ./logos_core/cbor
  import ./logos_core/durable
  import ./logos_core/iface/outcome
  import ./logos_core/runtime/rc_types
  import
    ./logos_core/daemon/[
      compose, ctlwire, evexport, evkey, evstore, render, session, sessioninit,
      trustfile,
    ]

  const
    Usage =
      """usage: logosctl [--session-dir DIR] [--json | --text] [--timeout MS] <command> ...

online (through logosd's socket):
  status
  module ls [--module M]
  module status MODULE [--instance I]
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

offline (the session's files; writers hold its lock):
  init [--config @FILE] [--policy @FILE] [--module-config INSTANCE=@FILE]... [--development]
  init --print-template
  daemon config get [--format diag|cbor] [--out FILE]
  daemon config check [@FILE]
  daemon config set @FILE
  daemon config module-config INSTANCE (@FILE | --remove)
  trust show
  trust development on|off
  trust reestablish --revision N
  trust evidence-keys ls|rotate
  audit evidence ls
  audit evidence export --seq N [--out FILE]
  version"""
    DefaultTimeoutMs = 65_000
    ExitOk = 0
    ExitUsage = 1
    ExitUnreachable = 2
    ExitRc = 4
    NoValue = [
      "json", "text", "wait", "development", "remove", "print-template", "help",
      "version",
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
      return ok(encodeCbor(v))
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
      return err((fail(ExitUnreachable, "no reply: " & error.message), true))
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

  proc cmdModule(cl: var Client, c: Cli): Result[Done, Fail] =
    let sub = ?c.arg(1, "a module command")
    case sub
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
      let x = LogosNSRuntimeControlCreateModuleResponse.decode(bytes).valueOr:
        return err(fail(ExitRc, "the response does not decode: " & error, $ecModule))
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
        let (x, bytes) = ?cl.callTyped(
          LcnCtlMethodKind.Start_module, req, LogosNSRuntimeControlStartModuleResponse
        )
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
        let (x, bytes) = ?cl.callTyped(
          LcnCtlMethodKind.Stop_module, req, LogosNSRuntimeControlStopModuleResponse
        )
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
        let (x, bytes) = ?cl.callTyped(
          LcnCtlMethodKind.Recover_module, req,
          LogosNSRuntimeControlRecoverModuleResponse,
        )
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
        let (_, bytes) = ?cl.callTyped(
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
      let (x, bytes) = ?cl.callTyped(
        LcnCtlMethodKind.Update_configuration, req,
        LogosNSRuntimeControlUpdateConfigurationResponse,
      )
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
      let (x, bytes) = ?cl.callTyped(
        LcnCtlMethodKind.Apply_configuration,
        LogosNSRuntimeControlApplyConfigurationRequest(
          target: t, expected_state_revision: rev.get
        ),
        LogosNSRuntimeControlApplyConfigurationResponse,
      )
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

  proc cmdTrust(c: Cli, s: Session): Result[Done, Fail] =
    let sub = ?c.arg(1, "a trust command")
    case sub
    of "show":
      let t = readTrust(s).valueOr:
        return err(fail(ExitUsage, error))
      let mark = readMark(s).valueOr:
        return err(fail(ExitUsage, error))
      let continuity = block:
        let d = decide(t, mark)
        if d.isErr:
          "refused: " & d.error
        elif d.get == cAccept:
          "accepted (the revision in use)"
        else:
          "accepted at the next start (a higher revision)"
      var j = %*{
        "revision": t.file.revision,
        "development": t.file.development,
        "file": t.present,
        "continuity": continuity,
      }
      if mark.isSome:
        j["mark"] = %*{
          "revision": mark.get.revision, "digest": toHex(mark.get.digest).toLowerAscii
        }
      let text = table(
        ["FIELD", "VALUE"],
        [
          @[
            "revision",
            $t.file.revision & (if t.present: "" else: " (the floor; no file)"),
          ],
          @["development", (if t.file.development: "on" else: "off")],
          @["mark", (if mark.isSome: $mark.get.revision else: "none")],
          @["continuity", continuity],
        ],
      )
      ok(s.offline("trust show", j, text))
    of "development":
      let v = ?c.arg(2, "on or off")
      if v notin ["on", "off"]:
        return err(usage("trust development takes on or off"))
      var lock = ?locked(s)
      defer:
        lock.release()
      let t = setDevelopment(s, v == "on").valueOr:
        return err(fail(ExitUsage, error))
      ok(
        s.offline(
          "trust development",
          %*{"revision": t.file.revision, "development": t.file.development},
          "trust revision " & $t.file.revision & ": development switch " & v &
            "; it applies at the next start",
        )
      )
    of "reestablish":
      let rev = ?c.uintOpt("revision")
      if rev.isNone:
        return err(usage("trust reestablish needs --revision N"))
      var lock = ?locked(s)
      defer:
        lock.release()
      let t = reestablish(s, rev.get).valueOr:
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
      show($envelope(deployment, command, false, f.code, f.message, f.requestKey))
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
    let r =
      case c.args[0]
      of "init":
        cmdInit(c, s)
      of "trust":
        cmdTrust(c, s)
      of "audit":
        cmdAudit(c, s)
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
        if c.args[0] in ["init", "trust", "audit"]:
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
  quit(main())

{.pop.}
