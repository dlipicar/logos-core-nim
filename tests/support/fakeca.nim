## A scripted Capability Authority for the Runtime-side authority suites (step
## 8b; DECISIONS I85). A `direct_static` module whose `_MODULE_name` and
## `_MODULE_call_surface` are the real Capability Authority's, so its primary
## contract is the pinned one and the Runtime binds it, with its own `init`,
## `destroy`, `dispatch` and `free`:
##
## - `evaluate` answers from a script of rules matched by consumer and by what
##   the request asks (`what`): allow (with a validity, grants, a commitment
##   and narrowing), deny, an `error` arm, a non-OK status, a hang until
##   released, or one of the malformed decisions an evaluation must refuse.
## - Every request is recorded with its caller kind, thread and order.
## - The test publishes `grant_changed`, `policy_changed` or anything else
##   through the instance's publish callback.
##
## Every other method is MODULE_ERROR. Module code runs on the engine's
## workers, so the script, the records and the controls live on the shared
## heap behind a lock, as plain bytes (refc moves no GC'd value between
## threads).

{.push raises: [].}

import std/[atomics, locks, os, strutils, tables]
import results
import ../../src/logos_core/cbor
import ../../src/logos_core/abi/types
import ../../src/logos_core/base/clock
import ../../src/logos_core/iface/outcome
import ../../src/logos_core/authority/[provider, scopes]
import ../../src/logos_core/runtime/engine
from ../../src/logos_core/runtime/authscopes import AuthorityModule
from ../../src/logos_core/authority/logos_capability_authority_kit import nil

static:
  # [SPEC CA l.143] The Runtime's name for the authority module is the one
  # generated from the mirrored contract.
  doAssert AuthorityModule == logos_capability_authority_kit.moduleName

export clock

type
  Verdict* = enum
    vAllow
    vDeny
    vError ## the `error` arm
    vHang ## waits until `release`, then allows
    vStatus ## a non-OK status, no response
    vWrongConsumer ## an allow naming another consumer
    vOtherScopes ## an allow answering other requested scopes
    vBroadened ## an allowed scope wider than the request
    vUncovered ## an allow whose allowed scopes cover nothing requested
    vUnordered ## allowed scopes that are not a set
    vAllowWithDenial
    vDenyWithAllowed
    vBadValidity ## `valid_until` not after `issued_at`
    vExpired ## already past `valid_until`
    vPlacements ## an execution allow with placements
    vPermission ## an allowed `permission` scope
    vBadCbor
    vNoValidity ## an allow without `valid_until`

  Rule* = object
    consumer*: string ## the consumer module instance; empty: any
    what*: string
      ## what the request asks; empty: anything. `call`, `establish-route`,
      ## `renew-route`, `discover`, `publish-event`, `subscribe-event`,
      ## `rc:<method>`, `execute`, `stop`
    verdict*: Verdict
    validMs*: int64 ## allow: `valid_until` this far after `issued_at`
    grants*: seq[string]
    revision*: uint64 ## `policy_revision`
    narrowMethods*: Opt[seq[seq[byte]]]
      ## allow: the allowed provider-access scope's `access.methods`
    narrowProviders*: Opt[seq[string]] ## allow: the allowed scope's providers
    retainRequest*, retainResponse*: bool ## allow: `commitment`
    code*: int ## deny: the denial code; error: the error code (enum ordinal)

  Received* = object
    what*: string
    consumer*: string
    callerKind*: uint32
    thread*: int
    order*: int
    request*: seq[byte]

const
  CaModuleName* = AuthorityModule
  Everything* = 600_000'i64 ## ten minutes

# Shared state ------------------------------------------------------------------------

type SharedText = object
  data: ptr UncheckedArray[char]
  len, cap: int

var
  lock: Lock
  script, records: SharedText
  fakeClock: Clock ## set before an engine starts
  order: Atomic[int]
  decisions: Atomic[int]
  revision: Atomic[uint64]
    ## the policy revision a decision is made under: the latest one this fake
    ## published in a `policy_changed`
  hangGate: Atomic[bool]
  hanging*: Atomic[int] ## evaluations waiting at the gate
  sawCancel*: Atomic[int] ## hung evaluations that saw their invocation cancelled
  inits*: Atomic[int]
  failInit*: Atomic[bool]
  publishFn: Atomic[pointer]
  publishData: Atomic[pointer]

initLock(lock)

proc setText(t: var SharedText, s: string) =
  if s.len > t.cap:
    if t.data != nil:
      deallocShared(t.data)
    t.cap = max(s.len, 256)
    t.data = cast[ptr UncheckedArray[char]](allocShared0(t.cap))
  for i, c in s:
    t.data[i] = c
  t.len = s.len

proc addText(t: var SharedText, s: string) =
  if t.len + s.len > t.cap:
    let cap = max(2 * t.cap, t.len + s.len + 256)
    let d = cast[ptr UncheckedArray[char]](allocShared0(cap))
    for i in 0 ..< t.len:
      d[i] = t.data[i]
    if t.data != nil:
      deallocShared(t.data)
    t.data = d
    t.cap = cap
  for i, c in s:
    t.data[t.len + i] = c
  t.len += s.len

proc getText(t: SharedText): string =
  result = newString(t.len)
  for i in 0 ..< t.len:
    result[i] = t.data[i]

func hexOf(b: openArray[byte]): string =
  const digits = "0123456789abcdef"
  for x in b:
    result.add(digits[int(x shr 4)])
    result.add(digits[int(x and 0x0F)])

func nibble(c: char): int =
  case c
  of '0' .. '9':
    ord(c) - ord('0')
  of 'a' .. 'f':
    ord(c) - ord('a') + 10
  else:
    0

func unhex(s: string): seq[byte] =
  var i = 0
  while i + 1 < s.len:
    result.add(byte(nibble(s[i]) * 16 + nibble(s[i + 1])))
    i += 2

func joined(xs: openArray[string]): string =
  xs.join(",")

func split1(s: string): seq[string] =
  if s.len == 0:
    @[]
  else:
    s.split(',')

proc encodeRule(r: Rule): string =
  var methods = "-"
  if r.narrowMethods.isSome:
    var hs: seq[string]
    for m in r.narrowMethods.get:
      hs.add(hexOf(m))
    methods = "=" & hs.joined
  let providers =
    if r.narrowProviders.isSome:
      "=" & r.narrowProviders.get.joined
    else:
      "-"
  [
    r.consumer,
    r.what,
    $ord(r.verdict),
    $r.validMs,
    r.grants.joined,
    $r.revision,
    methods,
    providers,
    (if r.retainRequest: "q" else: "") & (if r.retainResponse: "s" else: ""),
    $r.code,
  ].join("\x1F")

proc decodeRule(s: string): Rule =
  let f = s.split('\x1F')
  try:
    result = Rule(
      consumer: f[0],
      what: f[1],
      verdict: Verdict(parseInt(f[2])),
      validMs: parseBiggestInt(f[3]),
      grants: split1(f[4]),
      revision: uint64(parseBiggestUInt(f[5])),
      retainRequest: 'q' in f[8],
      retainResponse: 's' in f[8],
      code: parseInt(f[9]),
    )
  except ValueError:
    return Rule(verdict: vStatus)
  if f[6] != "-":
    var ms: seq[seq[byte]]
    for h in split1(f[6][1 ..^ 1]):
      ms.add(unhex(h))
    result.narrowMethods = Opt.some(ms)
  if f[7] != "-":
    result.narrowProviders = Opt.some(split1(f[7][1 ..^ 1]))

# Test controls -------------------------------------------------------------------------

func allow*(
    what = "", consumer = "", validMs = Everything, grants: seq[string] = @[]
): Rule =
  Rule(
    what: what, consumer: consumer, verdict: vAllow, validMs: validMs, grants: grants
  )

func rule*(verdict: Verdict, what = "", consumer = "", code = 0): Rule =
  Rule(
    what: what, consumer: consumer, verdict: verdict, validMs: Everything, code: code
  )

proc setScript*(rules: varargs[Rule]) =
  ## The rules `evaluate` answers by, the first matching one first; nothing
  ## matching allows for ten minutes.
  var parts: seq[string]
  for r in rules:
    parts.add(encodeRule(r))
  withLock lock:
    script.setText(parts.join("\x1E"))

proc useClock*(c: Clock) =
  ## The clock `issued_at` and `valid_until` are read from; set before the
  ## engine starts.
  fakeClock = c

proc hold*() =
  ## `vHang` evaluations wait until `release`.
  hangGate.store(true)

proc release*() =
  hangGate.store(false)

proc tick*(): int =
  ## One step of the order every evaluation is recorded in, for a probe.
  order.fetchAdd(1) + 1

proc received*(): seq[Received] =
  var text: string
  withLock lock:
    text = records.getText()
  for line in text.split('\x1E'):
    if line.len == 0:
      continue
    let f = line.split('\x1F')
    try:
      result.add(
        Received(
          what: f[0],
          consumer: f[1],
          callerKind: uint32(parseInt(f[2])),
          thread: parseInt(f[3]),
          order: parseInt(f[4]),
          request: unhex(f[5]),
        )
      )
    except ValueError:
      discard

proc forget*() =
  withLock lock:
    records.len = 0

proc resetFake*() =
  ## A new authority: no script, no records, policy revision 0, the gate open.
  setScript()
  release()
  forget()
  revision.store(0)
  failInit.store(false)

proc publish*(name: string, payload: openArray[byte]): bool =
  ## Through the latest initialization's publish callback, on this thread.
  let f = cast[LogosPublishFn](publishFn.load)
  if f.isNil:
    return false
  if name == PolicyChangedName:
    # A real authority publishes a revision once its policy is at it.
    let n = LogosNSCapabilityAuthorityPolicyChangedEvent.decode(@payload)
    if n.isOk:
      revision.store(max(revision.load, n.get.policy_revision))
  f(
    publishData.load,
    cstring(name),
    (
      if payload.len == 0: nil
      else: cast[ptr UncheckedArray[uint8]](unsafeAddr payload[0])
    ),
    csize_t(payload.len),
  )
  true

proc grantChanged*(
    grant: string, kind: GrantStatusKind, target: string, runtime: string
): seq[byte] =
  encode(
    LogosNSCapabilityAuthorityGrantChangedEvent(
      grant: LogosNSCapabilityAuthorityGrant(
        grant_id: grant,
        issued_at: 1,
        issuer: LogosNSCapabilityAuthorityGrantIssuer(
          kind: LogosNSCapabilityAuthorityGrantIssuerKind.Protected_policy,
          arm_Protected_policy:
            LogosNSCapabilityAuthorityGrantIssuerARProtectedPolicyMap(source: "test"),
        ),
        status: LogosNSCapabilityAuthorityGrantStatus(kind: kind),
        target: Address(runtime_instance_id: runtime, module_instance_id: target),
        scopes: @[],
      )
    )
  )
    .get(newSeq[byte]())

proc policyChanged*(
    previous, revision: uint64, affected = Opt.none(seq[(string, string)])
): seq[byte] =
  var e = LogosNSCapabilityAuthorityPolicyChangedEvent(
    previous_policy_revision: previous, policy_revision: revision, changed_at: 1
  )
  if affected.isSome:
    var xs: seq[Address]
    for (rt, id) in affected.get:
      xs.add(Address(runtime_instance_id: rt, module_instance_id: id))
    e.affected_executions = Opt.some(xs)
  encode(e).get(newSeq[byte]())

# Classification ------------------------------------------------------------------------

proc whatOf(s: Scope): string =
  case s.kind
  of skProvider:
    if s.pa.actions.len == 0:
      return "?"
    ($s.pa.actions[0].kind).toLowerAscii.replace('_', '-')
  of skControl:
    if s.rc.methods.isSome and s.rc.methods.get.len == 1:
      for name, root in rcContractInfo().methods:
        if root == s.rc.methods.get[0]:
          return "rc:" & name
    "rc:?"
  of skExecution:
    if s.me.actions.len == 1 and s.me.actions[0].kind == MeActionKind.Stop:
      "stop"
    else:
      "execute"
  else:
    "?"

proc matching(rules: seq[Rule], what, consumer: string): Rule =
  for r in rules:
    if (r.what.len == 0 or r.what == what) and
        (r.consumer.len == 0 or r.consumer == consumer):
      return r
  allow()

# The module ------------------------------------------------------------------------------

type Ctx = object
  access: LogosInvocationAccess

proc fakeInit(
    input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
): LogosResult {.cdecl, gcsafe.} =
  if failInit.load:
    return LogosResult(code: CErrorCode(ord(ecModule)))
  inits += 1
  publishFn.store(cast[pointer](input.publish))
  publishData.store(input.publishUserData)
  let c = cast[ptr Ctx](allocShared0(sizeof(Ctx)))
  c.access = input.invocationAccess
  outContext[] = cast[ptr LogosModuleContext](c)

proc fakeDestroy(module: ptr LogosModuleContext) {.cdecl, gcsafe.} =
  publishFn.store(nil)
  deallocShared(module)

proc fakeFree(module: ptr LogosModuleContext, p: pointer) {.cdecl, gcsafe.} =
  if p != nil:
    deallocShared(p)

proc respond(
    bytes: openArray[byte], outResp: ptr ptr UncheckedArray[uint8], outLen: ptr csize_t
) =
  let p = cast[ptr UncheckedArray[uint8]](allocShared0(max(bytes.len, 1)))
  for i, b in bytes:
    p[i] = b
  outResp[] = p
  outLen[] = csize_t(bytes.len)

proc broadened(s: Scope): Scope =
  result = s
  case s.kind
  of skProvider:
    result.pa.access = Opt.none(RouteAccess)
    result.pa.providers = Opt.none(seq[ProviderAddress])
    result.pa.routes = Opt.none(seq[string])
  of skControl:
    result.rc.methods = Opt.none(seq[seq[byte]])
  of skExecution:
    result.me.instance = Opt.none(string)
  else:
    discard

proc decision(
    r: Rule, req: LogosNSCapabilityAuthorityEvaluateRequest, now, at: uint64
): Decision =
  ## `at`: the policy revision when the request was read.
  result = Decision(
    consumer: req.consumer,
    decision_id: "fd-" & $(decisions.fetchAdd(1) + 1),
    issued_at: now,
    policy_revision: max(r.revision, at),
    requested_scopes: req.scopes,
  )
  var allowed = req.scopes
  if r.narrowMethods.isSome or r.narrowProviders.isSome:
    for s in allowed.mitems:
      if s.kind == skProvider:
        if r.narrowMethods.isSome:
          var a = s.pa.access.get(RouteAccess())
          a.methods = Opt.some(r.narrowMethods.get)
          s.pa.access = Opt.some(a)
        if r.narrowProviders.isSome:
          var ps: seq[ProviderAddress]
          for p in r.narrowProviders.get:
            ps.add(
              ProviderAddress(
                provider: p,
                runtime_instance_id: Opt.some(req.consumer.runtime_instance_id),
              )
            )
          s.pa.providers = Opt.some(ps)
  case r.verdict
  of vDeny, vDenyWithAllowed:
    result.result = LogosNSCapabilityAuthorityDecisionResult(
      kind: LogosNSCapabilityAuthorityDecisionResultKind.Deny
    )
    result.denial = Opt.some(
      LogosNSCapabilityAuthorityDenial(
        code: LogosNSCapabilityAuthorityDenialCode(
          kind: LogosNSCapabilityAuthorityDenialCodeKind(r.code)
        )
      )
    )
    if r.verdict == vDenyWithAllowed:
      result.allowed_scopes = Opt.some(allowed)
    return
  else:
    result.result = LogosNSCapabilityAuthorityDecisionResult(
      kind: LogosNSCapabilityAuthorityDecisionResultKind.Allow
    )
  result.allowed_scopes = Opt.some(allowed)
  if r.validMs > 0 and r.verdict != vNoValidity:
    result.valid_until = Opt.some(now + uint64(r.validMs))
  if r.grants.len > 0:
    result.grant_ids = Opt.some(r.grants)
  if r.retainRequest or r.retainResponse:
    var c = LogosNSCapabilityAuthorityCommitmentRequirements()
    if r.retainRequest:
      c.request = Opt.some("retain-root")
    if r.retainResponse:
      c.response = Opt.some("retain-root")
    result.commitment = Opt.some(c)
  case r.verdict
  of vWrongConsumer:
    result.consumer.module_instance_id = "someone-else"
  of vOtherScopes:
    result.requested_scopes = @[]
  of vBroadened:
    result.allowed_scopes = Opt.some(@[broadened(req.scopes[0])])
  of vUncovered:
    result.allowed_scopes = Opt.some(newSeq[Scope]())
  of vUnordered:
    result.allowed_scopes = Opt.some(@[allowed[0], allowed[0]])
  of vAllowWithDenial:
    result.denial = Opt.some(
      LogosNSCapabilityAuthorityDenial(
        code: LogosNSCapabilityAuthorityDenialCode(
          kind: LogosNSCapabilityAuthorityDenialCodeKind.Not_granted
        )
      )
    )
  of vBadValidity:
    result.valid_until = Opt.some(now)
  of vExpired:
    result.issued_at = now - 2000
    result.valid_until = Opt.some(now - 1000)
  of vPlacements:
    var s = allowed[0]
    if s.kind == skExecution:
      s.me.placements = Opt.some(newSeq[LogosNSCapabilityAuthorityHostedPlacement]())
    result.allowed_scopes = Opt.some(@[s])
  of vPermission:
    result.allowed_scopes = Opt.some(@[toScope(PermissionScope(permission: "camera"))])
  else:
    discard

proc fakeDispatch(
    module: ptr LogosModuleContext,
    methodName: cstring,
    params: ptr UncheckedArray[uint8],
    paramsLen: csize_t,
    outResp: ptr ptr UncheckedArray[uint8],
    outLen: ptr csize_t,
): LogosResult {.cdecl, gcsafe.} =
  {.cast(gcsafe).}:
    if $methodName != "evaluate":
      return LogosResult(code: CErrorCode(ord(ecModule)))
    let c = cast[ptr Ctx](module)
    let inv =
      if c.access.current.isNil:
        nil
      else:
        c.access.current(c.access.state)
    var view: LogosCallerView
    if inv != nil:
      discard inv.vtable.caller(inv, addr view)
    var bytes = newSeq[byte](int(paramsLen))
    for i in 0 ..< bytes.len:
      bytes[i] = params[i]
    let req = LogosNSCapabilityAuthorityEvaluateRequest.decode(bytes).valueOr:
      return LogosResult(code: CErrorCode(ord(ecInvalidParams)))
    let what =
      if req.scopes.len > 0:
        whatOf(req.scopes[0])
      else:
        "?"
    let at = revision.load
    let consumer = req.consumer.module_instance_id
    var rules: seq[Rule]
    withLock lock:
      let text = script.getText()
      records.addText(
        [what, consumer, $view.kind, $getThreadId(), $tick(), hexOf(bytes)].join("\x1F") &
          "\x1E"
      )
      for part in text.split('\x1E'):
        if part.len > 0:
          rules.add(decodeRule(part))
    var r = matching(rules, what, consumer)
    if r.verdict == vHang:
      hanging += 1
      var seen = false
      while hangGate.load:
        if not seen and inv != nil and inv.vtable.isCancelled(inv):
          seen = true
          sawCancel += 1
        sleep(1)
      hanging -= 1
      r.verdict = vAllow
    case r.verdict
    of vStatus:
      return LogosResult(code: CErrorCode(ord(ecModule)))
    of vBadCbor:
      respond([0xFF'u8], outResp, outLen)
      return LogosResult()
    of vError:
      let resp = LogosNSCapabilityAuthorityEvaluateResponse(
        kind: LogosNSCapabilityAuthorityEvaluateResponseKind.Map_error,
        arm_Map_error: LogosNSCapabilityAuthorityEvaluateResponseARMapErrorMap(
          error: LogosNSCapabilityAuthorityError(
            code: LogosNSCapabilityAuthorityErrorCode(
              kind: LogosNSCapabilityAuthorityErrorCodeKind(r.code)
            )
          )
        ),
      )
      respond(encode(resp).get(newSeq[byte]()), outResp, outLen)
      return LogosResult()
    else:
      discard
    let now = uint64(max(fakeClock.wallMs, 0))
    let resp = LogosNSCapabilityAuthorityEvaluateResponse(
      kind: LogosNSCapabilityAuthorityEvaluateResponseKind.Map_decision,
      arm_Map_decision: LogosNSCapabilityAuthorityEvaluateResponseARMapDecisionMap(
        decision: decision(r, req, now, at)
      ),
    )
    respond(encode(resp).get(newSeq[byte]()), outResp, outLen)
    LogosResult()

proc realSymbol(suffix: string): pointer =
  for (n, p) in logosCapabilityAuthorityStaticSymbols():
    if n == "logos_logos_capability_authority_MODULE_" & suffix:
      return p
  nil

proc fakeCaRegistration*(binding = "fakeca"): StaticRegistration =
  ## A Logos-defined system module (CA l.143), as the real one: its name, call
  ## surface and typed `_CALL_` symbols are the real ones (the Runtime calls
  ## through `dispatch`), its lifecycle and dispatch are the script's.
  var symbols = @[
    ("logos_logos_capability_authority_MODULE_name", realSymbol("name")),
    ("logos_logos_capability_authority_MODULE_call_surface", realSymbol("call_surface")),
    ("logos_logos_capability_authority_MODULE_init", cast[pointer](fakeInit)),
    ("logos_logos_capability_authority_MODULE_destroy", cast[pointer](fakeDestroy)),
    ("logos_logos_capability_authority_MODULE_dispatch", cast[pointer](fakeDispatch)),
    ("logos_logos_capability_authority_MODULE_free", cast[pointer](fakeFree)),
  ]
  for (n, p) in logosCapabilityAuthorityStaticSymbols():
    if "_CALL_" in n:
      symbols.add((n, p))
  result = checkStaticRegistration(binding, symbols).expect(
      "the fake authority's symbol table"
    )
  result.system = true

proc caRootDigest*(): Digest =
  var d: Digest
  let r = caContract().schema_root
  for i in 0 ..< d.len:
    d[i] = r[i]
  d

proc fakeCaRecord*(binding = "fakeca"): ModuleRecord =
  ModuleRecord(
    module: CaModuleName,
    strategy: stDirectStatic,
    binding: binding,
    primaryContract: Opt.some(caRootDigest()),
  )
