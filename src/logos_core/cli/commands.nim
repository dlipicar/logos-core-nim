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
## - **Call.** The method by its bare or its qualified name. The arguments are
##   typed (`args.nim`), the value validated, and the call made through a
##   leased route (`routes.nim`) with the command's deadline.
## - **Marked payloads (G349 N-2d; IF §1.4.1).** A method that marks its request
##   or response is called on the local Runtime only (IF l.373), by a build
##   that erases (orc, arc; G277), and a marked request only from files
##   (`NAME=@FILE`, `NAME=@-`): each refusal comes before any file is read
##   (IF l.368-369). `runCall` wipes every copy at its last use.
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
import logos_sdk/base/[hex, testhooks, wipe]
import logos_sdk/hash/hashinput
import logos_sdk/iface/[accept, provider, surface]
import logos_sdk/kit/rc_types
import logos_sdk/abi/[checks, types]
import logos_sdk/iface/outcome
from ../authority/scopes import rcContractInfo
import ../daemon/render
import ./[args, cli_types, present, routes, rpc, streams, wire]

testHooksMarker("lcn_call_commands") # [PKG-0555] the watch's hook (`LCN_TEST_CLI_WATCH`)

when defined(posix):
  import std/posix
else:
  from std/os import sleep

export results

const
  MaxFileBytes* = 16 * 1024 * 1024 ## [G349] one `@FILE`, the transport frame
  MaxListPages = 64 ## [IMPL] `list_modules` pages read for one module
  ReadChunk = 65_536

type
  PmGate* = object
    ## [G503; ruling 4] lcn_call's own calls to the Package Manager in flight. lcn_call
    ## is one origin to it, so they stay within its per-caller bounds: one more waits
    ## here for a running one to end, and is never sent to be refused.
    pages*: Atomic[int] ## list pages and handoffs: at most `PmPageCalls`
    watches*: Atomic[int] ## watches: at most `PmWatches`

  Env* = object ## What every command shares; plain values, copied per worker.
    rc*: ptr LogosRuntimeControlBinding
    routes*: RouteTable
    hub*: Hub ## the streams' (`streams.nim`)
    stopping*: ptr Atomic[bool] ## the server's: lcn_call is stopping; nil: never
    production*: bool
    pm*: ptr PmGate
      ## [G503] lcn_call's calls to the Package Manager in flight; nil: none counted

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
    started: MonoTime ## the command's start, for what remains of `deadline`

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
  ## [G349 N-2d] A marked method is never called through another binding:
  ## `runCall` refuses it unless the target is `local`, so 5-7a's node
  ## bindings, and `hops.nextHop`, never see a marked payload.
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

proc grow(data: var seq[byte], need: int) =
  ## [N-2d] Room for `need` bytes: new storage, the old zeroed, so no
  ## reallocation leaves a copy of a file's bytes behind.
  if data.capacity >= need:
    return
  var bigger = newSeqOfCap[byte](max(need, 2 * data.capacity))
  bigger.add(data)
  wipe(data)
  data = move bigger

proc readAll(
    fd, cancelFd: cint, what: string, limit: int, data: var seq[byte]
): Result[void, Stop] =
  ## A passed descriptor's bytes to its end into `data`, at most `limit`: a
  ## longer file is refused after `limit` bytes, the rest never read. [N-2d]
  ## The bytes are read into `data`'s own storage, grown by `grow`; on every
  ## error it is wiped.
  when defined(posix):
    data = newSeqOfCap[byte](min(limit, ReadChunk))
    template fail(s: Stop) =
      wipe(data)
      return err(s)

    while true:
      var p: array[2, TPollfd]
      p[0] = TPollfd(fd: fd, events: POLLIN)
      p[1] = TPollfd(fd: cancelFd, events: POLLIN)
      let n = poll(addr p[0], Tnfds(if cancelFd >= 0: 2 else: 1), -1)
      if n < 0:
        if errno == EINTR:
          continue
        fail(refused(what & ": poll: " & $strerror(errno)))
      if cancelFd >= 0 and (p[1].revents and (POLLIN or POLLHUP or POLLERR)) != 0:
        fail(cancelled())
      let want = min(ReadChunk, limit - data.len)
      if want <= 0:
        # `limit` bytes are in; one more says the file is longer.
        var one: byte
        let r = read(fd, addr one, 1)
        if r < 0 and (errno == EINTR or errno == EAGAIN or errno == EWOULDBLOCK):
          continue
        secureZero(addr one, 1)
        if r == 0:
          break
        if r < 0:
          fail(refused(what & ": " & $strerror(errno)))
        if limit < MaxFileBytes:
          fail(refused(what & " is longer than its field's " & $(limit - 1) & " bytes"))
        fail(refused(what & " is larger than 16 MiB"))
      let at = data.len
      data.grow(at + want)
      data.setLen(at + want)
      let r = read(fd, addr data[at], want)
      if r < 0:
        data.setLen(at)
        if errno == EINTR or errno == EAGAIN or errno == EWOULDBLOCK:
          continue
        fail(refused(what & ": " & $strerror(errno)))
      data.setLen(at + r)
      if r == 0:
        break
    ok()
  else:
    err(refused("@FILE is not supported on this platform"))

proc argInputs(
    c: Ctx, sh: RequestShape, args: openArray[LcnCliArg], marked: bool
): Result[seq[ArgInput], Stop] =
  ## The arguments with each file's bytes read. [N-2d] For a `marked` request
  ## a file is read up to its field's bound (`fileLimit`); on any error the
  ## files read so far are wiped.
  var out0: seq[ArgInput] = @[]
  template fail(s: Stop) =
    wipeInputs(out0)
    return err(s)

  for a in args:
    case a.kind
    of LcnCliArgKind.lcn_Cli_text_arg:
      out0.add(
        ArgInput(
          name: a.arm_lcn_Cli_text_arg.name,
          isFile: false,
          text: a.arm_lcn_Cli_text_arg.value,
        )
      )
    of LcnCliArgKind.lcn_Cli_file_arg:
      let f = a.arm_lcn_Cli_file_arg
      let i = int(f.fd)
      if i < 2 or i >= c.fds.len:
        fail(refused(f.name & ": no such descriptor"))
      let limit = (if marked: sh.fileLimit(f.name, MaxFileBytes) else: MaxFileBytes)
      var data: seq[byte]
      let r = readAll(c.fds[i], c.cancelFd, f.name & "=@FILE", limit, data)
      if r.isErr:
        fail(r.error)
      out0.add(ArgInput(name: f.name, isFile: true, data: move data))
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

func markedInputRefusal(bare: string): Stop =
  refused(
    bare & "'s request is marked: give each field as NAME=@FILE or NAME=@- " &
      "(a value on the command line is not erased; INTERFACE §1.4.1)"
  )

proc runCall(c: Ctx, cmd: LcnCliCallCommand): Result[void, Stop] =
  ## [G348, G349] One typed call through a leased route.
  ##
  ## [G349 N-2d; SPEC INTERFACE §1.4.1] A marked method is called only on the
  ## local Runtime, in a build that erases (orc, arc), with every field of a
  ## marked request from a file: each refusal comes before any file is read.
  ## Every copy is wiped at its last use (IF l.361, l.364): the inputs, the
  ## typed value and its encoding once encoded, the params once no retry can
  ## need them (`prepare_call` keeps its own copy, IF l.1994), the response
  ## once decoded, the value once written. lcn_call wipes them for every
  ## call (IF l.385 allows it); only a marked response's output and a marked
  ## request's typing differ.
  let p = ?c.provider(cmd.provider)
  let m = p.surface.methodNamed(cmd.`method`).valueOr:
    return err(
      refused(
        p.module & " has no method " & cmd.`method` & "; its methods: " &
          p.surface.methodNames
      )
    )
  let marked = m.sensitiveRequest or m.sensitiveResponse
  if marked:
    when not ChannelsMove:
      # [G277] A refc Module Host refuses the marked route only at
      # materialization, after the inputs were read.
      return err(
        refused(
          m.bare & " carries marked payloads, which this build of lcn_call " &
            "does not erase (" & MarkedUnsupportedByHost & ")"
        )
      )
    if c.target != LocalNode:
      # [SPEC INTERFACE l.373; G347] `targetBinding` admits `local` only today;
      # a remote node (5-7a) must not carry a marked payload either.
      return err(
        refused(
          m.bare &
            " carries marked payloads, which have no remote path (INTERFACE l.373)"
        )
      )
  let sh = requestShape(p.set, m).valueOr:
    return err(refused(error))
  if m.sensitiveRequest:
    if cmd.json.isSome:
      return err(markedInputRefusal(m.bare))
    # A mistyped name can hold anything a user typed: these copies are wiped
    # on every return (W-13c).
    var names: seq[string] = @[]
    defer:
      for n in names.mitems:
        wipe(n)
    if cmd.args.isSome:
      for a in cmd.args.get:
        case a.kind
        of LcnCliArgKind.lcn_Cli_text_arg:
          return err(markedInputRefusal(m.bare))
        of LcnCliArgKind.lcn_Cli_file_arg:
          names.add(a.arm_lcn_Cli_file_arg.name)
    checkMarkedNames(sh, names).isOkOr:
      return
        err(refused(m.bare & ": " & error & "; fields: " & sh.fieldList(marked = true)))
  let root = ?p.memberRoot(m.doc, m.name)
  let spec = RouteSpec(
    key: routeKey(c.target, p.address, p.selected, "methods", root),
    contract: p.selected,
    provider: p.address,
    access: LogosNSRuntimeControlRouteAccess(methods: Opt.some(@[@root])),
    schema: p.schema,
  )
  var params: seq[byte]
  # The marked scope has the validator wipe its own temporaries too.
  markedScope(m.sensitiveRequest):
    var value: CborValue
    if cmd.json.isSome:
      value = fromJson(sh, cmd.json.get).valueOr:
        return err(refused(m.bare & ": " & error & "; fields: " & sh.fieldList))
    else:
      var inputs: seq[ArgInput] = @[]
      if cmd.args.isSome:
        inputs = ?c.argInputs(sh, cmd.args.get, m.sensitiveRequest)
      let typed = fromArgs(sh, inputs, m.sensitiveRequest)
      wipeInputs(inputs)
      value = typed.valueOr:
        return err(
          refused(
            m.bare & ": " & error & "; fields: " & sh.fieldList(m.sensitiveRequest)
          )
        )
    checkRequest(sh, value, m.sensitiveRequest).isOkOr:
      wipe(value)
      return err(refused(error))
    params = encodeCbor(value)
    wipe(value)
  var outcome = c.callWithRetry(spec, m.bare, params)
  wipe(params)
  if outcome.isErr:
    return err(outcome.error)
  if outcome.get.cancelled:
    if outcome.get.ok:
      wipe(outcome.value.response)
    return err(cancelled())
  if not outcome.get.ok:
    return err(classify(outcome.get))
  var v: CborValue
  var decoded = false
  markedScope(m.sensitiveResponse):
    let d = decodeCbor(outcome.value.response)
    wipe(outcome.value.response)
    if d.isOk:
      v = d.get
      decoded = true
  if not decoded:
    return err(
      Stop(
        exit: ExitProvider,
        code: $ecModule,
        message: "the response is not Logos deterministic CBOR",
      )
    )
  let written =
    if m.sensitiveResponse:
      c.pres.doneMarked(v)
    else:
      c.pres.doneValue(v)
  wipe(v)
  written.isOkOr:
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

# package and catalog (G503) ------------------------------------------------------------

const
  PmModule* = "logos_package_manager" ## [G491] the composed instance's module
  PmPageCalls* = 2
    ## [G503; G499, G500] lcn_call's list pages and handoffs in flight: the Package
    ## Manager's page-job bound for one caller
  PmWatches* = 4
    ## [G503; G501] lcn_call's watches in flight: its watch bound for one caller
  ListStarts* = 3
    ## [G503; IMPL] how often one listing starts over when the Package Manager no
    ## longer holds its cursor (a commit, or a catalog refresh, between two pages)
  GateTickMs = 20 ## [IMPL] a wait at the gate looks again this often
  WatchRefreshMs* = 30_000
    ## [G503; PKG-0554, PKG-0555] a watch lists the installed packages again this
    ## often: a submitted watch proves no observation boundary
  WatchResyncMs = 1_000 ## [IMPL] the pause before a lost watch is made again
  WatchRemakeMs* = WatchRefreshMs
    ## [G503; IMPL, Fable §17.1 point 3] how long a lost watch is made again before the
    ## command ends with the last failure: the refresh period, from the loss
  InstalledEvent = "logos.package_manager.installed_packages_changed_event"
  ProgressEvent = "logos.package_manager.operation_progress_event"
  PmRefusal* =
    "the Package Manager refused the query: it is at its query bound (8 page calls " &
    "or 16 watches in all), lcn_call is not one of its readers, or it failed; the " &
    "Package Manager's log says which"
    ## [G503; plan §5.7, Fable §11.2 point 1] what lcn_call says for a MODULE_ERROR
    ## with no detail from a reader's method: it cannot tell the three apart

proc waitCancel(cancelFd: cint, ms: int): bool =
  ## [IMPL] Waits `ms`, or less when the launcher cancels: true then. With no
  ## descriptor to wait on (not POSIX; Fable §17.3 point 5) a sleep of `ms`, never a
  ## spin; lcn_call is POSIX only today.
  when defined(posix):
    var p = TPollfd(fd: cancelFd, events: POLLIN)
    let r = poll(addr p, 1, cint(ms))
    r > 0 and cancelFd >= 0 and (p.revents and (POLLIN or POLLHUP or POLLERR)) != 0
  else:
    sleep(ms)
    false

proc tryEnter*(slot: var Atomic[int], bound: int): bool =
  ## [G503] One of `bound` places if one is free now.
  var n = slot.load
  while n < bound:
    if slot.compareExchange(n, n + 1):
      return true
  false

proc enter*(
    slot: var Atomic[int],
    bound: int,
    cancelFd: cint,
    deadline: Opt[MonoTime],
    past = "--timeout",
): Result[void, Stop] =
  ## [G503; ruling 4] One of `bound` places, waited for: until one is free, the
  ## launcher cancels, or `deadline` passes (exit 2: nothing was sent); `past` names
  ## the option that set it.
  while true:
    if slot.tryEnter(bound):
      return ok()
    var wait = GateTickMs
    if deadline.isSome:
      let left = inMilliseconds(deadline.get - getMonoTime())
      if left <= 0:
        return err(
          Stop(
            exit: ExitUnreachable,
            message:
              "lcn_call's calls to the Package Manager stayed at its bound (" & $bound &
              ") past " & past & "; nothing was sent",
          )
        )
      wait = min(wait, int(left))
    if waitCancel(cancelFd, wait):
      return err(cancelled())

proc leave*(slot: var Atomic[int]) =
  discard slot.fetchSub(1)

func opaque*(s: Stop): bool =
  ## A MODULE_ERROR with no message and no detail: what the Package Manager answers
  ## a caller at a query bound, one that is not a reader, and a fault (G498, G501).
  s.code == $ecModule and s.message.len == 0 and s.detail.isNone

func readerStop*(s: Stop): Stop =
  ## [G503] A reader's method's failure, with `PmRefusal` for an opaque one.
  if not s.opaque:
    return s
  Stop(exit: s.exit, code: s.code, message: PmRefusal)

func textOf(v: CborValue, key: string): string =
  let x = v.lookup(key)
  if x.isNone:
    return ""
  x.get.getText.get("")

func u64Of(v: CborValue, key: string): Opt[uint64] =
  let x = v.lookup(key)
  if x.isNone:
    return Opt.none(uint64)
  x.get.getUint64

func packageStop*(answer: CborValue): Opt[Stop] =
  ## [SPEC PM §14] The answer's `error` arm, as exit 5 with the Package Manager's
  ## code and its declared message; none for any other arm.
  let e = answer.lookup("error")
  if e.isNone:
    return Opt.none(Stop)
  Opt.some(
    Stop(
      exit: ExitProvider,
      code: e.get.textOf("code"),
      message: e.get.textOf("message"),
      declared: true,
    )
  )

type PageFetch* =
  proc(cursor: Opt[string]): Result[CborValue, Stop] {.gcsafe, raises: [].}
  ## One page's answer: `{packages, ? next_cursor}` or `{error}`.

proc listAll*(fetch: PageFetch, what: string): Result[seq[CborValue], Stop] =
  ## [G503; G499] Every page, in order. An `invalid-request` for a cursor means the
  ## Package Manager no longer holds the listing (a commit, or a catalog refresh,
  ## between two pages): the listing starts over, at most `ListStarts` times, then
  ## fails saying `what` kept changing. Any other error arm ends it.
  for start in 0 .. ListStarts:
    var items: seq[CborValue] = @[]
    var cursor = Opt.none(string)
    var again = false
    while true:
      let answer = ?fetch(cursor)
      let failed = packageStop(answer)
      if failed.isSome:
        if failed.get.code == "invalid-request" and cursor.isSome:
          again = true
          break
        return err(failed.get)
      let page = answer.lookup("packages")
      if page.isNone or page.get.kind != ckArray:
        return err(
          Stop(
            exit: ExitProvider,
            code: $ecModule,
            message: "a page of " & what & " has no packages",
          )
        )
      items.add(page.get.items)
      let next = answer.lookup("next_cursor")
      if next.isNone:
        return ok(items)
      cursor = next.get.getText
      if cursor.isNone:
        return err(
          Stop(
            exit: ExitProvider,
            code: $ecModule,
            message: "a page of " & what & " has a cursor that is not text",
          )
        )
    if not again:
      break
  err(
    Stop(
      exit: ExitProvider,
      code: "invalid-request",
      message:
        what & " kept changing while lcn_call read them: it started over " & $ListStarts &
        " times; run the command again",
    )
  )

proc within(c: Ctx): Ctx =
  ## `c` with what remains of its deadline, at least 1 ms.
  result = c
  if c.deadline.isSome:
    let left = c.deadline.get - int(inMilliseconds(getMonoTime() - c.started))
    result.deadline = Opt.some(max(left, 1))

func gateDeadline(c: Ctx): Opt[MonoTime] =
  if c.deadline.isNone:
    return Opt.none(MonoTime)
  Opt.some(c.started + initDuration(milliseconds = c.deadline.get))

proc pmMethod(
    c: Ctx, p: Provider, bare: string
): Result[(SurfaceMethod, RequestShape, RouteSpec, Digest), Stop] =
  ## [G503] The Package Manager's method `bare`, its request rule, its route and its
  ## declaration root.
  let m = p.surface.methodNamed(bare).valueOr:
    return err(
      Stop(
        exit: ExitRc,
        code: $ecModule,
        message: "the Package Manager's contract has no method " & bare,
      )
    )
  let sh = requestShape(p.set, m).valueOr:
    return err(refused(error))
  let root = ?p.memberRoot(m.doc, m.name)
  let spec = RouteSpec(
    key: routeKey(c.target, p.address, p.selected, "methods", root),
    contract: p.selected,
    provider: p.address,
    access: LogosNSRuntimeControlRouteAccess(methods: Opt.some(@[@root])),
    schema: p.schema,
  )
  ok((m, sh, spec, root))

proc pmChecked(
    c: Ctx, p: Provider, bare: string, request: CborValue
): Result[(SurfaceMethod, RouteSpec, Digest, seq[byte]), Stop] =
  ## [G503] `bare`'s request checked against its request rule (exit 1), encoded.
  let (m, sh, spec, root) = ?c.pmMethod(p, bare)
  checkRequest(sh, request).isOkOr:
    return err(refused(error & "; fields: " & sh.fieldList))
  ok((m, spec, root, encodeCbor(request)))

proc pmSend(
    c: Ctx, p: Provider, bare: string, request: CborValue
): Result[CallResult, Stop] =
  ## [G503] One call of the Package Manager's `bare`: the request checked against its
  ## request rule first (exit 1), then sent with `c`'s deadline.
  let (m, spec, _, params) = ?c.pmChecked(p, bare, request)
  c.callWithRetry(spec, m.bare, params)

proc pmAnswer(r: CallResult, reader: bool): Result[CborValue, Stop] =
  ## The call's answer, decoded; a failure as `classify` says, an opaque one of a
  ## reader's method with `PmRefusal`; the `error` arm as `packageStop`.
  if r.cancelled:
    return err(cancelled())
  if not r.ok:
    let s = classify(r)
    return err(
      if reader:
        readerStop(s)
      else:
        s
    )
  let v = decodeCbor(r.response).valueOr:
    return err(
      Stop(
        exit: ExitProvider,
        code: $ecModule,
        message: "the Package Manager's answer is not Logos deterministic CBOR",
      )
    )
  let failed = packageStop(v)
  if failed.isSome:
    return err(failed.get)
  ok(v)

proc pmProvider(c: Ctx): Result[Provider, Stop] =
  c.provider(LcnCliProvider(module: PmModule))

proc pageCall(
    c: Ctx, p: Provider, bare: string, request: CborValue
): Result[CborValue, Stop] =
  ## [G503] A page call (a list page, a handoff), within lcn_call's own page bound;
  ## its error arm returned as the answer, for `listAll`.
  if c.env.pm != nil:
    ?enter(c.env.pm[].pages, PmPageCalls, c.cancelFd, c.gateDeadline)
  defer:
    if c.env.pm != nil:
      leave(c.env.pm[].pages)
  let r = ?c.within.pmSend(p, bare, request)
  if r.cancelled:
    return err(cancelled())
  if not r.ok:
    return err(readerStop(classify(r)))
  let v = decodeCbor(r.response).valueOr:
    return err(
      Stop(
        exit: ExitProvider,
        code: $ecModule,
        message: "the Package Manager's answer is not Logos deterministic CBOR",
      )
    )
  ok(v)

proc listing(
    c: Ctx, p: Provider, bare: string, package: Opt[string], what: string
): Result[seq[CborValue], Stop] =
  ## [G503] Every page of `bare` (`list_installed_packages`, `list_packages`).
  proc fetch(cursor: Opt[string]): Result[CborValue, Stop] =
    var entries: seq[CborEntry] = @[]
    if cursor.isSome:
      entries.add((cbor("cursor"), cbor(cursor.get)))
    if package.isSome:
      entries.add((cbor("package"), cbor(package.get)))
    c.pageCall(p, bare, CborValue(kind: ckMap, entries: entries))

  listAll(fetch, what)

func identityText(v: CborValue): string =
  ## `name version` of a record's `identity`.
  let id = v.lookup("identity")
  if id.isNone:
    return "?"
  id.get.textOf("package") & " " & id.get.textOf("version")

func identityMap(package, version: string): CborValue =
  cborMap((cbor("package"), cbor(package)), (cbor("version"), cbor(version)))

proc need(x: Opt[string], what: string): Result[string, Stop] =
  if x.isNone:
    return err(refused(what))
  ok(x.get)

# Subscriptions on the Package Manager's routes --------------------------------------------

type Sub = object
  ## One event subscription on a leased route, as `runSubscribe` makes it.
  lease: Lease
  s: Stream

proc openSub(c: Ctx, p: Provider, id: string, meth: Digest): Result[Sub, Stop] =
  ## [G503; SPEC TRANSPORT §5.2, §6] A subscription to the Package Manager's event `id`
  ## for the call of the method whose root is `meth`: the Package Manager publishes it
  ## in that call's own scope (PM §15.1, §15.2), which reaches the subscriptions of the
  ## session that carried the request only. So both share one route, whose access
  ## names the method and the event, and the call goes on the subscription's lease
  ## (`subCall`).
  let found = p.surface.eventsNamed(id)
  if found.len != 1:
    return err(
      Stop(
        exit: ExitRc,
        code: $ecModule,
        message: "the Package Manager's contract has no event " & id,
      )
    )
  let e = found[0]
  let root = ?p.memberRoot(e.doc, e.id)
  let both = digestOfInput(encodeCbor(cborArray(cbor(@meth), cbor(@root))))
  let spec = RouteSpec(
    key: routeKey(c.target, p.address, p.selected, "methods+subscribe_events", both),
    contract: p.selected,
    provider: p.address,
    access: LogosNSRuntimeControlRouteAccess(
      methods: Opt.some(@[@meth]), subscribe_events: Opt.some(@[@root])
    ),
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
      c.env.routes.drop(lease)
    c.env.routes.done(lease)
    return err(subscribeFailure(r))
  if c.env.routes.ended(lease):
    s.markEnded(ekRoute, CErrorCode(ord(ecNotReady)))
  ok(Sub(lease: lease, s: s))

proc closeSub(c: Ctx, sub: Sub) =
  var u: LogosResult
  withLock sub.lease.lock[]:
    u = sub.lease.route.vtable.unsubscribe(sub.lease.route, sub.s.id(0))
  c.env.hub.detach(sub.s)
  if int64(u.code) == 0:
    freeStream(sub.s)
  else:
    # [IF l.1436-1438] e.g. the route ended: valid until the handle's release.
    c.env.routes.keepUntilRelease(sub.lease, sub.s, freeStream)
  c.env.routes.done(sub.lease)

proc subCall(
    c: Ctx, sub: Sub, bare: string, params: openArray[byte], side: Side
): CallResult =
  ## [G503] The call on the subscription's own route, with `c`'s deadline. A call the
  ## route did not take (`retryable`) drops it, so the next subscription gets a new one.
  result = callRoute(
    sub.lease.route, sub.lease.lock, bare, params, c.deadline, c.cancelFd, side
  )
  if result.retryable:
    c.env.routes.drop(sub.lease)

# Operations and their progress (PM §15.2) -------------------------------------------------

proc progressLine(c: Ctx, v: CborValue): Result[void, SinkError] =
  ## [G503] One `operation_progress` publication, on stderr in either format: stdout
  ## carries the command's one result.
  let phase = v.textOf("phase")
  let done = v.u64Of("bytes_completed")
  let total = v.u64Of("bytes_total")
  var j = %*{"phase": phase}
  var t = "progress: " & phase
  if done.isSome:
    j["bytes_completed"] = %done.get
  if total.isSome:
    j["bytes_total"] = %total.get
  if done.isSome and total.isSome:
    t.add(" " & $done.get & " of " & $total.get & " bytes")
  elif total.isSome:
    t.add(" of " & $total.get & " bytes")
  c.pres.progressLine(%*{"progress": j}, t)

proc operate(
    c: Ctx, bare: string, request: CborValue, progress: bool
): Result[CborValue, Stop] =
  ## [G503; PM §15.2] An install, remove or update. With `progress`, lcn_call first
  ## subscribes to `operation_progress`, then sends a fresh key and writes each
  ## publication for it as it comes. [PKG-0573] A cancel, a timeout or a lost route
  ## is reported as the outcome unknown (exit 2), never as a rollback; a progress
  ## stream that ends only stops the progress lines.
  let p = ?c.pmProvider()
  if not progress:
    return pmAnswer(?c.within.pmSend(p, bare, request), reader = false)
  let key = requestKey().valueOr:
    return err(rcStop(error))
  var req = request
  req.entries.add((cbor("progress_key"), cbor(key)))
  let (m, _, root, params) = ?c.pmChecked(p, bare, req)
  var watching = true
  var r: CallResult
  for attempt in 0 .. 1:
    # Once more on a new route when this one took no request, as `callWithRetry`.
    let sub = ?c.openSub(p, ProgressEvent, root)
    proc drain(): bool =
      discard sub.s.wait(-1, 0) # the wake pipe
      for ev in sub.s.take():
        if not watching:
          continue
        let v = decodeCbor(ev.data).valueOr:
          continue
        if v.textOf("progress_key") != key:
          continue # another command's operation on this shared route
        if c.progressLine(v).isErr:
          watching = false # the reader of stderr is gone; the operation goes on
      if sub.s.ending.kind != ekNone:
        watching = false
      true

    r = c.within.subCall(
      sub, m.bare, params, Side(fd: sub.s.wakeFd, everyMs: -1, tick: drain)
    )
    discard drain()
    c.closeSub(sub)
    if not (attempt == 0 and r.retryable):
      break
  pmAnswer(r, reader = false)

# The watch (PM §15.1) ---------------------------------------------------------------------

when defined(lcnTestHooks):
  from std/os import getEnv

  type WatchHook = object
    refreshMs: int ## > 0: in place of `WatchRefreshMs`
    loseFirstHint: bool ## a watch command's first hint ends its watch, unlisted
    deaf: bool ## every other hint is ignored, as if it were lost

  proc watchHook(): WatchHook =
    ## [PKG-0555] A test build's watch, from `LCN_TEST_CLI_WATCH`: a comma list of
    ## `refresh=MS`, `deaf` and `lose-first-hint`, read when a watch command starts.
    for item in getEnv("LCN_TEST_CLI_WATCH").split(','):
      let t = item.strip()
      if t == "deaf":
        result.deaf = true
      elif t == "lose-first-hint":
        result.loseFirstHint = true
      elif t.startsWith("refresh="):
        try:
          result.refreshMs = parseInt(t["refresh=".len ..^ 1])
        except ValueError:
          discard

proc installedView(items: seq[CborValue]): (JsonNode, string) =
  var a = newJArray()
  var names: seq[string] = @[]
  for r in items:
    let id = r.lookup("identity")
    let n = (if id.isSome: id.get.textOf("package") else: "?")
    let v = (if id.isSome: id.get.textOf("version") else: "?")
    a.add(%*{"package": n, "version": v})
    names.add(n & " " & v)
  (
    %*{"installed": a},
    "installed: " & (if names.len == 0: "(none)" else: names.join(", ")),
  )

func remakable(s: Stop): bool =
  ## [G503; Fable §17.1 point 3] A failure a lost watch is made again after: the Package
  ## Manager not ready (stopped, starting, its route ended), a transport failure, a
  ## timeout, or a cancel lcn_call's user did not ask for.
  not s.silent and s.code in [$ecNotReady, $ecTransport, $ecTimeout, $ecCancelled]

proc runWatch(c: Ctx, cmd: LcnCliPackageCommand): Result[void, Stop] =
  ## [G503; PM §15.1] The installed packages as a stream: one line with every
  ## installed identity at the start, and again whenever they changed.
  ## [PKG-0554, PKG-0555] A watch's hint only says to look again, and a submitted
  ## watch proves no observation boundary, so lcn_call lists the packages after
  ## each hint, every `WatchRefreshMs` and after a lost watch, which it makes
  ## again; a line is written when the list differs from the last one written.
  ## [Fable §17.1 point 3] A watch that was made and listed, then lost (it ended, its
  ## route or its hints were lost, or the Package Manager stopped), is made again every
  ## `WatchResyncMs` for up to `WatchRemakeMs` from the loss, with one notice on stderr
  ## for each loss. [Fable §17.1 point 4] A watch waiting at lcn_call's own bound says
  ## so on stderr, and `--for` bounds that wait.
  ## The stream ends as `subscribe`'s does (count, for, the launcher's cancel), or
  ## with the failure of a list or of the watch itself: one no re-making helps, one
  ## before the watch was first made, or one still there `WatchRemakeMs` after a loss.
  let (count, forMs) = ?limits(cmd.count, cmd.for_ms)
  var shown = Opt.none(string)
  var written = 0
  let started = getMonoTime()
  var pres = c.pres
  ?pres.streamStart().mapErr(outputStop)
  if c.env.pm != nil and not c.env.pm[].watches.tryEnter(PmWatches):
    let msg =
      "lcn_call has " & $PmWatches &
      " watches open: this one waits for one of them to end"
    ?pres.notice(%*{"notice": msg}, "notice: " & msg).mapErr(outputStop)
    let deadline =
      if forMs.isSome:
        Opt.some(started + initDuration(milliseconds = forMs.get))
      else:
        Opt.none(MonoTime)
    ?enter(c.env.pm[].watches, PmWatches, c.cancelFd, deadline, past = "--for")
  defer:
    if c.env.pm != nil:
      leave(c.env.pm[].watches)
  var nc = c
  nc.deadline = Opt.none(int)
  var refreshMs = WatchRefreshMs
  when defined(lcnTestHooks):
    let hook = watchHook()
    if hook.refreshMs > 0:
      refreshMs = hook.refreshMs
    var lostOnce = false
  proc expired(): bool =
    forMs.isSome and int(inMilliseconds(getMonoTime() - started)) >= forMs.get

  var made = false ## a watch was made and its list written or compared
  var lostAt = Opt.none(MonoTime) ## when the watch was lost; none while it is made
  proc lose(s: Opt[Stop]): Result[void, Stop] =
    ## The watch is lost: it is made again, unless `s` is a failure no re-making helps
    ## or one before the watch was first made, or the loss is `WatchRemakeMs` old.
    if s.isSome and (not made or not s.get.remakable):
      return err(s.get)
    let now = getMonoTime()
    if lostAt.isNone:
      lostAt = Opt.some(now)
      let why =
        if s.isSome and s.get.message.len > 0:
          " (" & s.get.message & ")"
        else:
          ""
      let msg =
        "the watch on the Package Manager was lost" & why &
        "; it is made again for up to " & $(WatchRemakeMs div 1000) & " s"
      pres.notice(%*{"notice": msg}, "notice: " & msg).isOkOr:
        return err(outputStop(error))
    elif int(inMilliseconds(now - lostAt.get)) >= WatchRemakeMs:
      if s.isSome:
        return err(s.get)
      return err(
        Stop(
          exit: ExitRc,
          code: $ecNotReady,
          message:
            "the watch on the Package Manager was not made again within " &
            $(WatchRemakeMs div 1000) & " s",
        )
      )
    ok()

  while true:
    if lostAt.isSome:
      # A lost watch: a pause, then made again.
      if expired():
        return ok()
      if waitCancel(c.cancelFd, WatchResyncMs):
        return err(nc.interrupted)
      if expired():
        return ok()
    # The provider each time the watch is made: a lost one may come back as a new record.
    let p = c.pmProvider().valueOr:
      ?lose(Opt.some(error))
      continue
    let (wm, _, wroot, wparams) = c.pmChecked(
      p, "watch_installed_packages", CborValue(kind: ckMap)
    ).valueOr:
      ?lose(Opt.some(error))
      continue
    let sub = nc.openSub(p, InstalledEvent, wroot).valueOr:
      ?lose(Opt.some(error))
      continue
    var failure = Opt.none(Stop)
    var finished = false
    var lastList = getMonoTime()
    var first = true
    proc look(): bool =
      ## Lists and writes when the view changed; false ends the watch call.
      var lc = c
      lc.started = getMonoTime()
      lc.deadline = Opt.some(RcDeadlineMs)
        # [IMPL] a list in a stream, as a Runtime Control call
      let items = lc.listing(
        p, "list_installed_packages", Opt.none(string), "the installed packages"
      )
      lastList = getMonoTime()
      if items.isErr:
        failure = Opt.some(items.error)
        return false
      made = true
      lostAt = Opt.none(MonoTime)
      let (j, t) = installedView(items.get)
      if shown.isNone or shown.get != t:
        pres.streamLine(j, t).isOkOr:
          failure = Opt.some(outputStop(error))
          return false
        shown = Opt.some(t)
        inc written
        if count.isSome and written >= count.get:
          finished = true
          return false
      true

    proc tick(): bool =
      discard sub.s.wait(-1, 0)
      var hints = sub.s.take().len
      when defined(lcnTestHooks):
        if hook.loseFirstHint and hints > 0 and not lostOnce:
          lostOnce = true
          return false # as a lost subscription below: the watch is made again
        if hook.deaf:
          hints = 0
      if expired():
        finished = true
        return false
      if first or hints > 0 or inMilliseconds(getMonoTime() - lastList) >= refreshMs:
        first = false
        if not look():
          return false
      if sub.s.ending.kind != ekNone:
        return false # the hints are lost: the watch is made again
      true

    var every = refreshMs
    if forMs.isSome:
      every =
        min(every, max(forMs.get - int(inMilliseconds(getMonoTime() - started)), 1))
    # The watch on the subscription's route: its hints are published in its own scope.
    let call = nc.subCall(
      sub, wm.bare, wparams, Side(fd: sub.s.wakeFd, everyMs: every, tick: tick)
    )
    nc.closeSub(sub)
    if failure.isSome:
      ?lose(failure) # a list's failure: made again when it is one a re-making helps
      continue
    if finished:
      return ok()
    if call.cancelled:
      return err(nc.interrupted)
    if not call.ok and not call.ended:
      # A refusal or a fault ends it; NOT_READY, TRANSPORT_ERROR and the like are a loss.
      ?lose(Opt.some(readerStop(classify(call))))
      continue
    if call.ok:
      let v = decodeCbor(call.response)
      if v.isOk:
        let failed = packageStop(v.get)
        if failed.isSome:
          return err(failed.get)
    # The watch ended (`{}`), its route or its hints were lost: made again.
    ?lose(Opt.none(Stop))

# The actions ------------------------------------------------------------------------------

proc runPackage(c: Ctx, cmd: LcnCliPackageCommand): Result[void, Stop] =
  ## [G503; PM §15] One `package` action on the composed Package Manager.
  template answer(v: JsonNode, text: string) =
    c.pres.done(v, text).isOkOr:
      return err(outputStop(error))
    return ok()

  case cmd.action.kind
  of LcnCliPackageActionKind.List:
    let p = ?c.pmProvider()
    let items =
      ?c.listing(p, "list_installed_packages", cmd.package, "the installed packages")
    var lines: seq[string] = @[]
    var a = newJArray()
    for r in items:
      a.add(jsonOf(r))
      lines.add(identityText(r))
    answer(
      %*{"packages": a},
      (if lines.len == 0: "no packages installed" else: lines.join("\n")),
    )
  of LcnCliPackageActionKind.Inspect:
    let package = ?need(cmd.package, "package inspect names a PACKAGE")
    var entries: seq[CborEntry] = @[(cbor("package"), cbor(package))]
    if cmd.version.isSome:
      entries.add((cbor("version"), cbor(cmd.version.get)))
    let p = ?c.pmProvider()
    let v = ?pmAnswer(
      ?c.within.pmSend(p, "inspect_package", CborValue(kind: ckMap, entries: entries)),
      reader = false,
    )
    answer(jsonOf(v), toDiag(v))
  of LcnCliPackageActionKind.Install:
    let package = ?need(cmd.package, "package install names a PACKAGE")
    var entries: seq[CborEntry] = @[(cbor("package"), cbor(package))]
    if cmd.version.isSome:
      entries.add((cbor("version"), cbor(cmd.version.get)))
    let v = ?c.operate(
      "install_package",
      CborValue(kind: ckMap, entries: entries),
      cmd.progress.get(false),
    )
    let rec = v.lookup("installed")
    answer(
      jsonOf(v), "installed " & (if rec.isSome: identityText(rec.get)
      else: package)
    )
  of LcnCliPackageActionKind.Remove:
    let package = ?need(cmd.package, "package remove names a PACKAGE and its VERSION")
    let version = ?need(cmd.version, "package remove names a PACKAGE and its VERSION")
    let v = ?c.operate(
      "remove_package",
      cborMap((cbor("identity"), identityMap(package, version))),
      cmd.progress.get(false),
    )
    # [IMPL; G503] PM §15 l.1693-1699: `{}` whether or not it was installed, so the text
    # says what is true after either.
    answer(jsonOf(v), package & " " & version & " is not installed")
  of LcnCliPackageActionKind.Update:
    let package = ?need(cmd.package, "package update names a PACKAGE and its VERSION")
    let version = ?need(cmd.version, "package update names a PACKAGE and its VERSION")
    var entries: seq[CborEntry] = @[(cbor("current"), identityMap(package, version))]
    if cmd.to.isSome:
      entries.add((cbor("target_version"), cbor(cmd.to.get)))
    let v = ?c.operate(
      "update_package",
      CborValue(kind: ckMap, entries: entries),
      cmd.progress.get(false),
    )
    let rec = v.lookup("installed")
    answer(
      jsonOf(v), "installed " & (if rec.isSome: identityText(rec.get)
      else: package)
    )
  of LcnCliPackageActionKind.Handoff:
    let package =
      ?need(cmd.package, "package handoff names a PACKAGE, its VERSION and a MODULE")
    let version =
      ?need(cmd.version, "package handoff names a PACKAGE, its VERSION and a MODULE")
    let module =
      ?need(cmd.module, "package handoff names a PACKAGE, its VERSION and a MODULE")
    let p = ?c.pmProvider()
    let v = ?c.pageCall(
      p,
      "get_runtime_handoff",
      cborMap(
        (cbor("module"), cbor(module)), (cbor("package"), identityMap(package, version))
      ),
    )
    let failed = packageStop(v)
    if failed.isSome:
      return err(failed.get)
    answer(jsonOf(v), toDiag(v))
  of LcnCliPackageActionKind.Watch:
    c.runWatch(cmd)

proc runCatalog(c: Ctx, cmd: LcnCliCatalogCommand): Result[void, Stop] =
  ## [G503; PM §15] The catalog, every page.
  let p = ?c.pmProvider()
  let items = ?c.listing(p, "list_packages", cmd.package, "the catalog's packages")
  var lines: seq[string] = @[]
  var a = newJArray()
  for r in items:
    a.add(jsonOf(r))
    let src = r.lookup("source")
    let kind = (if src.isSome: src.get.textOf("kind") else: "")
    lines.add(identityText(r) & (if kind.len > 0: " (" & kind & ")" else: ""))
  c.pres.done(
    %*{"packages": a},
    (if lines.len == 0: "the catalog lists no packages"
    else: lines.join("\n")),
  ).isOkOr:
    return err(outputStop(error))
  ok()

# A request ---------------------------------------------------------------------------------

func what(cmd: LcnCliCommand): string =
  case cmd.kind
  of LcnCliCommandKind.lcn_Cli_call_command:
    # Fields, not a `let` copy of the command, which holds argument values.
    "call " & cmd.arm_lcn_Cli_call_command.provider.module & "." &
      cmd.arm_lcn_Cli_call_command.`method`
  of LcnCliCommandKind.lcn_Cli_describe_command:
    "describe " & cmd.arm_lcn_Cli_describe_command.provider.module
  of LcnCliCommandKind.lcn_Cli_subscribe_command:
    let x = cmd.arm_lcn_Cli_subscribe_command
    "subscribe " & x.provider.module & "." & x.event
  of LcnCliCommandKind.lcn_Cli_events_command:
    "events"
  of LcnCliCommandKind.lcn_Cli_rc_command:
    "rc " & cmd.arm_lcn_Cli_rc_command.`method`
  of LcnCliCommandKind.lcn_Cli_package_command:
    # [G503] The action and the package's name: no version, module or key.
    let x = cmd.arm_lcn_Cli_package_command
    "package " & toLowerAscii($x.action.kind) &
      (if x.package.isSome: " " & x.package.get else: "")
  of LcnCliCommandKind.lcn_Cli_catalog_command:
    "catalog list"

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
    started: getMonoTime(),
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
    of LcnCliCommandKind.lcn_Cli_package_command:
      r = runPackage(c, job.msg.command.arm_lcn_Cli_package_command)
    of LcnCliCommandKind.lcn_Cli_catalog_command:
      r = runCatalog(c, job.msg.command.arm_lcn_Cli_catalog_command)
    of LcnCliCommandKind.lcn_Cli_rc_command:
      r = R.err(refused("the rc op comes with remote Runtimes (Tier 5 step 5-7a)"))
  if r.isOk:
    return Done(exit: ExitOk, what: what0)
  let s = r.error
  if not s.silent:
    discard c.pres.failed(s.code, s.message, s.detail, s.declared)
  Done(exit: s.exit, what: what0, code: s.code)

{.pop.}
