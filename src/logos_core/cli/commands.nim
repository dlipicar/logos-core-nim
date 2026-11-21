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
##   (R l.428), and its refusal is printed as it came.
## - **Contract.** The primary contract, or the exact contract view
##   `--contract` names: an implemented interface or an earlier contract the
##   provider extends (R l.90-91). The surface projected to it (`schemaResponse`) is
##   accepted again (`acceptSchemaResponse`): the set the arguments are typed
##   by, and the bytes `materialize_route` takes (IF l.3905).
## - **Call.** The method by its bare or its qualified name. A marked request
##   or response is refused before any route (IF l.368-369). The arguments are
##   typed (`args.nim`), the value validated, and the call made through a
##   leased route (`routes.nim`) with the command's deadline.
## - **Retry (G348; plan §3.5 step 8).** An ended handle is never leased (rule
##   1). A call is made once more, on a new route and within what remains of
##   the deadline, only when `prepare_call` failed with NOT_READY,
##   NOT_AUTHORISED or TRANSPORT_ERROR, or its completion is NOT_READY or
##   NOT_AUTHORISED (rule 2): those come before the call is sent, or from the
##   provider's boundary before dispatch, and provider code cannot answer them
##   (IF l.3308-3311). A completion TRANSPORT_ERROR, TIMEOUT or CANCELLED is
##   never retried (rule 3): an admitted call its route's end interrupts may
##   have run (R l.1271-1272).
## - **Exit codes** (G349): 1 refused before anything was called, 2 the
##   outcome unknown, 4 a Runtime Control failure or a code the classifier
##   does not name, 5 the call's error channel, 130 the launcher cancelled
##   (nothing more is written). An output the reader closed ends the command
##   with 0; one that cannot be written, with 2 (the user has not seen the
##   outcome).

{.push raises: [], gcsafe.}

import std/[algorithm, atomics, json, locks, monotimes, strutils, tables, times]
import results
import logos_sdk/cbor
import logos_sdk/commitment
import logos_sdk/base/hex
import logos_sdk/hash/hashinput
import logos_sdk/iface/[accept, provider, surface]
import logos_sdk/kit/rc_types
import logos_sdk/abi/[checks, types]
import logos_sdk/iface/outcome
from ../authority/scopes import rcContractInfo
import ../daemon/render
import ./[args, cli_types, present, routes, rpc, streams, wire]

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
    hub*: Hub ## the streams' (`streams.nim`)
    stopping*: ptr Atomic[bool] ## the server's: lcn_call is stopping; nil: never
    production*: bool

  Job* = object ## One admitted request.
    msg*: LcnCliMessage
    fds*: seq[cint] ## as received: stdout, stderr, then one per `@FILE`
    cancelFd*: cint ## the launcher's connection: readable means cancel

  Done* = object ## A command's end, for the reply and the log line.
    exit*: int
    what*: string ## the op and `module.method` or `module.event`: metadata only
    code*: string ## the error channel's code, or ""

  Stop* = object ## Why a command ends early.
    exit*: int
    code*: string
    message*: string
    detail*: Opt[seq[byte]]
    declared*: bool ## the message is a provider's text
    silent*: bool ## cancelled: nothing more is written

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
    record: LogosNSRuntimeControlModuleRecord ## `list_modules`' record

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

func contractViews*(b: ModuleBinding): seq[Digest] =
  ## [SPEC RUNTIME l.90-91] Every exact contract view: the primary, the
  ## interfaces and the earlier contracts the provider extends.
  if b.primary.isSome:
    result.add(b.primary.get.root)
  for i in b.interfaces:
    result.add(i.root)
  for e in b.extends:
    result.add(e.root)

proc projectView*(
    b: ModuleBinding, module: string, selected: Digest
): Result[(ContractSet, seq[byte]), Stop] =
  ## [SPEC INTERFACE §5.1; R l.90-91] The surface projected to the exact
  ## contract view `selected` (primary, interface or extended), accepted again:
  ## the set and the bytes `materialize_route` takes (IF l.3905).
  let v = schemaResponse(b, selected).valueOr:
    return err(refused(module & ": " & error))
  let bytes = encodeCbor(v)
  let set = acceptSchemaResponse(
    bytes, selected, AcceptOptions(system: module.startsWith("logos_"))
  ).valueOr:
    return err(
      Stop(
        exit: ExitRc,
        code: $ecModule,
        message: "the projected contract of " & module & " does not validate: " & error,
      )
    )
  ok((set, bytes))

proc project(p: var Provider, selected: Digest): Result[void, Stop] =
  let (set, bytes) = ?projectView(p.binding, p.module, selected)
  p.selected = selected
  p.set = set
  p.surface = callSurface(set)
  p.schema = bytes
  ok()

proc provider(c: Ctx, sel: LcnCliProvider): Result[Provider, Stop] =
  let rec = ?c.findRecord(sel.module, sel.instance)
  let binding = ?c.describe(rec.provider.get, sel.module)
  var p = Provider(
    module: sel.module,
    instance: rec.instance.get(""),
    address: rec.provider.get,
    binding: binding,
    record: rec,
  )
  if sel.contract.isSome:
    let want = digestOf(sel.contract.get).valueOr:
      return err(refused("--contract is 32 bytes"))
    if want notin p.binding.contractViews:
      var names: seq[string] = @[]
      for r in p.binding.contractViews:
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
  of seIo, seStalled: # seStalled: only a sink with `waitMs`, the overflow's notice
    Stop(exit: ExitUnreachable, silent: true)
  of seAborted:
    Stop(exit: ExitStreamEnded, silent: true) # a stream's queue overflowed

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
  for x in p.binding.extends:
    rows.add(("extended", x)) # [SPEC RUNTIME l.90-91; re-pin RG-9]
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
  # [SPEC RUNTIME l.1966] The record's contract roots, beside the surface's.
  var record = newJObject()
  if p.record.primary_contract.isSome:
    record["primary"] = %toHex(p.record.primary_contract.get.schema_root)
  for (field, list) in [
    ("implements", p.record.implements), ("extends", p.record.extends)
  ]:
    if list.isSome:
      var a = newJArray()
      for x in list.get:
        a.add(%toHex(x.schema_root))
      record[field] = a
  let result0 = %*{
    "module": p.module,
    "instance": p.instance,
    "provider": providerText(p.address),
    "node": c.target,
    "selected": hexOf(p.selected),
    "contracts": contracts,
    "record": record,
    "methods": methods,
    "events": events,
  }
  if lines.len > 0:
    text.add("\n" & lines.join("\n"))
  c.pres.done(result0, text).isOkOr:
    return err(outputStop(error))
  ok()

# call --------------------------------------------------------------------------------------

func methodNamed(s: CallSurface, name: string): Opt[SurfaceMethod] =
  ## By bare name (the SDK's `findMethod`), else by qualified name.
  let b = surface.findMethod(s, name)
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

func retryable*(r: CallResult): bool =
  ## [G348; plan §3.5 step 8, rule 2] A failure that proves the call was not
  ## sent: `prepare_call` failed with NOT_READY, NOT_AUTHORISED or
  ## TRANSPORT_ERROR (nothing was submitted), or the completion is NOT_READY or
  ## NOT_AUTHORISED (before sending, or the provider's boundary before
  ## dispatch; provider code cannot answer them, IF l.3308-3311). Never a
  ## completion TRANSPORT_ERROR, TIMEOUT or CANCELLED (rule 3).
  if r.ok or r.cancelled:
    return false
  let code = r.failure.code
  if not r.prepared:
    code in {ecNotReady, ecNotAuthorised, ecTransport}
  else:
    code in {ecNotReady, ecNotAuthorised}

func classify*(r: CallResult): Stop =
  ## [G349; plan §3.6, IMPL on R l.1259-1272 and IF l.3308-3311] A failed
  ## call's exit, total over the codes.
  let f = r.failure
  func unknown(f: Failure): Stop =
    Stop(
      exit: ExitUnreachable,
      code: $f.code,
      message:
        "the outcome is unknown: the provider may have run the call" &
        (if f.message.len > 0: " (" & f.message & ")" else: ""),
    )

  if r.cancelled:
    return cancelled()
  if not r.prepared and f.code == ecTransport:
    # Nothing was submitted: unreachable, and nothing ran.
    return Stop(
      exit: ExitUnreachable,
      code: $f.code,
      message:
        "lcn_call could not reach the provider" &
        (if f.message.len > 0: " (" & f.message & ")" else: ""),
    )
  case f.code
  of ecTransport, ecTimeout, ecCancelled:
    # [R l.1271-1272; IF l.2025, l.2112] A CANCELLED the user did not ask for
    # promises no rollback.
    unknown(f)
  of ecMethodNotFound, ecInvalidParams, ecModule:
    # [IF l.3308-3311] What provider code may answer; "declared" stays true
    # when the Runtime's boundary answered instead.
    Stop(
      exit: ExitProvider,
      code: $f.code,
      message: f.message,
      detail: f.detail,
      declared: true,
    )
  else:
    # NOT_READY and NOT_AUTHORISED after the retry, VERSION_MISMATCH (IF
    # l.3920) and every code not named.
    Stop(exit: ExitRc, code: $f.code, message: f.message, detail: f.detail)

proc callWithRetry(
    c: Ctx, spec: RouteSpec, bare: string, params: openArray[byte]
): Result[CallResult, Stop] =
  ## [G348; plan §3.5 step 8] The call through a leased route, made once more
  ## on a new route when `retryable`, within what remains of the deadline.
  let started = getMonoTime()
  var outcome: CallResult
  for attempt in 0 .. 1:
    var deadline = c.deadline
    if deadline.isSome:
      let left = deadline.get - int(inMilliseconds(getMonoTime() - started))
      if attempt > 0 and left <= 0:
        break # rule 4: no time left; the first outcome stands
      deadline = Opt.some(max(left, 1))
    let lease = c.env.routes.acquire(spec, deadline, c.cancelFd).valueOr:
      if attempt > 0:
        break # the first outcome stands
      return err(rcStop(error))
    let r = callRoute(lease.route, lease.lock, bare, params, deadline, c.cancelFd)
    let again = attempt == 0 and r.retryable
    if again:
      c.env.routes.drop(lease) # before `done`, which may release the handle
    c.env.routes.done(lease)
    outcome = r
    if not again:
      break
  ok(outcome)

proc runCall(c: Ctx, cmd: LcnCliCallCommand): Result[void, Stop] =
  ## [G348, G349] One typed call through a leased route.
  let p = ?c.provider(cmd.provider)
  let m = p.surface.methodNamed(cmd.`method`).valueOr:
    return err(
      refused(
        p.module & " has no method " & cmd.`method` & "; its methods: " &
          p.surface.methodNames
      )
    )
  if m.sensitiveRequest or m.sensitiveResponse:
    # [SPEC INTERFACE l.368-369; G349 Q2] No path for marked payloads here.
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
  let outcome = ?c.callWithRetry(spec, m.bare, params)
  if outcome.cancelled:
    return err(cancelled())
  if not outcome.ok:
    return err(classify(outcome))
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

# subscribe and events ------------------------------------------------------------------

const
  OverflowNoticeMs = 1_000 ## [IMPL] the wait for room for the overflow's message
  RcEventPrefix = "logos.runtime_control."
  DefaultEvents* =
    ["module_state_changed", "execution_state_changed", "inventory_changed"]
    ## [G346] the events rule's three, `events`' default set (as compose's
    ## `CliEvents`)

func shortEvent(id, namespace: string): string =
  ## [G349] An event's identifier without its namespace and `_event` suffix.
  result = id
  if result.startsWith(namespace & "."):
    result = result[namespace.len + 1 .. ^1]
  if result.endsWith("_event"):
    result = result[0 ..< result.len - "_event".len]

func eventsNamed(s: CallSurface, name: string): seq[SurfaceEvent] =
  ## [G349] By identifier, or without the namespace, or without the `_event`
  ## suffix too.
  for e in s.events:
    let noNs =
      if e.id.startsWith(e.namespace & "."):
        e.id[e.namespace.len + 1 .. ^1]
      else:
        e.id
    if name == e.id or name == noNs or name == shortEvent(e.id, e.namespace):
      result.add(e)

func eventNames(s: CallSurface): string =
  var names: seq[string] = @[]
  for e in s.events:
    names.add(shortEvent(e.id, e.namespace))
  if names.len == 0:
    "(none)"
  else:
    names.join(", ")

proc limits(count, forMs: Opt[uint32]): Result[(Opt[int], Opt[int]), Stop] =
  if count.isSome and count.get == 0:
    return err(refused("--count is at least 1"))
  if forMs.isSome and forMs.get == 0:
    return err(refused("--for is at least 1 ms"))
  ok(
    (
      count.map(
        proc(x: uint32): int =
          int(x)
      ),
      forMs.map(
        proc(x: uint32): int =
          int(x)
      ),
    )
  )

func codeName(c: CErrorCode): string =
  let e = errorCode(int64(c))
  if e.isSome:
    $e.get
  else:
    $c

func endStop(e: Ending): Stop =
  ## [G349; plan §3.7] Why lcn_call ended the stream (exit 6).
  let code = codeName(e.reason)
  case e.kind
  of ekOverflow:
    Stop(
      exit: ExitStreamEnded, message: "the terminal did not keep up; the stream ended"
    )
  of ekSubscription:
    Stop(
      exit: ExitStreamEnded,
      code: code,
      message:
        if e.reason == CErrorCode(ord(ecNotAuthorised)):
          "the subscription ended: authority to receive the event ended"
        else:
          "the subscription ended",
    )
  of ekRoute, ekNone:
    Stop(
      exit: ExitStreamEnded,
      code: code,
      message:
        if e.reason == CErrorCode(ord(ecNotAuthorised)):
          # [P5; R l.3337-3338] A stream lasts one route session.
          "the route's session ended; run the command again"
        elif e.reason == CErrorCode(ord(ecNotReady)):
          "the route ended: the provider is not ready"
        else:
          "the route ended",
    )

proc interrupted(c: Ctx): Stop =
  ## [G349; plan §3.7] A cancel: the launcher's EOF (130), or lcn_call
  ## stopping, which ends the stream itself (6).
  if c.env.stopping != nil and c.env.stopping[].load:
    Stop(exit: ExitStreamEnded, message: "lcn_call is stopping; the stream ended")
  else:
    cancelled()

proc pump(
    c: Ctx, s: Stream, names: openArray[string], count, forMs: Opt[int]
): Result[void, Stop] =
  ## [G349; plan §3.7] Writes the stream's events, one line each, until
  ## `count` events, `forMs`, the launcher's cancel, or the stream's end;
  ## what was queued before an end is written first. An overflow stops a
  ## write the terminal holds up (`abortFd`).
  var p = c.pres
  p.output.abortFd = s.abortFd
  proc overflowed(p: Presenter): Result[void, Stop] =
    # [IMPL] Said on stderr in either format, since stdout waits for the same
    # reader; given up after a second if stderr is that reader too (`2>&1`).
    let st = endStop(Ending(kind: ekOverflow))
    var q = p
    q.errors.waitMs = OverflowNoticeMs
    q.output = q.errors
    discard q.failed(st.code, st.message)
    var quiet = st
    quiet.silent = true
    err(quiet)

  p.streamStart().isOkOr:
    return err(outputStop(error))
  let started = getMonoTime()
  var written = 0
  while true:
    for ev in s.take():
      let v = decodeCbor(ev.data).valueOr:
        return err(
          Stop(
            exit: ExitStreamEnded,
            code: $ecModule,
            message: "an event's data is not Logos deterministic CBOR",
          )
        )
      let line = %*{"event": names[ev.name], "data": jsonOf(v)}
      p.streamLine(line, names[ev.name] & " " & toDiag(v)).isOkOr:
        if error == seAborted:
          return p.overflowed()
        if error == seCancelled:
          return err(c.interrupted)
        return err(outputStop(error))
      inc written
      if count.isSome and written >= count.get:
        return ok()
    let e = s.ending
    if e.kind == ekOverflow:
      return p.overflowed()
    if e.kind != ekNone:
      # Nothing is queued after an end; one more pass writes what came in
      # between `take` and `ending`.
      for ev in s.take():
        let v = decodeCbor(ev.data).valueOr:
          break
        p.streamLine(
          %*{"event": names[ev.name], "data": jsonOf(v)},
          names[ev.name] & " " & toDiag(v),
        ).isOkOr:
          break
        inc written
        if count.isSome and written >= count.get:
          return ok()
      return err(endStop(e))
    var timeout = -1
    if forMs.isSome:
      let left = forMs.get - int(inMilliseconds(getMonoTime() - started))
      if left <= 0:
        return ok()
      timeout = left
    if not s.wait(c.cancelFd, timeout):
      return err(c.interrupted)

proc subscribeFailure(r: LogosResult): Stop =
  ## A `subscribe` that did not succeed.
  let st = readStatus(r)
  let f =
    if st.isErr:
      failureOf(st.error)
    else:
      failure(ecModule, "subscribe returned LOGOS_OK without a subscription")
  rcStop(f)

proc runSubscribe(c: Ctx, cmd: LcnCliSubscribeCommand): Result[void, Stop] =
  ## [G348, G349; plan §3.7] One provider event as a stream, through a leased
  ## route whose access names that event only; the stream lasts at most the
  ## route's session (P5).
  let (count, forMs) = ?limits(cmd.count, cmd.for_ms)
  let p = ?c.provider(cmd.provider)
  let found = p.surface.eventsNamed(cmd.event)
  if found.len == 0:
    return err(
      refused(
        p.module & " has no event " & cmd.event & "; its events: " & p.surface.eventNames
      )
    )
  if found.len > 1:
    var ids: seq[string] = @[]
    for e in found:
      ids.add(e.id)
    return err(refused(cmd.event & " names more than one event: " & ids.join(", ")))
  let e = found[0]
  let root = ?p.memberRoot(e.doc, e.id)
  let spec = RouteSpec(
    key: routeKey(c.target, p.address, p.selected, "subscribe_events", root),
    contract: p.selected,
    provider: p.address,
    access: LogosNSRuntimeControlRouteAccess(subscribe_events: Opt.some(@[@root])),
    schema: p.schema,
  )
  let lease = c.env.routes.acquire(spec, Opt.none(int), c.cancelFd).valueOr:
    return err(rcStop(error))
  let s = c.env.hub.open(lease.handle, 1).valueOr:
    c.env.routes.done(lease)
    return err(Stop(exit: ExitUnreachable, message: error))
  var r: LogosResult
  withLock lease.lock[]:
    r = lease.route.vtable.subscribe(
      lease.route, cstring(e.id), handler(), s.userData(0), s.idSlot(0)
    )
  if int64(r.code) != 0:
    s.settle(0, false)
    c.env.hub.detach(s)
    freeStream(s) # [IF l.1400] no handler was or will be invoked
    if r.code in [CErrorCode(ord(ecNotReady)), CErrorCode(ord(ecTransport))]:
      c.env.routes.drop(lease) # the next command establishes a new route
    c.env.routes.done(lease)
    return err(subscribeFailure(r))
  if c.env.routes.ended(lease):
    s.markEnded(ekRoute, CErrorCode(ord(ecNotReady)))
  let res = c.pump(s, [e.id], count, forMs)
  var u: LogosResult
  withLock lease.lock[]:
    u = lease.route.vtable.unsubscribe(lease.route, s.id(0))
  c.env.hub.detach(s)
  if int64(u.code) == 0:
    freeStream(s)
  else:
    # [IF l.1436-1438] e.g. the route ended: valid until the handle's release.
    c.env.routes.keepUntilRelease(lease, s, freeStream)
  c.env.routes.done(lease)
  res

proc runEvents(c: Ctx, cmd: LcnCliEventsCommand): Result[void, Stop] =
  ## [G346, G349; plan §3.7] The target's Runtime Control events as one
  ## stream, subscribed on its binding; by default the events rule's three.
  let (count, forMs) = ?limits(cmd.count, cmd.for_ms)
  var wanted: seq[string] = @[]
  for n in cmd.names.get(@DefaultEvents):
    var bare = n
    if bare.startsWith(RcEventPrefix):
      bare = bare[RcEventPrefix.len .. ^1]
    if bare.endsWith("_event"):
      bare = bare[0 ..< bare.len - "_event".len]
    if bare notin rcContractInfo().events:
      var known: seq[string] = @[]
      for k in rcContractInfo().events.keys:
        known.add(k)
      return err(
        refused(
          "no Runtime Control event " & n & "; its events: " & known.sorted.join(", ")
        )
      )
    if bare notin wanted:
      wanted.add(bare)
  if wanted.len == 0 or wanted.len > MaxNames:
    return err(refused("events takes 1 to " & $MaxNames & " names"))
  var ids: seq[string] = @[]
  for b in wanted:
    ids.add(RcEventPrefix & b & "_event")
  let s = c.env.hub.open(c.rc, ids.len).valueOr:
    return err(Stop(exit: ExitUnreachable, message: error))
  var made = 0
  var res = Result[void, Stop].ok()
  for i, id in ids:
    let r =
      c.rc.vtable.subscribe(c.rc, cstring(id), handler(), s.userData(i), s.idSlot(i))
    if int64(r.code) != 0:
      s.settle(i, false)
      res = Result[void, Stop].err(subscribeFailure(r))
      break
    inc made
  if res.isOk:
    res = c.pump(s, ids, count, forMs)
  var quiet = true
  for i in 0 ..< made:
    let u = c.rc.vtable.unsubscribe(c.rc, s.id(i))
    if int64(u.code) != 0:
      quiet = false
  c.env.hub.detach(s)
  if quiet:
    freeStream(s)
  # [IMPL; IF l.1436-1438] Otherwise a handler may still run until the
  # binding's release, after `_MODULE_destroy`: the stream is never freed.
  res

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
    of LcnCliCommandKind.lcn_Cli_subscribe_command:
      r = runSubscribe(c, job.msg.command.arm_lcn_Cli_subscribe_command)
    of LcnCliCommandKind.lcn_Cli_events_command:
      r = runEvents(c, job.msg.command.arm_lcn_Cli_events_command)
    of LcnCliCommandKind.lcn_Cli_rc_command:
      r = R.err(refused("the rc op comes with remote Runtimes (Tier 5 step 5-7a)"))
  if r.isOk:
    return Done(exit: ExitOk, what: what0)
  let s = r.error
  if not s.silent:
    discard c.pres.failed(s.code, s.message, s.detail, s.declared)
  Done(exit: s.exit, what: what0, code: s.code)

{.pop.}
