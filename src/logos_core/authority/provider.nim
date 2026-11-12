## The Capability Authority as a module (step 8a.2; DECISIONS I84): the
## `direct_static` module `logos_capability_authority` (CA l.143), built with
## its lcn-gen kit over `core.nim`, and the embedded wiring that gives an
## instance its policy, Runtime id, facts and clock (RUNTIME l.1681,
## l.3075-3077; §2.3, §2.15 of the plan).
##
## - `wireAuthority(stateDir, wiring)` records the inputs for the instance whose
##   state directory is `stateDir`. The instance's `initModule` reads them; a
##   missing state directory or wiring fails init with MODULE_ERROR. Step 8b
##   wires at host create; the wiring stays until `unwireAuthority`, so a
##   recovered instance starts again.
## - The caller comes from the invocation context (INTERFACE §2.9.3), never from
##   a payload field (CAP-0146, CAP-0147).
## - `grant_changed` and `policy_changed` go out through the instance's publish
##   callback, which 8b intercepts (§2.11). `observed_change` goes only through
##   a watch's invocation scope (CAP-0366, CAP-0367).
## - `watch_changes` runs on the invocation's own thread until it is cancelled
##   or the authority closes. Call it asynchronously: a synchronous call holds
##   the calling thread until then.

{.push raises: [], gcsafe.}

import std/[locks, monotimes, times]
import results
import ../runtime/native
import ./[core, logos_capability_authority_kit]

export core, native

# Wiring -------------------------------------------------------------------------------

type
  AuthorityWiring* = object
    ## The embedded inputs of one CA instance (§2.15): the policy
    ## (`lcn.authority_policy`), the Runtime id, the facts table step 8b feeds,
    ## the clock and the limits.
    policy*: seq[byte]
    runtimeId*: string
    facts*: SharedFacts
    clock*: Clock
    limits*: AuthorityLimits

  WiringEntry = object ## One wiring, in shared memory: read from any thread.
    stateDir: cstring
    policy: ptr UncheckedArray[byte]
    policyLen: int
    runtimeId: cstring
    facts: SharedFacts
    clock: Clock
    limits: AuthorityLimits
    next: ptr WiringEntry

var wiringLock: Lock
var wirings: ptr WiringEntry
initLock(wiringLock)

proc sharedText(s: string): cstring =
  let p = cast[cstring](allocShared0(s.len + 1))
  if s.len > 0:
    copyMem(p, unsafeAddr s[0], s.len)
  p

proc freeEntry(e: ptr WiringEntry) =
  deallocShared(e.stateDir)
  deallocShared(e.runtimeId)
  if e.policy != nil:
    deallocShared(e.policy)
  deallocShared(e)

proc wireAuthority*(stateDir: string, w: AuthorityWiring): Result[void, string] =
  ## Records the wiring of the CA instance whose state directory is
  ## `stateDir`. A second wiring of one directory is refused.
  if stateDir.len == 0:
    return err("the state directory is empty")
  if w.facts == nil:
    return err("the wiring has no facts table")
  if w.runtimeId.len == 0:
    return err("the wiring has no runtime id")
  let e = cast[ptr WiringEntry](allocShared0(sizeof(WiringEntry)))
  e.stateDir = sharedText(stateDir)
  e.runtimeId = sharedText(w.runtimeId)
  e.policyLen = w.policy.len
  if w.policy.len > 0:
    e.policy = cast[ptr UncheckedArray[byte]](allocShared0(w.policy.len))
    copyMem(e.policy, unsafeAddr w.policy[0], w.policy.len)
  e.facts = w.facts
  e.clock = w.clock
  e.limits = w.limits
  var taken = false
  withLock wiringLock:
    var p = wirings
    while p != nil:
      if $p.stateDir == stateDir:
        taken = true
        break
      p = p.next
    if not taken:
      e.next = wirings
      wirings = e
  if taken:
    freeEntry(e)
    return err("the state directory is already wired")
  ok()

proc unwireAuthority*(stateDir: string) =
  ## Forgets the wiring of `stateDir`. An instance already started keeps its
  ## copy.
  var gone: ptr WiringEntry
  withLock wiringLock:
    var p = addr wirings
    while p[] != nil:
      if $p[].stateDir == stateDir:
        gone = p[]
        p[] = gone.next
        break
      p = addr p[].next
  if gone != nil:
    freeEntry(gone)

proc readWiring(stateDir: string): Opt[AuthorityWiring] =
  withLock wiringLock:
    var p = wirings
    while p != nil:
      if $p.stateDir == stateDir:
        var w = AuthorityWiring(
          runtimeId: $p.runtimeId, facts: p.facts, clock: p.clock, limits: p.limits
        )
        w.policy = newSeq[byte](p.policyLen)
        if p.policyLen > 0:
          copyMem(addr w.policy[0], p.policy, p.policyLen)
        return Opt.some(w)
      p = p.next
  Opt.none(AuthorityWiring)

# The module ----------------------------------------------------------------------------

type
  SinkEnv = object
    services: ModuleServices

  CaModule* = ref object
    ## One CA instance: the authority it opened and the services it was given.
    authority: Authority
    services: ModuleServices
    sinkEnv: ptr SinkEnv

const NotWired = "the capability authority is not wired"

proc publishNotify(
    env: pointer, ev: sink AuthorityEvent
): bool {.nimcall, gcsafe, raises: [].} =
  ## [§2.11] The engine path: the instance's ordinary publish callback, on the
  ## CA thread, with no CA lock held. The kit refuses an instance without the
  ## callback, so false is an encoding failure; it makes every later
  ## evaluation `authority-unavailable`.
  let s = cast[ptr SinkEnv](env)
  case ev.kind
  of aeGrantChanged:
    s.services.publish(LogosNSCapabilityAuthorityGrantChangedEvent(grant: ev.grant)).isOk
  of aePolicyChanged:
    s.services.publish(ev.policy).isOk

proc initModule(
    _: type CaModule, init: ModuleInit
): Result[CaModule, InvocationFailure] =
  if init.stateDir.isNone:
    return err(moduleError(NotWired))
  let w = readWiring(init.stateDir.get).valueOr:
    return err(moduleError(NotWired))
  let env = cast[ptr SinkEnv](allocShared0(sizeof(SinkEnv)))
  env.services = init.services
  let cfg = AuthorityConfig(
    stateDir: init.stateDir.get,
    policy: w.policy,
    runtimeId: w.runtimeId,
    facts: w.facts,
    clock: w.clock,
    limits: w.limits,
    sink: AuthoritySink(env: env, notify: publishNotify),
  )
  let a = openAuthority(cfg).valueOr:
    deallocShared(env)
    return err(moduleError("the capability authority does not start: " & error))
  ok(CaModule(authority: a, services: init.services, sinkEnv: env))

proc destroyModule(m: CaModule) =
  ## [§2.3] Closes the authority: new requests are refused, queued ones
  ## answered, every watch ends, audit is flushed and the thread joined.
  closeAuthority(m.authority)
  deallocShared(m.sinkEnv)

var activeServices {.threadvar.}: ModuleServices
  ## The services of the provider entry running on this thread, for
  ## `invocationCancelled`.

proc invocationCancelled(): bool {.nimcall, gcsafe, raises: [].} =
  activeServices.isCancelled()

proc callerOf(m: CaModule): CallerInfo =
  ## [SPEC INTERFACE §2.9.3] The authenticated caller; none when the context
  ## gives none, which every method refuses.
  activeServices = m.services
  let c = m.services.caller().valueOr:
    return CallerInfo(kind: ckNone)
  if c.kind == ckSystemService:
    CallerInfo(kind: ckSystem)
  elif c.moduleInstance.isSome:
    CallerInfo(
      kind: ckModule,
      address: Address(
        runtime_instance_id: c.runtimeInstance, module_instance_id: c.moduleInstance.get
      ),
    )
  else:
    CallerInfo(kind: ckNone)

proc `evaluate`(
    m: CaModule, request: EvaluateRequest
): Result[EvaluateResponse, InvocationFailure] =
  let caller = m.callerOf()
  ok(m.authority.evaluate(caller, request, invocationCancelled))

proc `issue_grant`(
    m: CaModule, request: IssueGrantRequest
): Result[IssueGrantResponse, InvocationFailure] =
  let caller = m.callerOf()
  ok(m.authority.issueGrant(caller, request, invocationCancelled))

proc `revoke_grant`(
    m: CaModule, request: RevokeGrantRequest
): Result[RevokeGrantResponse, InvocationFailure] =
  let caller = m.callerOf()
  ok(m.authority.revokeGrant(caller, request, invocationCancelled))

proc `get_grant`(
    m: CaModule, request: GetGrantRequest
): Result[GetGrantResponse, InvocationFailure] =
  let caller = m.callerOf()
  ok(m.authority.getGrant(caller, request, invocationCancelled))

proc `list_grants`(
    m: CaModule, request: ListGrantsRequest
): Result[ListGrantsResponse, InvocationFailure] =
  let caller = m.callerOf()
  ok(m.authority.listGrants(caller, request, invocationCancelled))

proc `query_audit`(
    m: CaModule, request: QueryAuditRequest
): Result[QueryAuditResponse, InvocationFailure] =
  let caller = m.callerOf()
  ok(m.authority.queryAudit(caller, request, invocationCancelled))

const ObservedChange = "logos.capability_authority.observed_change_event"

proc `watch_changes`(
    m: CaModule, request: WatchChangesRequest
): Result[WatchChangesResponse, InvocationFailure] =
  ## [SPEC CA §8.1; G82] Registers a watch, then publishes each admitted change
  ## as one invocation-scoped `observed_change`, with no CA lock held
  ## (CAP-0366, CAP-0375), until the invocation is cancelled, the authority
  ## closes or the destination goes (`{}`), or the watch overflows
  ## (`authority-unavailable`, CAP-0383). Cancellation is seen within 50 ms
  ## (CAP-0381). Ending a watch revokes nothing (CAP-0369).
  let caller = m.callerOf()
  let w = m.authority.watch(caller, request.consumer).valueOr:
    return ok(watchError(error))
  var outcome = watchEnded()
  while true:
    if m.services.isCancelled() or w.isEnded:
      break
    if w.overflowed:
      outcome = watchError(CaCode.Authority_unavailable)
      break
    let item = w.nextChange()
    if item.isSome:
      if m.services.publishScopedEncoded(ObservedChange, item.get).isErr:
        break # the destination is gone (l.956)
      continue
    w.waitChange(getMonoTime() + initDuration(milliseconds = 50))
  m.authority.unwatch(w)
  ok(outcome)

exportLogosCapabilityAuthority(CaModule)

proc caStaticRegistration*(): StaticRegistration =
  ## [SPEC RUNTIME §13.3] The CA's symbol table, for a `direct_static`
  ## declaration with binding `logos_capability_authority`. [SPEC INTERFACE
  ## §1.3; CA l.143] A Logos-defined system module: its call surface uses the
  ## reserved `logos` names.
  result = checkStaticRegistration(moduleName, logosCapabilityAuthorityStaticSymbols())
    .expect("the capability authority's symbol table")
  result.system = true
