## lcn_call's commands (Tier 5 step N-2; DECISIONS G347, G348, G349): what one
## launcher request does, on one of lcn_call's workers. docs/DAEMON.md §7a.
##
## - **Target** (G347). `local`, lcn_call's own binding, is the only node in
##   N-2; another name is refused, as is the reserved `rc` op, until remote
##   Runtimes come (Tier 5 step 5-7a). `targetBinding` is that seam.
## - **Provider.** `list_modules` names the instance's record: a local
##   provider, ready. `describe_provider` gives its call surface, validated as
##   any consumer validates one (`acceptCallSurfaceDescriptor`); the Runtime
##   describes a provider only if every one of its contracts may be discovered
##   (R l.454), and its refusal is printed as it came.
## - **Contract.** The primary contract, or the implemented interface
##   `--contract` names. The surface projected to it (`schemaResponse`) is
##   accepted again (`acceptSchemaResponse`): the set the arguments are typed
##   by, and the bytes `materialize_route` takes (IF l.3874).
## - **Call.** The method by its bare or its qualified name. A marked request
##   or response is refused before any route (IF l.388-389). The arguments are
##   typed (`args.nim`), the value validated, and the call made through a
##   leased route (`routes.nim`) with the command's deadline; one made on a
##   route that ended meanwhile is made once more on a new route.
## - **Exit codes** (G349): 1 refused before anything was called, 4 a Runtime
##   Control failure, 5 the call's error channel, 130 the launcher cancelled
##   (nothing more is written). An output the reader closed ends the command
##   with 0; one that cannot be written, with 2 (the user has not seen the
##   outcome).

{.push raises: [], gcsafe.}

import std/[json, strutils]
import results
import logos_sdk/cbor
import logos_sdk/commitment
import logos_sdk/base/hex
import logos_sdk/hash/hashinput
import logos_sdk/iface/[accept, provider, surface]
import logos_sdk/kit/rc_types
import ./[args, cli_types, present, routes, rpc, wire]

when defined(posix):
  import std/posix

export results

const
  MaxFileBytes* = 16 * 1024 * 1024 ## [G349] one `@FILE`, the transport frame
  MaxListPages = 64 ## [IMPL] `list_modules` pages read for one module
  ReadChunk = 65_536

type
  Env* = object ## What every command shares; plain values, copied per worker.
    rc*: ptr LogosRuntimeControlBinding
    routes*: RouteTable
    production*: bool

  Job* = object ## One admitted request.
    msg*: LcnCliMessage
    fds*: seq[cint] ## as received: stdout, stderr, then one per `@FILE`
    cancelFd*: cint ## the launcher's connection: readable means cancel

  Done* = object ## A command's end, for the reply and the log line.
    exit*: int
    what*: string ## the op and `module.method` or `module.event`: metadata only
    code*: string ## the error channel's code, or ""

  Stop = object ## Why a command ends early.
    exit: int
    code: string
    message: string
    detail: Opt[seq[byte]]
    declared: bool ## the message is a provider's text
    silent: bool ## cancelled: nothing more is written

  Ctx = object
    env: Env
    rc: ptr LogosRuntimeControlBinding ## the target's binding
    target: string
    pres: Presenter
    fds: seq[cint]
    cancelFd: cint
    deadline: Opt[int]

  Provider = object ## The selected provider and contract.
    module, instance: string
    address: LogosNSRuntimeModuleProviderAddress
    binding: ModuleBinding
    selected: Digest
    set: ContractSet
    surface: CallSurface
    schema: seq[byte] ## the encoded projected `logos.schema_response`

func refused(message: string): Stop =
  Stop(exit: ExitRefused, message: message)

func cancelled(): Stop =
  Stop(exit: ExitInterrupted, silent: true)

func rcStop(f: Failure): Stop =
  if f.code == ecCancelled:
    return cancelled()
  Stop(exit: ExitRc, code: $f.code, message: f.message, detail: f.detail)

func hexOf(d: Digest): string =
  toHex(d)

func digestOf(b: openArray[byte]): Opt[Digest] =
  if b.len != 32:
    return Opt.none(Digest)
  var d: Digest
  for i in 0 ..< 32:
    d[i] = b[i]
  Opt.some(d)

func stateText(s: LogosNSRuntimeControlState): string =
  ($s.kind).toLowerAscii

func providerText(a: LogosNSRuntimeModuleProviderAddress): string =
  if a.runtime_instance_id.isSome:
    a.provider & "@" & a.runtime_instance_id.get
  else:
    a.provider

# Targets (G347) ------------------------------------------------------------------------

proc targetBinding(
    env: Env, name: string
): Result[ptr LogosRuntimeControlBinding, Stop] =
  ## [G347] The binding a node name stands for: `local` only, until 5-7a.
  if not validNodeName(name):
    return err(refused("a node name is [a-z][a-z0-9_-], at most 63 bytes"))
  if name != LocalNode:
    return err(
      refused(
        "unknown node " & name & " (other nodes need remote Runtimes, Tier 5 step 5-7a)"
      )
    )
  ok(env.rc)

# Input -----------------------------------------------------------------------------------

proc readAll(fd, cancelFd: cint, what: string): Result[seq[byte], Stop] =
  ## A passed descriptor's bytes to its end, at most `MaxFileBytes`.
  when defined(posix):
    var data: seq[byte] = @[]
    var buf = newSeq[byte](ReadChunk)
    while true:
      var p: array[2, TPollfd]
      p[0] = TPollfd(fd: fd, events: POLLIN)
      p[1] = TPollfd(fd: cancelFd, events: POLLIN)
      let n = poll(addr p[0], Tnfds(if cancelFd >= 0: 2 else: 1), -1)
      if n < 0:
        if errno == EINTR:
          continue
        return err(refused(what & ": poll: " & $strerror(errno)))
      if cancelFd >= 0 and (p[1].revents and (POLLIN or POLLHUP or POLLERR)) != 0:
        return err(cancelled())
      let r = read(fd, addr buf[0], buf.len)
      if r < 0:
        if errno == EINTR or errno == EAGAIN or errno == EWOULDBLOCK:
          continue
        return err(refused(what & ": " & $strerror(errno)))
      if r == 0:
        break
      if data.len + r > MaxFileBytes:
        return err(refused(what & " is larger than 16 MiB"))
      data.add(buf.toOpenArray(0, r - 1))
    ok(data)
  else:
    err(refused("@FILE is not supported on this platform"))

proc argInputs(c: Ctx, args: seq[LcnCliArg]): Result[seq[ArgInput], Stop] =
  var out0: seq[ArgInput] = @[]
  for a in args:
    case a.kind
    of LcnCliArgKind.lcn_Cli_text_arg:
      let t = a.arm_lcn_Cli_text_arg
      out0.add(ArgInput(name: t.name, isFile: false, text: t.value))
    of LcnCliArgKind.lcn_Cli_file_arg:
      let f = a.arm_lcn_Cli_file_arg
      let i = int(f.fd)
      if i < 2 or i >= c.fds.len:
        return err(refused(f.name & ": no such descriptor"))
      let data = ?readAll(c.fds[i], c.cancelFd, f.name & "=@FILE")
      out0.add(ArgInput(name: f.name, isFile: true, data: data))
  ok(out0)

# The provider ----------------------------------------------------------------------------

proc findRecord(
    c: Ctx, module: string, instance: Opt[string]
): Result[LogosNSRuntimeControlModuleRecord, Stop] =
  ## [SPEC RUNTIME list_modules] The one record `module` (and `instance`) name.
  var found: seq[LogosNSRuntimeControlModuleRecord] = @[]
  var cursor = Opt.none(string)
  for _ in 0 ..< MaxListPages:
    let req = LogosNSRuntimeControlListModulesRequest(
      module: Opt.some(module), instance: instance, cursor: cursor
    )
    let r = rcCall(
      c.rc, "list_modules", req, LogosNSRuntimeControlListModulesResponse, c.cancelFd
    ).valueOr:
      return err(rcStop(error))
    for m in r.modules:
      if m.module == module and (instance.isNone or m.instance == instance):
        found.add(m)
    if r.next_cursor.isNone:
      break
    cursor = r.next_cursor
  if found.len == 0:
    if instance.isSome:
      return err(refused("no instance " & instance.get & " of module " & module))
    return err(refused("no module " & module))
  if found.len > 1:
    var names: seq[string] = @[]
    for m in found:
      names.add(m.instance.get("(no instance)"))
    return err(
      refused(
        module & " has several instances (" & names.join(", ") &
          "): name one with --instance"
      )
    )
  let rec = found[0]
  if rec.state.kind != LogosNSRuntimeControlStateKind.Ready:
    var msg = module & " is " & rec.state.stateText
    if rec.failure.isSome:
      msg.add(" (" & rec.failure.get & ")")
    if rec.reason.isSome:
      msg.add(": " & rec.reason.get)
    return err(Stop(exit: ExitRc, code: $ecNotReady, message: msg))
  if rec.provider.isNone:
    return err(
      refused(
        module & " has no local provider (remote providers come with Tier 5 step 5-7a)"
      )
    )
  ok(rec)

proc describe(
    c: Ctx, address: LogosNSRuntimeModuleProviderAddress, module: string
): Result[ModuleBinding, Stop] =
  ## [SPEC RUNTIME describe_provider; INTERFACE §2.6] The provider's validated
  ## call surface. [IMPL] A `logos_` module name is a Logos system module.
  let req = LogosNSRuntimeControlDescribeProviderRequest(provider: address)
  let r = rcCall(
    c.rc, "describe_provider", req, LogosNSRuntimeControlDescribeProviderResponse,
    c.cancelFd,
  ).valueOr:
    return err(rcStop(error))
  let b = acceptCallSurfaceDescriptor(
    r.surface, module, AcceptOptions(system: module.startsWith("logos_"))
  ).valueOr:
    return err(
      Stop(
        exit: ExitRc,
        code: $ecModule,
        message: "the call surface of " & module & " does not validate: " & error,
      )
    )
  ok(b)

func roots(b: ModuleBinding): seq[Digest] =
  if b.primary.isSome:
    result.add(b.primary.get.root)
  for i in b.interfaces:
    result.add(i.root)

proc project(p: var Provider, selected: Digest): Result[void, Stop] =
  ## [SPEC INTERFACE §5.1] The surface projected to `selected`, accepted again.
  let v = schemaResponse(p.binding, selected).valueOr:
    return err(refused(p.module & ": " & error))
  let bytes = encodeCbor(v)
  let set = acceptSchemaResponse(
    bytes, selected, AcceptOptions(system: p.module.startsWith("logos_"))
  ).valueOr:
    return err(
      Stop(
        exit: ExitRc,
        code: $ecModule,
        message:
          "the projected contract of " & p.module & " does not validate: " & error,
      )
    )
  p.selected = selected
  p.set = set
  p.surface = callSurface(set)
  p.schema = bytes
  ok()

proc provider(c: Ctx, sel: LcnCliProvider): Result[Provider, Stop] =
  let rec = ?c.findRecord(sel.module, sel.instance)
  var p = Provider(
    module: sel.module,
    instance: rec.instance.get(""),
    address: rec.provider.get,
    binding: ?c.describe(rec.provider.get, sel.module),
  )
  if sel.contract.isSome:
    let want = digestOf(sel.contract.get).valueOr:
      return err(refused("--contract is 32 bytes"))
    if want notin p.binding.roots:
      var names: seq[string] = @[]
      for r in p.binding.roots:
        names.add(hexOf(r))
      return err(
        refused(
          sel.module & " has no contract " & hexOf(want) & "; its contracts: " &
            names.join(", ")
        )
      )
    ?p.project(want)
  elif p.binding.primary.isSome:
    ?p.project(p.binding.primary.get.root)
  else:
    var names: seq[string] = @[]
    for i in p.binding.interfaces:
      names.add(i.model.namespace & " " & hexOf(i.root))
    return err(
      refused(
        sel.module & " has no primary contract: name one of its interfaces with " &
          "--contract (" & names.join(", ") & ")"
      )
    )
  ok(p)

func outputStop(e: SinkError): Stop =
  case e
  of seCancelled:
    cancelled()
  of seClosed:
    Stop(exit: ExitOk, silent: true)
  of seIo:
    Stop(exit: ExitUnreachable, silent: true)

# describe ------------------------------------------------------------------------------

proc describeOne(p: Provider): (JsonNode, JsonNode, seq[string]) =
  ## The selected contract's methods and events, as JSON and text lines.
  var methods = newJArray()
  var events = newJArray()
  var lines: seq[string] = @[]
  for m in p.surface.methods:
    let req = requestShape(p.set, m)
    let resp = responseShape(p.set, m)
    let reqText = (if req.isOk: req.get.fieldList else: "?")
    let respText = (if resp.isOk: resp.get.ruleText else: "?")
    let marked = m.sensitiveRequest or m.sensitiveResponse
    methods.add(
      %*{
        "method": m.bare,
        "name": m.name,
        "contract": hexOf(m.contract),
        "request": reqText,
        "response": respText,
        "marked": marked,
      }
    )
    lines.add(
      "  " & m.bare & " " & reqText & " -> " & respText &
        (if marked: "  [marked: not callable through this CLI]" else: "")
    )
  for e in p.surface.events:
    let sh = eventShape(p.set, e)
    let t = (if sh.isOk: sh.get.ruleText else: "?")
    events.add(%*{"event": e.id, "contract": hexOf(e.contract), "payload": t})
    lines.add("  event " & e.id & ": " & t)
  (methods, events, lines)

proc runDescribe(c: Ctx, sel: LcnCliProvider): Result[void, Stop] =
  ## [G349] The provider's contracts, methods and events.
  let p = ?c.provider(sel)
  let (methods, events, lines) = describeOne(p)
  var contracts = newJArray()
  var rows: seq[(string, Contract)] = @[]
  if p.binding.primary.isSome:
    rows.add(("primary", p.binding.primary.get))
  for x in p.binding.interfaces:
    rows.add(("interface", x))
  var text =
    p.module & (if p.instance.len > 0: " (instance " & p.instance & ")"
    else: "") & " on node " & c.target & ", provider " & providerText(p.address)
  for (role, x) in rows:
    contracts.add(
      %*{"role": role, "namespace": x.model.namespace, "root": hexOf(x.root)}
    )
    text.add(
      "\n" & role & " " & x.model.namespace & " " & hexOf(x.root) &
        (if x.root == p.selected: " (selected)" else: "")
    )
  let result0 = %*{
    "module": p.module,
    "instance": p.instance,
    "provider": providerText(p.address),
    "node": c.target,
    "selected": hexOf(p.selected),
    "contracts": contracts,
    "methods": methods,
    "events": events,
  }
  if lines.len > 0:
    text.add("\n" & lines.join("\n"))
  c.pres.done(result0, text).isOkOr:
    return err(outputStop(error))
  ok()

# call --------------------------------------------------------------------------------------

func findMethod(s: CallSurface, name: string): Opt[SurfaceMethod] =
  ## By bare name, else by qualified name.
  let b = s.findMethod(name)
  if b.isSome:
    return b
  for m in s.methods:
    if m.name == name:
      return Opt.some(m)
  Opt.none(SurfaceMethod)

func methodNames(s: CallSurface): string =
  var names: seq[string] = @[]
  for m in s.methods:
    names.add(m.bare)
  if names.len == 0:
    "(none)"
  else:
    names.join(", ")

func routeKey*(
    target: string,
    address: LogosNSRuntimeModuleProviderAddress,
    contract: Digest,
    kind: string,
    member: Digest,
): Digest =
  ## [G348] One route per (target, provider, selected contract, access kind,
  ## member root).
  digestOfInput(
    encodeCbor(
      cborArray(
        cbor(target),
        cbor(address.provider),
        cbor(address.runtime_instance_id.get("")),
        cbor(@contract),
        cbor(kind),
        cbor(@member),
      )
    )
  )

proc memberRoot(p: Provider, doc: int, name: string): Result[Digest, Stop] =
  ## [SPEC COMMITMENT §9.2] The declaration root a route's access names.
  let docs = p.set.documents
  if doc < 0 or doc >= docs.len:
    return err(refused(name & " names no document"))
  let model = docs[doc].model
  let d = model.find(name).valueOr:
    return err(refused(name & " is not declared"))
  ok(declarationRoot(model, d))

proc runCall(c: Ctx, cmd: LcnCliCallCommand): Result[void, Stop] =
  ## [G348, G349] One typed call through a leased route.
  let p = ?c.provider(cmd.provider)
  let m = p.surface.findMethod(cmd.`method`).valueOr:
    return err(
      refused(
        p.module & " has no method " & cmd.`method` & "; its methods: " &
          p.surface.methodNames
      )
    )
  if m.sensitiveRequest or m.sensitiveResponse:
    # [SPEC INTERFACE l.388-389; G349 Q2] No path for marked payloads here.
    return err(
      refused(m.bare & " carries marked payloads; this CLI does not handle them yet")
    )
  let sh = requestShape(p.set, m).valueOr:
    return err(refused(error))
  var value: CborValue
  if cmd.json.isSome:
    value = fromJson(sh, cmd.json.get).valueOr:
      return err(refused(m.bare & ": " & error & "; fields: " & sh.fieldList))
  else:
    let inputs = ?c.argInputs(cmd.args.get(@[]))
    value = fromArgs(sh, inputs).valueOr:
      return err(refused(m.bare & ": " & error & "; fields: " & sh.fieldList))
  checkRequest(sh, value).isOkOr:
    return err(refused(error))
  let params = encodeCbor(value)
  let root = ?p.memberRoot(m.doc, m.name)
  let spec = RouteSpec(
    key: routeKey(c.target, p.address, p.selected, "methods", root),
    contract: p.selected,
    provider: p.address,
    access: LogosNSRuntimeControlRouteAccess(methods: Opt.some(@[@root])),
    schema: p.schema,
  )
  var outcome: CallResult
  for attempt in 0 .. 1:
    let lease = c.env.routes.acquire(spec, c.cancelFd).valueOr:
      return err(rcStop(error))
    outcome = callRoute(lease.route, lease.lock, m.bare, params, c.deadline, c.cancelFd)
    let ended = c.env.routes.ended(lease)
    c.env.routes.done(lease)
    if outcome.cancelled or outcome.ok or not ended or attempt == 1:
      break
  if outcome.cancelled:
    return err(cancelled())
  if not outcome.ok:
    let f = outcome.failure
    return err(
      Stop(
        exit: ExitProvider,
        code: $f.code,
        message: f.message,
        detail: f.detail,
        declared: true,
      )
    )
  let v = decodeCbor(outcome.response).valueOr:
    return err(
      Stop(
        exit: ExitProvider,
        code: $ecModule,
        message: "the response is not Logos deterministic CBOR",
      )
    )
  c.pres.doneValue(v).isOkOr:
    return err(outputStop(error))
  ok()

# A request ---------------------------------------------------------------------------------

func what(cmd: LcnCliCommand): string =
  case cmd.kind
  of LcnCliCommandKind.lcn_Cli_call_command:
    let x = cmd.arm_lcn_Cli_call_command
    "call " & x.provider.module & "." & x.`method`
  of LcnCliCommandKind.lcn_Cli_describe_command:
    "describe " & cmd.arm_lcn_Cli_describe_command.provider.module
  of LcnCliCommandKind.lcn_Cli_subscribe_command:
    let x = cmd.arm_lcn_Cli_subscribe_command
    "subscribe " & x.provider.module & "." & x.event
  of LcnCliCommandKind.lcn_Cli_events_command:
    "events"
  of LcnCliCommandKind.lcn_Cli_rc_command:
    "rc " & cmd.arm_lcn_Cli_rc_command.`method`

proc run*(env: Env, job: Job): Done =
  ## [G344-G349] One request: its output written to the launcher's
  ## descriptors, its exit code returned. The descriptors stay open; the
  ## caller closes them before it answers `done`.
  let what0 = what(job.msg.command)
  var c = Ctx(
    env: env,
    target: targetOf(job.msg),
    fds: job.fds,
    cancelFd: job.cancelFd,
    deadline: (
      if job.msg.deadline_ms.isSome: Opt.some(int(job.msg.deadline_ms.get))
      else: Opt.none(int)
    ),
    pres: Presenter(
      json: job.msg.isJson,
      deployment: (if env.production: "production" else: "non-production"),
      command: what0,
      output: sinkOf(job.fds[0], job.cancelFd),
      errors: sinkOf(job.fds[1], job.cancelFd),
    ),
  )
  type R = Result[void, Stop]
  var r = R.ok()
  block run0:
    if job.msg.command.kind == LcnCliCommandKind.lcn_Cli_rc_command:
      r = R.err(refused("the rc op comes with remote Runtimes (Tier 5 step 5-7a)"))
      break run0
    let b = targetBinding(env, c.target)
    if b.isErr:
      r = R.err(b.error)
      break run0
    c.rc = b.get
    case job.msg.command.kind
    of LcnCliCommandKind.lcn_Cli_call_command:
      r = runCall(c, job.msg.command.arm_lcn_Cli_call_command)
    of LcnCliCommandKind.lcn_Cli_describe_command:
      r = runDescribe(c, job.msg.command.arm_lcn_Cli_describe_command.provider)
    of LcnCliCommandKind.lcn_Cli_subscribe_command,
        LcnCliCommandKind.lcn_Cli_events_command:
      r = R.err(refused("streams come with Tier 5 step N-2c"))
    of LcnCliCommandKind.lcn_Cli_rc_command:
      r = R.err(refused("the rc op comes with remote Runtimes (Tier 5 step 5-7a)"))
  if r.isOk:
    return Done(exit: ExitOk, what: what0)
  let s = r.error
  if not s.silent:
    discard c.pres.failed(s.code, s.message, s.detail, s.declared)
  Done(exit: s.exit, what: what0, code: s.code)

{.pop.}
