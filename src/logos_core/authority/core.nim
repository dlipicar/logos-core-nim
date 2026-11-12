## The Capability Authority: one thread that owns all of its state [IMPL]
## (CA §2-§10; DECISIONS I84, G205-G207).
##
## - **Threading.** Requests and replies are plain values over channels, so no
##   garbage-collected memory crosses threads under ORC or refc. Requests from
##   the Runtime (`SYSTEM_SERVICE` callers and this module's administrative
##   entries) go to the engine inbox, which is drained first on every wake-up;
##   module requests go to a bounded module inbox, one at a time between checks
##   of the engine inbox, so ordinary traffic cannot hold back engine
##   evaluation (CAP-0382). A full module inbox refuses the request
##   (`authority-unavailable`) before evaluation: an admission failure, not
##   audited (CA l.1170-1171).
## - **Giving up** (D5). A module caller waits at most `moduleTimeoutMs`, and
##   any caller stops when cancelled. A request the CA thread has not claimed is
##   withdrawn (dropped unprocessed, no record) and answered
##   `authority-unavailable`; a claimed one is waited for, so a caller is never
##   told `authority-unavailable` about a change that commits.
## - **The CA thread never waits on the Runtime thread.** Facts come from
##   `SharedFacts` under its own lock, and engine notifications go through the
##   sink, which step 8b handles without waiting on the CA.
## - **The order of checks** is §2.14 of the step 8a plan (G205, the S8a-1
##   interim, "TL-04, extended"): caller, admission, form, locality,
##   permission, availability, the issuer check (`issue_grant`), resolution,
##   visibility, policy, state.

{.push raises: [].}

import
  std/[algorithm, atomics, deques, heapqueue, locks, monotimes, sets, tables, times]
import results
import ../base/clock
import ../runtime/bell
import ./[audit, cursor, facts, grants, ids, persist, policy, scopes, state_types]

export results, clock, facts, scopes, policy

type
  AuthorityLimits* = object ## [IMPL] Every bound, settable by tests.
    maxScopes*: int = 64 ## scopes in one request
    moduleQueue*: int = 1024 ## queued module requests
    maxGrants*: int = 16_384 ## retained grants
    maxWatches*: int = 64 ## live `watch_changes` in all
    watchesPerConsumer*: int = 8
    watchQueue*: int = 256 ## notifications queued per watch
    cursorLifetimeMs*: uint64 = 600_000
    responseBudget*: int = 15 * 1024 * 1024 ## encoded bytes per list or query response
    maxUnwritten*: int = 4_096
      ## audit records not yet durable before evaluation fails closed
    moduleTimeoutMs*: int = 30_000
    segmentRecords*: int = 256
    flushMs*: int64 = 1_000
    policyRecords*: int = 64 ## retained policy-change records
    listDefault*: int = 100
    listMax*: int = 1_000
    queryMax*: int = 1_000

  AuthorityEventKind* = enum
    aeGrantChanged
    aePolicyChanged

  AuthorityEvent* = object
    case kind*: AuthorityEventKind
    of aeGrantChanged:
      grant*: Grant
    of aePolicyChanged:
      policy*: PolicyChangedEvent

  AuthoritySink* = object
    ## The engine notification path (§2.11). `notify` runs on the CA thread,
    ## inside the transition, after the new state is active and before the
    ## reply. `false` means the path is lost: every later evaluation then fails
    ## `authority-unavailable` until the instance restarts.
    env*: pointer
    notify*:
      proc(env: pointer, ev: sink AuthorityEvent): bool {.nimcall, gcsafe, raises: [].}

  CallerKind* = enum
    ckNone
    ckModule
    ckSystem

  CallerInfo* = object
    ## Who invoked the method, from the invocation context (INTERFACE §2.9.3),
    ## never from a payload (CAP-0146, CAP-0147).
    kind*: CallerKind
    address*: Address ## for a module caller

  CancelFn* = proc(): bool {.nimcall, gcsafe, raises: [].}

  WatchShared* = object
    ## One `watch_changes` (G82): the changes admitted for its consumer, as
    ## encoded `observed_change` payloads, sent by the CA thread and taken by
    ## the watch body on the invocation's thread. Freed by `unwatch` once the
    ## CA thread has let go of it.
    ch: Channel[seq[byte]]
    bell: Bell
    overflow: Atomic[bool] ## a change did not fit (CAP-0382, CAP-0383)
    ended: Atomic[bool] ## the authority closed; the CA thread let go

  Watch* = ptr WatchShared

  AuthorityConfig* = object
    stateDir*: string
    policy*: seq[byte] ## an `lcn.authority_policy` value
    runtimeId*: string
    facts*: SharedFacts
    clock*: Clock
    limits*: AuthorityLimits
    sink*: AuthoritySink
    entropy*: EntropyFn

  EvaluateRequest* = LogosNSCapabilityAuthorityEvaluateRequest
  EvaluateResponse* = LogosNSCapabilityAuthorityEvaluateResponse
  IssueGrantRequest* = LogosNSCapabilityAuthorityIssueGrantRequest
  IssueGrantResponse* = LogosNSCapabilityAuthorityIssueGrantResponse
  RevokeGrantRequest* = LogosNSCapabilityAuthorityRevokeGrantRequest
  RevokeGrantResponse* = LogosNSCapabilityAuthorityRevokeGrantResponse
  GetGrantRequest* = LogosNSCapabilityAuthorityGetGrantRequest
  GetGrantResponse* = LogosNSCapabilityAuthorityGetGrantResponse
  ListGrantsRequest* = LogosNSCapabilityAuthorityListGrantsRequest
  ListGrantsResponse* = LogosNSCapabilityAuthorityListGrantsResponse
  QueryAuditRequest* = LogosNSCapabilityAuthorityQueryAuditRequest
  QueryAuditResponse* = LogosNSCapabilityAuthorityQueryAuditResponse
  WatchChangesRequest* = LogosNSCapabilityAuthorityWatchChangesRequest
  WatchChangesResponse* = LogosNSCapabilityAuthorityWatchChangesResponse

  RequestKind = enum
    rqEvaluate
    rqIssue
    rqRevoke
    rqGet
    rqList
    rqQuery
    rqIssueProtected
    rqRevokeProtected
    rqReplacePolicy
    rqTick
    rqFlush
    rqInject
    rqWatch
    rqUnwatch

  Request = object
    slot: ptr ReplySlot
    caller: CallerInfo
    case kind: RequestKind
    of rqEvaluate:
      evaluate: EvaluateRequest
    of rqIssue:
      issue: IssueGrantRequest
    of rqRevoke:
      revoke: RevokeGrantRequest
    of rqGet:
      get: GetGrantRequest
    of rqList:
      list: ListGrantsRequest
    of rqQuery:
      query: QueryAuditRequest
    of rqIssueProtected:
      pSource: string
      pTarget: Address
      pScopes: seq[Scope]
      pExpires: Opt[uint64]
      pCommitment: Opt[CommitmentRequirements]
    of rqRevokeProtected:
      rSource: string
      rGrant: string
      rReason: Opt[string]
    of rqReplacePolicy:
      policyBytes: seq[byte]
    of rqTick, rqFlush:
      discard
    of rqInject:
      failNext: int
      failAll: bool
    of rqWatch:
      watchConsumer: Address
    of rqUnwatch:
      watch: Watch

  Reply = object
    case kind: RequestKind
    of rqEvaluate:
      evaluated: EvaluateResponse
    of rqIssue:
      issued: IssueGrantResponse
    of rqRevoke:
      revoked: RevokeGrantResponse
    of rqGet:
      got: GetGrantResponse
    of rqList:
      listed: ListGrantsResponse
    of rqQuery:
      queried: QueryAuditResponse
    of rqIssueProtected, rqRevokeProtected:
      protected: Result[Grant, CaError]
    of rqReplacePolicy:
      replaced: Result[uint64, string]
    of rqWatch:
      watched: Result[Watch, CaCode]
    of rqTick, rqFlush, rqInject, rqUnwatch:
      discard

  ReplySlot = object
    ## One reply channel, reused call after call and closed only after the CA
    ## thread is joined (the late-signal hazard `runtime/plumbing.nim`'s
    ## `ReplySlot` describes).
    ch: Channel[Reply]
    bell: Bell
    state: Atomic[int] ## 0 queued, 1 claimed by the CA thread, 2 withdrawn
    nextFree: ptr ReplySlot
    nextAll: ptr ReplySlot

  AuthorityShared* = object
    engineInbox: Channel[Request]
    moduleInbox: Channel[Request]
    bell: Bell
    admitLock: Lock
    closed: bool ## under `admitLock`
    slotLock: Lock
    freeSlots: ptr ReplySlot
    allSlots: ptr ReplySlot
    thread: Thread[ptr AuthorityShared]
    start: Channel[AuthorityConfig]
    started: Channel[string]
    revision: Atomic[uint64]
    watching: Atomic[int] ## live watches, for tests
    moduleTimeoutMs: int
    stateDir: cstring
    nextOpen: ptr AuthorityShared ## the registry of open authorities

  Authority* = ptr AuthorityShared

const
  ErrorText: array[CaCode, string] = [
    "the capability authority is unavailable", "the grant is not active",
    "no such grant", "internal error", "the constraints are invalid",
    "the request is invalid", "not authorised", "unknown permission",
    "unsupported scope",
  ]
  DenialText: array[DenialKind, string] = [
    "approval is required", "the consumer is denied", "the grant has expired",
    "the grant has been revoked", "not granted", "the scope is denied",
    "the target is denied",
  ]

# Values -----------------------------------------------------------------------------

func errorCode(c: CaCode): LogosNSCapabilityAuthorityErrorCode =
  LogosNSCapabilityAuthorityErrorCode(kind: c)

func errorValue(c: CaCode): LogosNSCapabilityAuthorityError =
  LogosNSCapabilityAuthorityError(code: errorCode(c), message: Opt.some(ErrorText[c]))

func denialValue(k: DenialKind): Denial =
  Denial(
    code: LogosNSCapabilityAuthorityDenialCode(kind: k),
    message: Opt.some(DenialText[k]),
  )

func evaluateError(c: CaCode): EvaluateResponse =
  EvaluateResponse(
    kind: LogosNSCapabilityAuthorityEvaluateResponseKind.Map_error,
    arm_Map_error:
      LogosNSCapabilityAuthorityEvaluateResponseARMapErrorMap(error: errorValue(c)),
  )

func evaluateDecision(d: Decision): EvaluateResponse =
  EvaluateResponse(
    kind: LogosNSCapabilityAuthorityEvaluateResponseKind.Map_decision,
    arm_Map_decision:
      LogosNSCapabilityAuthorityEvaluateResponseARMapDecisionMap(decision: d),
  )

func issueError(c: CaCode): IssueGrantResponse =
  IssueGrantResponse(
    kind: LogosNSCapabilityAuthorityIssueGrantResponseKind.Map_error,
    arm_Map_error:
      LogosNSCapabilityAuthorityIssueGrantResponseARMapErrorMap(error: errorValue(c)),
  )

func issueDenial(k: DenialKind): IssueGrantResponse =
  IssueGrantResponse(
    kind: LogosNSCapabilityAuthorityIssueGrantResponseKind.Map_denial,
    arm_Map_denial:
      LogosNSCapabilityAuthorityIssueGrantResponseARMapDenialMap(denial: denialValue(k)),
  )

func issueGrantValue(g: Grant): IssueGrantResponse =
  IssueGrantResponse(
    kind: LogosNSCapabilityAuthorityIssueGrantResponseKind.Map_grant,
    arm_Map_grant: LogosNSCapabilityAuthorityIssueGrantResponseARMapGrantMap(grant: g),
  )

func revokeError(c: CaCode): RevokeGrantResponse =
  RevokeGrantResponse(
    kind: LogosNSCapabilityAuthorityRevokeGrantResponseKind.Map_error,
    arm_Map_error:
      LogosNSCapabilityAuthorityRevokeGrantResponseARMapErrorMap(error: errorValue(c)),
  )

func revokeGrantValue(g: Grant): RevokeGrantResponse =
  RevokeGrantResponse(
    kind: LogosNSCapabilityAuthorityRevokeGrantResponseKind.Map_grant,
    arm_Map_grant: LogosNSCapabilityAuthorityRevokeGrantResponseARMapGrantMap(grant: g),
  )

func getError(c: CaCode): GetGrantResponse =
  GetGrantResponse(
    kind: LogosNSCapabilityAuthorityGetGrantResponseKind.Map_error,
    arm_Map_error:
      LogosNSCapabilityAuthorityGetGrantResponseARMapErrorMap(error: errorValue(c)),
  )

func getGrantValue(g: Grant): GetGrantResponse =
  GetGrantResponse(
    kind: LogosNSCapabilityAuthorityGetGrantResponseKind.Map_grant,
    arm_Map_grant: LogosNSCapabilityAuthorityGetGrantResponseARMapGrantMap(grant: g),
  )

func listError(c: CaCode): ListGrantsResponse =
  ListGrantsResponse(
    kind: LogosNSCapabilityAuthorityListGrantsResponseKind.Map_error,
    arm_Map_error:
      LogosNSCapabilityAuthorityListGrantsResponseARMapErrorMap(error: errorValue(c)),
  )

func queryError(c: CaCode): QueryAuditResponse =
  QueryAuditResponse(
    kind: LogosNSCapabilityAuthorityQueryAuditResponseKind.Map_error,
    arm_Map_error:
      LogosNSCapabilityAuthorityQueryAuditResponseARMapErrorMap(error: errorValue(c)),
  )

func auditOf(x: LogosNSCapabilityAuthorityAuditRecordAREvaluateAllowMap): AuditRecord =
  AuditRecord(kind: AuditKind.Evaluate_allow, arm_Evaluate_allow: x)

func auditOf(x: LogosNSCapabilityAuthorityAuditRecordAREvaluateDenyMap): AuditRecord =
  AuditRecord(kind: AuditKind.Evaluate_deny, arm_Evaluate_deny: x)

func auditOf(
    x: LogosNSCapabilityAuthorityAuditRecordAREvaluateFailureMap
): AuditRecord =
  AuditRecord(kind: AuditKind.Evaluate_failure, arm_Evaluate_failure: x)

func auditOf(
    x: LogosNSCapabilityAuthorityAuditRecordARIssueGrantSuccessMap
): AuditRecord =
  AuditRecord(kind: AuditKind.Issue_grant_success, arm_Issue_grant_success: x)

func auditOf(x: LogosNSCapabilityAuthorityAuditRecordARIssueGrantDenyMap): AuditRecord =
  AuditRecord(kind: AuditKind.Issue_grant_deny, arm_Issue_grant_deny: x)

func auditOf(
    x: LogosNSCapabilityAuthorityAuditRecordARIssueGrantFailureMap
): AuditRecord =
  AuditRecord(kind: AuditKind.Issue_grant_failure, arm_Issue_grant_failure: x)

func auditOf(
    x: LogosNSCapabilityAuthorityAuditRecordARRevokeGrantSuccessMap
): AuditRecord =
  AuditRecord(kind: AuditKind.Revoke_grant_success, arm_Revoke_grant_success: x)

func auditOf(
    x: LogosNSCapabilityAuthorityAuditRecordARRevokeGrantFailureMap
): AuditRecord =
  AuditRecord(kind: AuditKind.Revoke_grant_failure, arm_Revoke_grant_failure: x)

func auditOf(
    x: LogosNSCapabilityAuthorityAuditRecordARGrantExpiredSuccessMap
): AuditRecord =
  AuditRecord(kind: AuditKind.Grant_expired_success, arm_Grant_expired_success: x)

func auditOf(
    x: LogosNSCapabilityAuthorityAuditRecordARPolicyChangeSuccessMap
): AuditRecord =
  AuditRecord(kind: AuditKind.Policy_change_success, arm_Policy_change_success: x)

func union(a, b: Opt[CommitmentRequirements]): Opt[CommitmentRequirements] =
  ## [SPEC CA l.488-490] An allow decision keeps every retention requirement
  ## of the request and its support.
  var r = CommitmentRequirements()
  for c in [a, b]:
    if c.isSome:
      if c.get.request.isSome:
        r.request = c.get.request
      if c.get.response.isSome:
        r.response = c.get.response
  if r.request.isNone and r.response.isNone:
    Opt.none(CommitmentRequirements)
  else:
    Opt.some(r)

# State files ------------------------------------------------------------------------

func toAs(f: FactsSnapshot): LcnAsFacts =
  LcnAsFacts(
    instance: f.instance,
    module: (if f.module.len > 0: Opt.some(f.module)
    else: Opt.none(string)),
    signer: f.signer,
    package: f.package,
  )

func fromAs(f: LcnAsFacts): FactsSnapshot =
  FactsSnapshot(
    instance: f.instance, module: f.module.get(""), signer: f.signer, package: f.package
  )

func toAs(r: StoredRecord): LcnAsRecord =
  var subject = Opt.none(LcnAsFacts)
  if r.subject.isSome:
    subject = Opt.some(toAs(r.subject.get))
  LcnAsRecord(seq: r.seq, record: r.bytes, subject: subject)

proc fromAs(r: LcnAsRecord): Result[StoredRecord, string] =
  let rec = ?decode(AuditRecord, r.record)
  var subject = Opt.none(FactsSnapshot)
  if r.subject.isSome:
    subject = Opt.some(fromAs(r.subject.get))
  ok(StoredRecord(seq: r.seq, record: rec, bytes: r.record, subject: subject))

proc toAs(rs: openArray[StoredRecord]): seq[LcnAsRecord] =
  for r in rs:
    result.add toAs(r)

# The CA thread's state --------------------------------------------------------------

type WatchEntry = object
  w: Watch
  consumer: Address

type Ca = object
  sh: ptr AuthorityShared
  cfg: AuthorityConfig
  view: FactsView
  policy: Policy
  revision: uint64
  changedAt: uint64
  ids: IdAllocator
  cursorKey: CursorKey
  store: Store
  grants: GrantTable
  log: AuditLog
  policyRecords: seq[StoredRecord]
  auditFloor: uint64
  nextSeq: uint64
  sinkLost: bool
  degraded: bool
  pendingGrants: OrderedSet[string] ## grant documents to rewrite
  pendingRemovals: OrderedSet[string] ## grant documents to remove
  metaPending: bool
  flushDue: Opt[int64] ## monotonic ns
  watches: seq[WatchEntry]

proc now(ca: Ca): uint64 =
  let ms = ca.cfg.clock.wallMs
  if ms < 0:
    0'u64
  else:
    uint64(ms)

func runtimeId(ca: Ca): string =
  ca.cfg.runtimeId

proc limits(ca: Ca): lent AuthorityLimits =
  ca.cfg.limits

proc metaDoc(ca: Ca): LcnAsMeta =
  LcnAsMeta(
    runtime_instance_id: ca.runtimeId,
    contract: caContract().schema_root,
    policy: LcnAsPolicy(
      digest: ca.policy.digest, revision: ca.revision, changed_at: ca.changedAt
    ),
    audit_floor: ca.auditFloor,
    policy_records: toAs(ca.policyRecords),
  )

proc grantDoc(e: GrantEntry): Result[LcnAsGrant, string] =
  let grant = ?encode(e.grant)
  ok(LcnAsGrant(grant: grant, target: toAs(e.targetFacts), records: toAs(e.records)))

proc writeGrantDoc(ca: var Ca, e: GrantEntry): Result[void, string] =
  ca.store.writeGrant(e.grant.grant_id, ?grantDoc(e))

proc newRecord(
    ca: var Ca, r: AuditRecord, subject: Opt[FactsSnapshot]
): Result[StoredRecord, string] =
  let bytes = ?encodeRecord(r)
  result = ok(StoredRecord(seq: ca.nextSeq, record: r, bytes: bytes, subject: subject))
  inc ca.nextSeq

proc unwritten(ca: Ca): int =
  ## Segment records not yet durable: always a suffix of the segments.
  for i in countdown(ca.log.segments.len - 1, 0):
    let s = ca.log.segments[i]
    if s.written == s.records.len:
      break
    result += s.records.len - s.written

proc flush(ca: var Ca): bool =
  ## Writes every segment with unwritten records, and pending meta.
  var good = true
  for i in 0 ..< ca.log.segments.len:
    if ca.log.segments[i].written < ca.log.segments[i].records.len:
      let seg = LcnAsSegment(
        first: ca.log.segments[i].first, records: toAs(ca.log.segments[i].records)
      )
      if ca.store.writeSegment(seg).isOk:
        ca.log.segments[i].written = ca.log.segments[i].records.len
      else:
        good = false
        break
  if good and ca.metaPending:
    if ca.store.writeMeta(ca.metaDoc).isOk:
      ca.metaPending = false
    else:
      good = false
  if good or ca.unwritten == 0 and not ca.metaPending:
    ca.flushDue = Opt.none(int64)
  else:
    ca.flushDue = Opt.some(ca.cfg.clock.monoNs + ca.limits.flushMs * 1_000_000)
  good

proc enforceRetention(ca: var Ca) =
  ## [SPEC CA l.1169; §0.1 U6] At most `policy.audit.records` segment records,
  ## across all consumers; the oldest whole segment goes first.
  var dropped: seq[uint64]
  while ca.log.overBound(int(ca.policy.auditRecords)):
    let seg = ca.log.dropOldest()
    dropped.add seg.first
  if dropped.len > 0:
    ca.auditFloor = ca.log.segments.peekFirst.first
    if ca.store.writeMeta(ca.metaDoc).isErr:
      ca.metaPending = true
      if ca.flushDue.isNone:
        ca.flushDue = Opt.some(ca.cfg.clock.monoNs + ca.limits.flushMs * 1_000_000)
    for first in dropped:
      # A segment below the floor is skipped at load if its removal fails.
      discard ca.store.removeSegment(first)

proc recordBehind(ca: var Ca, r: AuditRecord, subject: Opt[FactsSnapshot]) =
  ## A record written behind, within `flushMs` (U6).
  let sr = ca.newRecord(r, subject).valueOr:
    return # [IMPL] cannot happen: every record built here matches its schema
  ca.log.add(sr, ca.limits.segmentRecords)
  if ca.flushDue.isNone:
    ca.flushDue = Opt.some(ca.cfg.clock.monoNs + ca.limits.flushMs * 1_000_000)
  ca.enforceRetention()

proc retryPending(ca: var Ca): bool =
  ## [§2.13] Retries every write a degraded CA owes; true when none is left.
  var done: seq[string]
  for id in ca.pendingRemovals:
    if ca.store.removeGrant(id).isOk:
      done.add id
  for id in done:
    ca.pendingRemovals.excl id
  done.setLen(0)
  for id in ca.pendingGrants:
    if id notin ca.grants:
      done.add id
    elif ca.writeGrantDoc(ca.grants.byId.getOrDefault(id)).isOk:
      done.add id
  for id in done:
    ca.pendingGrants.excl id
  if ca.metaPending and ca.store.writeMeta(ca.metaDoc).isOk:
    ca.metaPending = false
  ca.degraded = ca.pendingGrants.len > 0 or ca.pendingRemovals.len > 0
  not ca.degraded

proc writable(ca: var Ca): bool =
  ## Before a mutating operation: a degraded CA first retries what it owes.
  not ca.degraded or ca.retryPending()

# Events -----------------------------------------------------------------------------

proc serveWatchers(ca: var Ca, ev: AuthorityEvent) {.gcsafe.}

proc emit(ca: var Ca, ev: AuthorityEvent) =
  ## [§2.11] The engine path first, then the watchers.
  if ca.cfg.sink.notify == nil:
    ca.sinkLost = true
  elif not ca.cfg.sink.notify(ca.cfg.sink.env, ev):
    ca.sinkLost = true
  ca.serveWatchers(ev)

# Facts ------------------------------------------------------------------------------

proc refreshFacts(ca: var Ca) =
  ca.view.refresh(ca.cfg.facts)

proc lookupAddress(ca: Ca, a: Address): FactsLookup =
  if not ca.view.available:
    FactsLookup(kind: flUnavailable)
  elif a.runtime_instance_id != ca.runtimeId:
    FactsLookup(kind: flUnknown)
  else:
    ca.view.lookup(a.module_instance_id)

proc subjectOf(ca: var Ca, a: Address): Opt[FactsSnapshot] =
  ## [IMPL] The subject of a record made before, or without, the consumer's
  ## facts: the facts as they read now, else the instance id alone for a local
  ## address. An instance-only snapshot matches no subject that names modules,
  ## signers or packages, so an unread fact never widens visibility.
  ca.refreshFacts()
  let f = ca.lookupAddress(a)
  if f.kind == flFound:
    Opt.some(snapshot(f.instance, f.facts))
  elif a.runtime_instance_id == ca.runtimeId and a.module_instance_id.len in 1 .. 128:
    # (the bounds of `lcn.as_facts.instance`: a snapshot must always encode)
    Opt.some(FactsSnapshot(instance: a.module_instance_id))
  else:
    Opt.none(FactsSnapshot)

proc resolveScopes(ca: Ca, scopes: openArray[Scope]): Result[void, CaError] =
  ## [SPEC CA l.77, l.459] Every referenced instance and provider is
  ## Runtime-known, and a module execution's module, package and version are
  ## its instance's own: `invalid-request` otherwise.
  let bad = caError(CaCode.Invalid_request, "unresolved")
  for s in scopes:
    case s.kind
    of skProvider:
      if s.pa.providers.isSome:
        for p in s.pa.providers.get:
          if ca.view.backing(p.provider).kind != flFound:
            return err(bad)
    of skControl:
      if s.rc.instances.isSome:
        for i in s.rc.instances.get:
          if ca.view.lookup(i).kind != flFound:
            return err(bad)
      if s.rc.providers.isSome:
        for p in s.rc.providers.get:
          if ca.view.backing(p.provider).kind != flFound:
            return err(bad)
    of skExecution:
      if s.me.instance.isSome:
        let f = ca.view.lookup(s.me.instance.get)
        if f.kind != flFound or f.facts.module != s.me.module:
          return err(bad)
        if s.me.package.isSome and f.facts.package != s.me.package:
          return err(bad)
        if s.me.version.isSome and f.facts.version != s.me.version:
          return err(bad)
    else:
      discard
  ok()

# evaluate (§5) ----------------------------------------------------------------------

proc newDecisionId(ca: var Ca): Opt[string] =
  let id = ca.ids.nextId('d')
  if id.isNone or id.get in ca.log.decisionIds:
    return Opt.none(string)
  id

proc doEvaluate(
    ca: var Ca, caller: CallerInfo, req: EvaluateRequest
): EvaluateResponse =
  if caller.kind != ckSystem:
    # [SPEC CA l.1375; CAP-0248] Only Runtime's protected path evaluates. Not
    # audited: refused before evaluation (l.1170).
    return evaluateError(CaCode.Not_authorised)
  let now = ca.now
  var validated = false
  var subject = Opt.none(FactsSnapshot)

  template fail(failed: CaCode): untyped =
    var failScopes = Opt.none(seq[Scope])
    if validated and failed in {CaCode.Authority_unavailable, CaCode.Internal_error}:
      failScopes = Opt.some(req.scopes)
    ca.recordBehind(
      auditOf(
        LogosNSCapabilityAuthorityAuditRecordAREvaluateFailureMap(
          timestamp: now,
          consumer: req.consumer,
          error: errorCode(failed),
          scopes: failScopes,
        )
      ),
      (if subject.isSome: subject else: ca.subjectOf(req.consumer)),
    )
    return evaluateError(failed)

  let form =
    validateScopes(req.scopes, ca.runtimeId, ca.limits.maxScopes, evaluating = true)
  if form.isErr:
    fail(form.error.code)
  validated = true
  ca.refreshFacts()
  if not ca.view.available or ca.sinkLost or ca.unwritten > ca.limits.maxUnwritten:
    fail(CaCode.Authority_unavailable)
  let cf = ca.lookupAddress(req.consumer)
  if cf.kind == flUnavailable:
    fail(CaCode.Authority_unavailable)
  if cf.kind == flUnknown:
    fail(CaCode.Invalid_request)
  let consumerFacts = snapshot(cf.instance, cf.facts)
  subject = Opt.some(consumerFacts)
  if ca.resolveScopes(req.scopes).isErr:
    fail(CaCode.Invalid_request)
  var op = req.scopes[0]
  for s in req.scopes:
    if s.kind != skPermission:
      op = s
  if op.kind == skProvider and op.pa.actions[0].kind == PaActionKind.Publish_event:
    # [SPEC CA l.243; CAP-0288] The publisher is the consumer.
    let b = ca.view.backing(op.pa.providers.get[0].provider)
    if b.kind != flFound or b.instance != cf.instance:
      fail(CaCode.Invalid_request)
  let id = ca.newDecisionId().valueOr:
    fail(CaCode.Authority_unavailable)

  var d = Decision(
    decision_id: id,
    policy_revision: ca.revision,
    consumer: req.consumer,
    requested_scopes: req.scopes,
    issued_at: now,
  )

  template deny(denied: DenialKind): untyped =
    d.result = LogosNSCapabilityAuthorityDecisionResult(
      kind: LogosNSCapabilityAuthorityDecisionResultKind.Deny
    )
    d.denial = Opt.some(denialValue(denied))
    ca.recordBehind(
      auditOf(
        LogosNSCapabilityAuthorityAuditRecordAREvaluateDenyMap(
          timestamp: now,
          consumer: req.consumer,
          decision_id: id,
          scopes: req.scopes,
          denial: d.denial.get,
        )
      ),
      subject,
    )
    return evaluateDecision(d)

  template allow(
      allowGrant: Opt[string],
      allowUntil: uint64,
      allowCommitment: Opt[CommitmentRequirements],
  ): untyped =
    d.result = LogosNSCapabilityAuthorityDecisionResult(
      kind: LogosNSCapabilityAuthorityDecisionResultKind.Allow
    )
    d.allowed_scopes = Opt.some(req.scopes)
    d.valid_until = Opt.some(allowUntil)
    if allowGrant.isSome:
      d.grant_ids = Opt.some(@[allowGrant.get])
    d.commitment = allowCommitment
    ca.recordBehind(
      auditOf(
        LogosNSCapabilityAuthorityAuditRecordAREvaluateAllowMap(
          timestamp: now, consumer: req.consumer, decision_id: id, scopes: req.scopes
        )
      ),
      subject,
    )
    return evaluateDecision(d)

  if op.isRestrictedOperation:
    deny(DenialKind.Scope_denied)
  for r in ca.policy.rules:
    if r.kind == rkDeny and r.subject.matches(consumerFacts) and
        r.deny.containsAny(op, ca.view):
      deny(r.code)
  var byRule = false
  var commitment = req.commitment
  for r in ca.policy.rules:
    if r.kind == rkAllow and r.subject.matches(consumerFacts) and
        r.allow.containsAny(op, ca.view):
      byRule = true
      commitment = union(commitment, r.commitment)
  if byRule:
    allow(Opt.none(string), now + ca.policy.validityMs, commitment)
  # [SPEC CA l.1391-1392] A grant whose target is the consumer.
  var best = Opt.none(string)
  var revoked, expired = false
  for gid in ca.grants.ids:
    let e = ca.grants.byId.getOrDefault(gid)
    if e.grant.target != req.consumer:
      continue
    var covering = false
    for s in e.grant.scopes:
      if covers(s, op, ca.runtimeId):
        covering = true
        break
    if not covering:
      continue
    case e.grant.status(now)
    of GrantStatusKind.Revoked:
      revoked = true
    of GrantStatusKind.Expired:
      expired = true
    of GrantStatusKind.Active:
      if best.isNone:
        best = Opt.some(gid)
      else:
        let b = ca.grants.byId.getOrDefault(best.get).grant.expires_at
        let x = e.grant.expires_at
        # no expiry first, else the latest; ids ascend, so ties keep the lower
        if b.isSome and (x.isNone or x.get > b.get):
          best = Opt.some(gid)
  if best.isSome:
    let g = ca.grants.byId.getOrDefault(best.get).grant
    var until = now + ca.policy.validityMs
    if g.expires_at.isSome:
      until = min(until, g.expires_at.get)
    allow(best, until, union(commitment, g.commitment))
  if revoked:
    deny(DenialKind.Grant_revoked)
  if expired:
    deny(DenialKind.Grant_expired)
  deny(DenialKind.Not_granted)

# issue_grant (§6) -------------------------------------------------------------------

proc makeRoom(ca: var Ca): bool =
  ## [§2.9] At most `maxGrants`: the oldest terminal grant goes, document and
  ## all. False when every retained grant is active.
  let now = ca.now
  while ca.grants.len >= ca.limits.maxGrants:
    let victim = ca.grants.oldestTerminal(now).valueOr:
      return false
    if ca.store.removeGrant(victim).isErr:
      ca.pendingRemovals.incl victim
      ca.degraded = true
    ca.pendingGrants.excl victim
    ca.grants.remove(victim)
  true

proc commitIssue(
    ca: var Ca,
    issuer: LogosNSCapabilityAuthorityGrantIssuer,
    consumer: Opt[Address],
    target: Address,
    targetFacts: FactsSnapshot,
    scopes: seq[Scope],
    expiresAt: Opt[uint64],
    commitment: Opt[CommitmentRequirements],
    subject: Opt[FactsSnapshot],
): Result[Grant, CaCode] =
  ## Ids, capacity, the durable document, the expiry re-check, then the effect
  ## and the event.
  let now = ca.now
  let gid = ca.ids.nextId('g').valueOr:
    return err(CaCode.Authority_unavailable)
  if gid in ca.grants:
    return err(CaCode.Authority_unavailable)
  if not ca.makeRoom():
    return err(CaCode.Authority_unavailable)
  let g = Grant(
    grant_id: gid,
    issuer: issuer,
    target: target,
    scopes: scopes,
    issued_at: now,
    expires_at: expiresAt,
    status: statusValue(GrantStatusKind.Active),
    commitment: commitment,
  )
  let rec = ca.newRecord(
    auditOf(
      LogosNSCapabilityAuthorityAuditRecordARIssueGrantSuccessMap(
        timestamp: now,
        consumer: consumer,
        target: target,
        grant_id: gid,
        scopes: scopes,
      )
    ),
    subject,
  ).valueOr:
    return err(CaCode.Internal_error)
  let e = GrantEntry(grant: g, targetFacts: targetFacts, records: @[rec])
  if ca.writeGrantDoc(e).isErr:
    ca.degraded = true
    return err(CaCode.Authority_unavailable)
  if expiresAt.isSome and ca.now >= expiresAt.get:
    # [SPEC CA l.722; §0.1 D7] It expired while it was written.
    if ca.store.removeGrant(gid).isErr:
      ca.pendingRemovals.incl gid
      ca.degraded = true
    return err(CaCode.Invalid_request)
  ca.grants.put(e)
  ca.emit(AuthorityEvent(kind: aeGrantChanged, grant: g))
  ok(g)

proc doIssue(
    ca: var Ca, caller: CallerInfo, req: IssueGrantRequest
): IssueGrantResponse =
  if caller.kind != ckModule or req.consumer != caller.address:
    return issueError(CaCode.Not_authorised)
  let now = ca.now
  var validated = false
  var subject = Opt.none(FactsSnapshot)

  template fail(failed: CaCode): untyped =
    var failScopes = Opt.none(seq[Scope])
    if validated and failed in {CaCode.Authority_unavailable, CaCode.Internal_error}:
      failScopes = Opt.some(req.scopes)
    ca.recordBehind(
      auditOf(
        LogosNSCapabilityAuthorityAuditRecordARIssueGrantFailureMap(
          timestamp: now,
          consumer: req.consumer,
          target: req.target,
          error: errorCode(failed),
          scopes: failScopes,
        )
      ),
      (if subject.isSome: subject else: ca.subjectOf(req.consumer)),
    )
    return issueError(failed)

  template deny(denied: DenialKind): untyped =
    ca.recordBehind(
      auditOf(
        LogosNSCapabilityAuthorityAuditRecordARIssueGrantDenyMap(
          timestamp: now,
          consumer: req.consumer,
          target: req.target,
          scopes: req.scopes,
          denial: denialValue(denied),
        )
      ),
      subject,
    )
    return issueDenial(denied)

  let form =
    validateScopes(req.scopes, ca.runtimeId, ca.limits.maxScopes, evaluating = false)
  if form.isErr and form.error.code == CaCode.Invalid_request:
    fail(CaCode.Invalid_request)
  if req.expires_at.isSome and req.expires_at.get <= now:
    fail(CaCode.Invalid_request) # [SPEC CA l.722]
  if form.isErr:
    fail(form.error.code)
  validated = true
  ca.refreshFacts()
  if not ca.view.available or ca.sinkLost or not ca.writable:
    fail(CaCode.Authority_unavailable)
  if ca.grants.len >= ca.limits.maxGrants and ca.grants.oldestTerminal(now).isNone:
    fail(CaCode.Authority_unavailable)
  let cf = ca.lookupAddress(req.consumer)
  if cf.kind != flFound:
    fail(
      if cf.kind == flUnavailable:
        CaCode.Authority_unavailable
      else:
        CaCode.Invalid_request
    )
  let callerFacts = snapshot(cf.instance, cf.facts)
  subject = Opt.some(callerFacts)
  # [§0.1 U3] The issuer check comes before any target is resolved.
  if not ca.policy.hasIssuer(callerFacts):
    deny(DenialKind.Consumer_denied)
  let tf = ca.lookupAddress(req.target)
  if tf.kind != flFound:
    fail(
      if tf.kind == flUnavailable:
        CaCode.Authority_unavailable
      else:
        CaCode.Invalid_request
    )
  let targetFacts = snapshot(tf.instance, tf.facts)
  if ca.resolveScopes(req.scopes).isErr:
    fail(CaCode.Invalid_request)
  for s in req.scopes:
    if s.namesRestricted:
      deny(DenialKind.Scope_denied)
  var targetMatched = false
  var granted = false
  for r in ca.policy.rules:
    if r.kind != rkIssue or not r.subject.matches(callerFacts):
      continue
    if not r.issueTargets.targetMatches(
      caller.address, req.target, targetFacts, Opt.none(Address)
    ):
      continue
    targetMatched = true
    var all = true
    for s in req.scopes:
      if not r.issue.containsAny(s, ca.view):
        all = false
        break
    if not all:
      continue
    if r.maxValidityMs.isSome and
        (req.expires_at.isNone or req.expires_at.get - now > r.maxValidityMs.get):
      continue
    granted = true
    break
  if not granted:
    deny(if targetMatched: DenialKind.Scope_denied else: DenialKind.Target_denied)
  let issuer = LogosNSCapabilityAuthorityGrantIssuer(
    kind: LogosNSCapabilityAuthorityGrantIssuerKind.Module,
    arm_Module: LogosNSCapabilityAuthorityGrantIssuerARModuleMap(module: caller.address),
  )
  let g = ca.commitIssue(
    issuer,
    Opt.some(req.consumer),
    req.target,
    targetFacts,
    req.scopes,
    req.expires_at,
    req.commitment,
    subject,
  ).valueOr:
    fail(error)
  issueGrantValue(g)

proc doIssueProtected(
    ca: var Ca,
    source: string,
    target: Address,
    scopes: seq[Scope],
    expiresAt: Opt[uint64],
    commitment: Opt[CommitmentRequirements],
): Result[Grant, CaError] =
  ## [SPEC CA l.696, l.1162] Issuance by the protected policy path: no
  ## consumer, no rule. Its failures name no consumer, so only its success is
  ## audited.
  let now = ca.now
  if not validSource(source):
    return err(caError(CaCode.Invalid_request, "source"))
  ?validateScopes(scopes, ca.runtimeId, ca.limits.maxScopes, evaluating = false)
  if expiresAt.isSome and expiresAt.get <= now:
    return err(caError(CaCode.Invalid_request, "expires_at"))
  ca.refreshFacts()
  if not ca.view.available or ca.sinkLost or not ca.writable:
    return err(caError(CaCode.Authority_unavailable))
  let tf = ca.lookupAddress(target)
  if tf.kind != flFound:
    return err(
      caError(
        if tf.kind == flUnavailable:
          CaCode.Authority_unavailable
        else:
          CaCode.Invalid_request
      )
    )
  ?ca.resolveScopes(scopes)
  for s in scopes:
    if s.namesRestricted:
      return err(caError(CaCode.Invalid_request, "restricted"))
  let targetFacts = snapshot(tf.instance, tf.facts)
  let issuer = LogosNSCapabilityAuthorityGrantIssuer(
    kind: LogosNSCapabilityAuthorityGrantIssuerKind.Protected_policy,
    arm_Protected_policy:
      LogosNSCapabilityAuthorityGrantIssuerARProtectedPolicyMap(source: source),
  )
  ca
    .commitIssue(
      issuer,
      Opt.none(Address),
      target,
      targetFacts,
      scopes,
      expiresAt,
      commitment,
      Opt.some(targetFacts),
    )
    .mapErr(
      proc(c: CaCode): CaError =
        caError(c)
    )

# revoke_grant (§6) ------------------------------------------------------------------

proc revokeEntry(
    ca: var Ca,
    gid: string,
    consumer: Opt[Address],
    reason: Opt[string],
    subject: Opt[FactsSnapshot],
): Result[Grant, CaCode] =
  ## The state step of a visible, revocable grant.
  let now = ca.now
  var e = ca.grants.byId.getOrDefault(gid)
  case e.grant.status(now)
  of GrantStatusKind.Expired:
    return err(CaCode.Grant_not_active) # [SPEC CA l.745]
  of GrantStatusKind.Revoked:
    # Idempotent: the current record, and a second success record (G206
    # interim, "TL-04, extended"), written behind with the other records.
    ca.recordBehind(
      auditOf(
        LogosNSCapabilityAuthorityAuditRecordARRevokeGrantSuccessMap(
          timestamp: now, consumer: consumer, target: e.grant.target, grant_id: gid
        )
      ),
      subject,
    )
    return ok(e.grant.current(now))
  of GrantStatusKind.Active:
    if not ca.writable:
      return err(CaCode.Authority_unavailable)
    var next = e
    next.grant.status = statusValue(GrantStatusKind.Revoked)
    next.grant.revoked_at = Opt.some(now)
    next.grant.revocation_reason = reason
    let rec = ca.newRecord(
      auditOf(
        LogosNSCapabilityAuthorityAuditRecordARRevokeGrantSuccessMap(
          timestamp: now, consumer: consumer, target: e.grant.target, grant_id: gid
        )
      ),
      subject,
    ).valueOr:
      return err(CaCode.Internal_error)
    next.records.add rec
    if ca.writeGrantDoc(next).isErr:
      ca.degraded = true
      return err(CaCode.Authority_unavailable)
    ca.grants.put(next)
    ca.emit(AuthorityEvent(kind: aeGrantChanged, grant: next.grant))
    ok(next.grant)

proc doRevoke(
    ca: var Ca, caller: CallerInfo, req: RevokeGrantRequest
): RevokeGrantResponse =
  if caller.kind != ckModule or req.consumer != caller.address:
    return revokeError(CaCode.Not_authorised)
  let now = ca.now
  var subject = Opt.none(FactsSnapshot)
  var failTarget = Opt.none(Address)

  template fail(failed: CaCode): untyped =
    ca.recordBehind(
      auditOf(
        LogosNSCapabilityAuthorityAuditRecordARRevokeGrantFailureMap(
          timestamp: now,
          consumer: req.consumer,
          target: failTarget,
          grant_id: req.grant_id,
          error: errorCode(failed),
        )
      ),
      (if subject.isSome: subject else: ca.subjectOf(req.consumer)),
    )
    return revokeError(failed)

  ca.refreshFacts()
  if not ca.view.available:
    fail(CaCode.Authority_unavailable)
  let cf = ca.lookupAddress(req.consumer)
  if cf.kind != flFound:
    # A retired caller cannot act; nothing to record about it.
    return revokeError(
      if cf.kind == flUnavailable:
        CaCode.Authority_unavailable
      else:
        CaCode.Not_authorised
    )
  let callerFacts = snapshot(cf.instance, cf.facts)
  subject = Opt.some(callerFacts)
  if req.grant_id notin ca.grants:
    fail(CaCode.Grant_not_found)
  let e = ca.grants.byId.getOrDefault(req.grant_id)
  let issuer = e.grant.issuerModule
  if not ca.policy.canSeeGrant(
    caller.address, callerFacts, e.grant.target, e.targetFacts, issuer
  ):
    fail(CaCode.Grant_not_found) # [SPEC CA l.1390] hidden reads as unknown
  failTarget = Opt.some(e.grant.target)
  if not ca.policy.canRevoke(
    caller.address, callerFacts, e.grant.target, e.targetFacts, issuer
  ):
    fail(CaCode.Not_authorised)
  let g = ca.revokeEntry(req.grant_id, Opt.some(req.consumer), req.reason, subject).valueOr:
    fail(error)
  revokeGrantValue(g)

proc doRevokeProtected(
    ca: var Ca, source, gid: string, reason: Opt[string]
): Result[Grant, CaError] =
  if not validSource(source):
    return err(caError(CaCode.Invalid_request, "source"))
  if gid notin ca.grants:
    return err(caError(CaCode.Grant_not_found))
  let e = ca.grants.byId.getOrDefault(gid)
  ca.revokeEntry(gid, Opt.none(Address), reason, Opt.some(e.targetFacts)).mapErr(
    proc(c: CaCode): CaError =
      caError(c)
  )

# get_grant, list_grants (§6, G51) ---------------------------------------------------

proc readerFacts(
    ca: var Ca, caller: CallerInfo, consumer: Address
): Result[FactsSnapshot, CaCode] =
  ## The caller checks and availability of the read methods.
  if caller.kind != ckModule or consumer != caller.address:
    return err(CaCode.Not_authorised)
  ca.refreshFacts()
  let cf = ca.lookupAddress(consumer)
  case cf.kind
  of flUnavailable:
    err(CaCode.Authority_unavailable)
  of flUnknown:
    err(CaCode.Not_authorised)
  of flFound:
    ok(snapshot(cf.instance, cf.facts))

proc visible(ca: Ca, caller: Address, callerFacts: FactsSnapshot, e: GrantEntry): bool =
  ca.policy.canSeeGrant(
    caller, callerFacts, e.grant.target, e.targetFacts, e.grant.issuerModule
  )

# Watches ----------------------------------------------------------------------------

proc offer(w: Watch, payload: seq[byte]) =
  ## [CAP-0382] Never blocks the CA thread: a change that does not fit marks
  ## the watch overflowed, and its body ends it (CAP-0383).
  if not w.overflow.load(moAcquire):
    var sent = false
    try:
      sent = w.ch.trySend(payload)
    except Exception:
      sent = false
    if not sent:
      w.overflow.store(true, moRelease)
  w.bell.ring()

proc serveWatchers(ca: var Ca, ev: AuthorityEvent) {.gcsafe.} =
  ## [SPEC CA §8.1; CAP-0372 to CAP-0374, CAP-0377 to CAP-0379] Each change, on
  ## the CA thread inside its transition, to every watch whose consumer may see
  ## it under the current policy and facts. One payload, encoded once, goes to
  ## all of them: equivalent watches get identical bytes and no watch id
  ## (CAP-0370, CAP-0371). A consumer the facts no longer know gets nothing.
  if ca.watches.len == 0:
    return
  ca.refreshFacts()
  case ev.kind
  of aeGrantChanged:
    if ev.grant.grant_id notin ca.grants:
      return
    let e = ca.grants.byId.getOrDefault(ev.grant.grant_id)
    let payload = encode(
      LogosNSCapabilityAuthorityObservedChangeEvent(
        kind: LogosNSCapabilityAuthorityObservedChangeEventKind.Map_grant,
        arm_Map_grant:
          LogosNSCapabilityAuthorityObservedChangeEventARMapGrantMap(grant: ev.grant),
      )
    ).valueOr:
      return
    for x in ca.watches:
      let f = ca.lookupAddress(x.consumer)
      if f.kind == flFound and ca.visible(x.consumer, snapshot(f.instance, f.facts), e):
        x.w.offer(payload)
  of aePolicyChanged:
    # [CAP-0379; l.841] Only to `policy_changes` inspectors, and never with
    # `affected_executions`.
    let payload = encode(
      LogosNSCapabilityAuthorityObservedChangeEvent(
        kind:
          LogosNSCapabilityAuthorityObservedChangeEventKind.Map_changed_at_policy_revision_previous_policy_revision,
        arm_Map_changed_at_policy_revision_previous_policy_revision: LogosNSCapabilityAuthorityObservedChangeEventARMapChangedAtPolicyRevisionPreviousPolicyRevisionMap(
          changed_at: ev.policy.changed_at,
          previous_policy_revision: ev.policy.previous_policy_revision,
          policy_revision: ev.policy.policy_revision,
        ),
      )
    ).valueOr:
      return
    for x in ca.watches:
      let f = ca.lookupAddress(x.consumer)
      if f.kind == flFound and
          ca.policy.inspectsPolicyChanges(snapshot(f.instance, f.facts)):
        x.w.offer(payload)

proc doWatch(ca: var Ca, caller: CallerInfo, consumer: Address): Result[Watch, CaCode] =
  ## [SPEC CA §8.1] A module caller watching as itself (CAP-0364), within
  ## 64 watches and 8 per consumer [IMPL] (CAP-0380, CAP-0383). Not audited:
  ## a watch changes nothing.
  discard ?ca.readerFacts(caller, consumer)
  var mine = 0
  for x in ca.watches:
    if x.consumer == consumer:
      inc mine
  if ca.watches.len >= ca.limits.maxWatches or mine >= ca.limits.watchesPerConsumer:
    return err(CaCode.Authority_unavailable)
  let w = createShared(WatchShared)
  w.ch.open(ca.limits.watchQueue)
  w.bell = newBell()
  ca.watches.add WatchEntry(w: w, consumer: consumer)
  ca.sh.watching.store(ca.watches.len, moRelease)
  ok(w)

proc doUnwatch(ca: var Ca, w: Watch) =
  for i in 0 ..< ca.watches.len:
    if ca.watches[i].w == w:
      ca.watches.delete(i)
      break
  ca.sh.watching.store(ca.watches.len, moRelease)

proc endWatches(ca: var Ca) =
  ## At close: every watch body returns `{}`. The CA thread lets go of each
  ## watch when it sets `ended`, after its last ring.
  for x in ca.watches:
    x.w.bell.ring()
    x.w.ended.store(true, moRelease)
  ca.watches.setLen(0)
  ca.sh.watching.store(0, moRelease)

proc doGet(ca: var Ca, caller: CallerInfo, req: GetGrantRequest): GetGrantResponse =
  let cf = ca.readerFacts(caller, req.consumer).valueOr:
    return getError(error)
  if req.grant_id notin ca.grants:
    return getError(CaCode.Grant_not_found)
  let e = ca.grants.byId.getOrDefault(req.grant_id)
  if not ca.visible(caller.address, cf, e):
    return getError(CaCode.Grant_not_found)
  getGrantValue(e.grant.current(ca.now))

proc doList(
    ca: var Ca, caller: CallerInfo, req: ListGrantsRequest
): ListGrantsResponse =
  if caller.kind != ckModule or req.consumer != caller.address:
    return listError(CaCode.Not_authorised)
  let now = ca.now
  let limit = int(req.limit.get(uint16(ca.limits.listDefault)))
  if limit < 1 or limit > ca.limits.listMax:
    return listError(CaCode.Invalid_request)
  var status = Opt.none(GrantStatusKind)
  if req.status.isSome:
    status = Opt.some(req.status.get.kind)
  let q = CursorQuery(
    consumer: req.consumer, target: req.target, status: status, limit: uint64(limit)
  )
  var start = 0
  if req.cursor.isSome:
    let c = readCursor(ca.cursorKey, q, req.cursor.get, now, ca.limits.cursorLifetimeMs).valueOr:
      return listError(CaCode.Invalid_request)
    start = ca.grants.firstAfter(c.lastId)
  let cf = ca.readerFacts(caller, req.consumer).valueOr:
    return listError(error)
  var listed: seq[Grant]
  var budget = 0
  var more = false
  for i in start ..< ca.grants.ids.len:
    let e = ca.grants.byId.getOrDefault(ca.grants.ids[i])
    if req.target.isSome and e.grant.target != req.target.get:
      continue
    if status.isSome and e.grant.status(now) != status.get:
      continue
    if not ca.visible(caller.address, cf, e):
      continue
    let g = e.grant.current(now)
    let size = encode(g).get(@[]).len
    if listed.len >= limit or
        (listed.len > 0 and budget + size > ca.limits.responseBudget):
      more = true
      break
    listed.add g
    budget += size
  var r = LogosNSCapabilityAuthorityListGrantsResponseARMapGrantsMap(grants: listed)
  if more:
    r.next_cursor = Opt.some(
      makeCursor(
        ca.cursorKey, q, CursorState(lastId: listed[^1].grant_id, issuedMs: now)
      )
    )
  ListGrantsResponse(
    kind: LogosNSCapabilityAuthorityListGrantsResponseKind.Map_grants, arm_Map_grants: r
  )

# query_audit (§9, G51, G52) ---------------------------------------------------------

proc doQuery(
    ca: var Ca, caller: CallerInfo, req: QueryAuditRequest
): QueryAuditResponse =
  if caller.kind != ckModule or req.consumer != caller.address:
    return queryError(CaCode.Not_authorised)
  if req.since.isSome and req.until.isSome and req.since.get > req.until.get:
    return queryError(CaCode.Invalid_request) # [SPEC CA l.1132]
  let cf = ca.readerFacts(caller, req.consumer).valueOr:
    return queryError(error)
  let q = AuditQuery(
    recordConsumer: req.record_consumer,
    target: req.target,
    decisionId: req.decision_id,
    grantId: req.grant_id,
    since: req.since,
    until: req.until,
  )
  var found: seq[StoredRecord]
  proc consider(ca: Ca, r: StoredRecord, found: var seq[StoredRecord]) =
    if not q.selects(r.record):
      return
    var issued = false
    let gid = r.record.grantId
    if gid.isSome and gid.get in ca.grants:
      let im = ca.grants.byId.getOrDefault(gid.get).grant.issuerModule
      issued = im.isSome and im.get == caller.address
    if ca.policy.canSeeRecord(
      caller.address,
      cf,
      r.subject,
      r.record.consumer,
      r.record.target,
      issued,
      r.record.kind == AuditKind.Policy_change_success,
    ):
      found.add r

  for s in ca.log.segments:
    for r in s.records:
      ca.consider(r, found)
  for _, e in ca.grants.byId:
    for r in e.records:
      ca.consider(r, found)
  for r in ca.policyRecords:
    ca.consider(r, found)
  found.newestFirst()
  var records: seq[AuditRecord]
  var budget = 0
  for r in found:
    if records.len >= ca.limits.queryMax or
        (records.len > 0 and budget + r.bytes.len > ca.limits.responseBudget):
      break
    records.add r.record
    budget += r.bytes.len
  QueryAuditResponse(
    kind: LogosNSCapabilityAuthorityQueryAuditResponseKind.Map_records,
    arm_Map_records:
      LogosNSCapabilityAuthorityQueryAuditResponseARMapRecordsMap(records: records),
  )

# Policy replacement (§2.5) ----------------------------------------------------------

proc addPolicyRecord(ca: var Ca, at: uint64): Result[void, string] =
  let r = ?ca.newRecord(
    auditOf(
      LogosNSCapabilityAuthorityAuditRecordARPolicyChangeSuccessMap(timestamp: at)
    ),
    Opt.none(FactsSnapshot),
  )
  ca.policyRecords.add r
  while ca.policyRecords.len > ca.limits.policyRecords:
    ca.policyRecords.delete(0)
  ok()

proc doReplacePolicy(ca: var Ca, bytes: seq[byte]): Result[uint64, string] =
  ## [SPEC CA l.829-848, l.884; §0.1 U4] A changed policy takes effect when
  ## this returns, after it is durable; an unchanged digest is a no-op.
  let p = ?loadPolicy(bytes)
  if p.digest == ca.policy.digest:
    return ok(ca.revision)
  let now = ca.now
  let saved = (ca.policy, ca.revision, ca.changedAt, ca.policyRecords, ca.nextSeq)
  let previous = ca.revision
  ca.policy = p
  ca.revision = previous + 1
  ca.changedAt = now
  ?ca.addPolicyRecord(now)
  if ca.store.writeMeta(ca.metaDoc).isErr:
    (ca.policy, ca.revision, ca.changedAt, ca.policyRecords, ca.nextSeq) = saved
    return err("authority-unavailable: the policy change could not be written")
  ca.metaPending = false
  ca.sh.revision.store(ca.revision, moRelease)
  ca.emit(
    AuthorityEvent(
      kind: aePolicyChanged,
      policy: PolicyChangedEvent(
        changed_at: now,
        previous_policy_revision: previous,
        policy_revision: ca.revision,
      ),
    )
  )
  ok(ca.revision)

# Timers -----------------------------------------------------------------------------

proc processTimers(ca: var Ca) =
  ## Expiry transitions (§0.1 D8: the event does not wait for the write), the
  ## audit flush, and the retries of a degraded CA.
  let now = ca.now
  while ca.grants.expiry.len > 0 and ca.grants.expiry[0][0] <= now:
    let (at, gid) = ca.grants.expiry.pop()
    if gid notin ca.grants:
      continue
    var e = ca.grants.byId.getOrDefault(gid)
    if e.grant.status.kind == GrantStatusKind.Revoked or e.expiryRecorded or
        e.grant.expires_at != Opt.some(at):
      continue
    if not e.expiryEmitted:
      e.expiryEmitted = true
      ca.grants.byId[gid] = e
      ca.emit(AuthorityEvent(kind: aeGrantChanged, grant: e.grant.current(now)))
    let rec = ca.newRecord(
      auditOf(
        LogosNSCapabilityAuthorityAuditRecordARGrantExpiredSuccessMap(
          timestamp: at, target: e.grant.target, grant_id: gid
        )
      ),
      Opt.some(e.targetFacts),
    )
    if rec.isOk:
      e.records.add rec.get
      e.expiryRecorded = true
    ca.grants.byId[gid] = e
    if ca.writeGrantDoc(e).isErr:
      ca.pendingGrants.incl gid
      ca.degraded = true
  if ca.flushDue.isSome and ca.cfg.clock.monoNs >= ca.flushDue.get:
    discard ca.flush()
  if ca.degraded:
    discard ca.retryPending()

proc nextWake(ca: Ca): Opt[MonoTime] =
  ## At most a second away; sooner for a due expiry or flush.
  var ms = 1_000'i64
  let ne = ca.grants.nextExpiry
  if ne.isSome:
    let now = int64(ca.now)
    ms = min(ms, max(int64(ne.get) - now, 1))
  if ca.flushDue.isSome:
    ms = min(ms, max((ca.flushDue.get - ca.cfg.clock.monoNs) div 1_000_000, 1))
  Opt.some(getMonoTime() + initDuration(milliseconds = ms))

# Opening ----------------------------------------------------------------------------

proc open(
    ca: var Ca, sh: ptr AuthorityShared, cfg: AuthorityConfig
): Result[void, string] =
  ca.sh = sh
  ca.cfg = cfg
  ca.policy = ?loadPolicy(cfg.policy)
  let entropy = if cfg.entropy == nil: systemEntropy else: cfg.entropy
  ca.ids = ?newIdAllocator(entropy)
  if not entropy(ca.cursorKey):
    return err("no protected entropy for the cursor key")
  ca.store = ?openStore(cfg.stateDir)
  let loaded = ca.store.load().valueOr:
    ca.store.close()
    return err(error)

  template refuse(msg: string): untyped =
    ca.store.close()
    return err(msg)

  let now = ca.now
  var maxSeq = 0'u64
  var any = false
  template seen(s: uint64) =
    if not any or s > maxSeq:
      maxSeq = s
    any = true

  if loaded.meta.isSome:
    let m = loaded.meta.get
    if m.runtime_instance_id != cfg.runtimeId:
      refuse("the authority state belongs to Runtime " & m.runtime_instance_id)
    if m.contract != caContract().schema_root:
      refuse(
        "the authority state was written for another Capability Authority contract"
      )
    ca.auditFloor = m.audit_floor
    for r in m.policy_records:
      let sr = fromAs(r).valueOr:
        refuse("meta.cbor: " & error)
      seen(sr.seq)
      ca.policyRecords.add sr
  var docs: seq[GrantEntry]
  for d in loaded.grants:
    let g = decode(Grant, d.grant).valueOr:
      refuse("a grant document: " & error)
    if g.grant_id in ca.grants:
      refuse("grant " & g.grant_id & " is stored twice")
    var e = GrantEntry(grant: g, targetFacts: fromAs(d.target))
    for r in d.records:
      let sr = fromAs(r).valueOr:
        refuse("grant " & g.grant_id & ": " & error)
      seen(sr.seq)
      if sr.record.kind == AuditKind.Grant_expired_success:
        e.expiryRecorded = true
        e.expiryEmitted = true
      e.records.add sr
    ca.grants.put(e)
  var segs = loaded.segments
  segs.sort(
    proc(a, b: LcnAsSegment): int =
      cmp(a.first, b.first)
  )
  for s in segs:
    if s.first < ca.auditFloor:
      continue
    for r in s.records:
      let sr = fromAs(r).valueOr:
        refuse("an audit segment: " & error)
      seen(sr.seq)
      ca.log.add(sr, ca.limits.segmentRecords)
    if ca.log.segments.len > 0:
      ca.log.segments.peekLast.written = ca.log.segments.peekLast.records.len
  ca.nextSeq =
    if any:
      maxSeq + 1
    else:
      0
  # The policy (§2.5): kept with an equal digest, else the next revision.
  if loaded.meta.isNone:
    ca.revision = 1
    ca.changedAt = now
  else:
    let m = loaded.meta.get
    if m.policy.digest == ca.policy.digest:
      ca.revision = m.policy.revision
      ca.changedAt = m.policy.changed_at
    else:
      ca.revision = m.policy.revision + 1
      ca.changedAt = now
      let r = ca.addPolicyRecord(now)
      if r.isErr:
        refuse(r.error)
  let w = ca.store.writeMeta(ca.metaDoc)
  if w.isErr:
    refuse(w.error)
  ca.enforceRetention()
  sh.revision.store(ca.revision, moRelease)
  ok()

# The loop ---------------------------------------------------------------------------

proc giveSlot(sh: ptr AuthorityShared, slot: ptr ReplySlot) =
  withLock sh.slotLock:
    slot.nextFree = sh.freeSlots
    sh.freeSlots = slot

proc answer(slot: ptr ReplySlot, r: sink Reply) =
  try:
    slot.ch.send(r)
  except Exception:
    discard # [IMPL] cannot happen for these value-only messages
  slot.bell.ring()

proc handle(ca: var Ca, q: sink Request) =
  var expected = 0
  if not q.slot.state.compareExchange(expected, 1, moAcquireRelease):
    # Withdrawn by its caller (D5): dropped unprocessed, no record.
    ca.sh.giveSlot(q.slot)
    return
  let r =
    case q.kind
    of rqEvaluate:
      Reply(kind: rqEvaluate, evaluated: ca.doEvaluate(q.caller, q.evaluate))
    of rqIssue:
      Reply(kind: rqIssue, issued: ca.doIssue(q.caller, q.issue))
    of rqRevoke:
      Reply(kind: rqRevoke, revoked: ca.doRevoke(q.caller, q.revoke))
    of rqGet:
      Reply(kind: rqGet, got: ca.doGet(q.caller, q.get))
    of rqList:
      Reply(kind: rqList, listed: ca.doList(q.caller, q.list))
    of rqQuery:
      Reply(kind: rqQuery, queried: ca.doQuery(q.caller, q.query))
    of rqIssueProtected:
      Reply(
        kind: rqIssueProtected,
        protected: ca.doIssueProtected(
          q.pSource, q.pTarget, q.pScopes, q.pExpires, q.pCommitment
        ),
      )
    of rqRevokeProtected:
      Reply(
        kind: rqRevokeProtected,
        protected: ca.doRevokeProtected(q.rSource, q.rGrant, q.rReason),
      )
    of rqReplacePolicy:
      Reply(kind: rqReplacePolicy, replaced: ca.doReplacePolicy(q.policyBytes))
    of rqTick:
      ca.processTimers()
      Reply(kind: rqTick)
    of rqFlush:
      discard ca.flush()
      Reply(kind: rqFlush)
    of rqInject:
      ca.store.failNext = q.failNext
      ca.store.failAll = q.failAll
      Reply(kind: rqInject)
    of rqWatch:
      Reply(kind: rqWatch, watched: ca.doWatch(q.caller, q.watchConsumer))
    of rqUnwatch:
      ca.doUnwatch(q.watch)
      Reply(kind: rqUnwatch)
  q.slot.answer(r)

proc tryTake(ch: var Channel[Request]): Opt[Request] =
  try:
    let (ok, q) = ch.tryRecv()
    if ok:
      return Opt.some(q)
  except Exception:
    discard
  Opt.none(Request)

proc run(ca: var Ca) =
  let sh = ca.sh
  while true:
    var worked = true
    while worked:
      worked = false
      while true:
        let q = sh.engineInbox.tryTake()
        if q.isNone:
          break
        ca.handle(q.get)
        worked = true
      let q = sh.moduleInbox.tryTake()
      if q.isSome:
        ca.handle(q.get)
        worked = true
    ca.processTimers()
    var closing: bool
    withLock sh.admitLock:
      closing = sh.closed
    if closing:
      # Nothing is admitted any more: answer what is queued, then stop.
      var left = true
      while left:
        left = false
        for ch in [addr sh.engineInbox, addr sh.moduleInbox]:
          let q = ch[].tryTake()
          if q.isSome:
            ca.handle(q.get)
            left = true
      break
    sh.bell.wait(ca.nextWake)

proc shutdown(ca: var Ca) =
  ca.endWatches()
  discard ca.flush()
  if ca.degraded:
    discard ca.retryPending()
  ca.store.close()

proc caMain(sh: ptr AuthorityShared) {.thread.} =
  var cfg: AuthorityConfig
  try:
    cfg = sh.start.recv()
  except Exception:
    return
  var ca: Ca
  let r = ca.open(sh, cfg)
  try:
    sh.started.send(if r.isOk: "" else: r.error)
  except Exception:
    discard
  if r.isOk:
    ca.run()
    ca.shutdown()

# The registry of open authorities ---------------------------------------------------

var registryLock: Lock
var registry: ptr AuthorityShared
initLock(registryLock)

proc authorityFor*(stateDir: string): Opt[Authority] =
  ## The authority open on `stateDir`, if any.
  withLock registryLock:
    var a = registry
    while a != nil:
      if $a.stateDir == stateDir:
        return Opt.some(a)
      a = a.nextOpen
  Opt.none(Authority)

proc register(a: Authority) =
  withLock registryLock:
    a.nextOpen = registry
    registry = a

proc unregister(a: Authority) =
  withLock registryLock:
    var p = addr registry
    while p[] != nil:
      if p[] == a:
        p[] = a.nextOpen
        break
      p = addr p[].nextOpen

# The public API ---------------------------------------------------------------------

proc drainClose[T](ch: var Channel[T]) =
  ## [IMPL] Closes `ch` once whatever is still queued in it is destroyed: under
  ## ORC `send` moves a value into the channel's buffer and `close` frees that
  ## buffer without destroying it.
  while true:
    try:
      let (ok, _) = ch.tryRecv()
      if not ok:
        break
    except Exception:
      break
  ch.close()

proc freeShared(a: Authority) =
  var slot = a.allSlots
  while slot != nil:
    let next = slot.nextAll
    slot.ch.drainClose()
    freeBell(slot.bell)
    deallocShared(slot)
    slot = next
  a.engineInbox.drainClose()
  a.moduleInbox.drainClose()
  a.start.drainClose()
  a.started.drainClose()
  freeBell(a.bell)
  deinitLock(a.admitLock)
  deinitLock(a.slotLock)
  deallocShared(a.stateDir)
  deallocShared(a)

proc openAuthority*(cfg: AuthorityConfig): Result[Authority, string] =
  ## Opens the state in `cfg.stateDir`, loads and verifies the policy and
  ## starts the CA thread. Fails, leaving the files unchanged, for state of
  ## another Runtime or contract, an undecodable file, a bad policy, a held
  ## lock, or no entropy.
  if authorityFor(cfg.stateDir).isSome:
    return err("the authority state is in use")
  let a = cast[Authority](allocShared0(sizeof(AuthorityShared)))
  a.engineInbox.open()
  a.moduleInbox.open(cfg.limits.moduleQueue)
  a.start.open()
  a.started.open()
  a.bell = newBell()
  initLock(a.admitLock)
  initLock(a.slotLock)
  a.moduleTimeoutMs = cfg.limits.moduleTimeoutMs
  a.stateDir = cast[cstring](allocShared0(cfg.stateDir.len + 1))
  if cfg.stateDir.len > 0:
    copyMem(a.stateDir, unsafeAddr cfg.stateDir[0], cfg.stateDir.len)
  var started: string
  try:
    a.start.send(cfg)
    createThread(a.thread, caMain, a)
    started = a.started.recv()
  except Exception as e:
    started = "cannot start the capability authority: " & e.msg
  if started.len > 0:
    try:
      joinThread(a.thread)
    except Exception:
      discard
    a.freeShared()
    return err(started)
  a.register()
  ok(a)

proc closeAuthority*(a: Authority) =
  ## Refuses new requests, answers the queued ones, flushes audit and stops
  ## the thread.
  withLock a.admitLock:
    a.closed = true
  a.bell.ring()
  try:
    joinThread(a.thread)
  except Exception:
    discard
  a.unregister()
  a.freeShared()

proc isClosed*(a: Authority): bool =
  withLock a.admitLock:
    result = a.closed

proc takeSlot(a: Authority): ptr ReplySlot =
  withLock a.slotLock:
    result = a.freeSlots
    if result != nil:
      a.freeSlots = result.nextFree
    else:
      result = createShared(ReplySlot)
      result.ch.open()
      result.bell = newBell()
      result.nextAll = a.allSlots
      a.allSlots = result

proc submit(
    a: Authority, q: sink Request, engine: bool, cancelled: CancelFn
): Opt[Reply] =
  ## Admits `q` and waits for its reply; none when it was not admitted or was
  ## withdrawn unclaimed (D5).
  let slot = a.takeSlot()
  slot.state.store(0, moRelease)
  q.slot = slot
  var admitted = false
  withLock a.admitLock:
    if not a.closed:
      try:
        if engine:
          a.engineInbox.send(q)
          admitted = true
        else:
          admitted = a.moduleInbox.trySend(q)
      except Exception:
        admitted = false
  if not admitted:
    a.giveSlot(slot)
    return Opt.none(Reply)
  a.bell.ring()
  let deadline =
    if engine:
      Opt.none(MonoTime)
    else:
      Opt.some(getMonoTime() + initDuration(milliseconds = a.moduleTimeoutMs))
  while true:
    try:
      let (ok, r) = slot.ch.tryRecv()
      if ok:
        a.giveSlot(slot)
        return Opt.some(r)
    except Exception:
      discard
    let late = deadline.isSome and getMonoTime() >= deadline.get
    if late or (cancelled != nil and cancelled()):
      var expected = 0
      if slot.state.compareExchange(expected, 2, moAcquireRelease):
        return Opt.none(Reply) # the CA thread gives the slot back
      try:
        let r = slot.ch.recv() # claimed: its reply always comes
        a.giveSlot(slot)
        return Opt.some(r)
      except Exception:
        return Opt.none(Reply)
    var wake = getMonoTime() + initDuration(milliseconds = 50)
    if deadline.isSome and deadline.get < wake:
      wake = deadline.get
    slot.bell.wait(Opt.some(wake))

func isEngine(caller: CallerInfo): bool =
  caller.kind == ckSystem

proc evaluate*(
    a: Authority, caller: CallerInfo, req: EvaluateRequest, cancelled: CancelFn = nil
): EvaluateResponse =
  let r = a.submit(
    Request(kind: rqEvaluate, caller: caller, evaluate: req), caller.isEngine, cancelled
  )
  if r.isNone:
    return evaluateError(CaCode.Authority_unavailable)
  r.get.evaluated

proc evaluateEngine*(a: Authority, req: EvaluateRequest): Result[Decision, CaError] =
  ## TEST-ONLY (C14): `evaluate` as Runtime's protected caller. Step 8b calls
  ## `evaluate` through the module's dispatch entry instead.
  let r = a.evaluate(CallerInfo(kind: ckSystem), req)
  case r.kind
  of LogosNSCapabilityAuthorityEvaluateResponseKind.Map_decision:
    ok(r.arm_Map_decision.decision)
  of LogosNSCapabilityAuthorityEvaluateResponseKind.Map_error:
    err(caError(r.arm_Map_error.error.code.kind))

proc issueGrant*(
    a: Authority, caller: CallerInfo, req: IssueGrantRequest, cancelled: CancelFn = nil
): IssueGrantResponse =
  let r = a.submit(
    Request(kind: rqIssue, caller: caller, issue: req), caller.isEngine, cancelled
  )
  if r.isNone:
    return issueError(CaCode.Authority_unavailable)
  r.get.issued

proc revokeGrant*(
    a: Authority, caller: CallerInfo, req: RevokeGrantRequest, cancelled: CancelFn = nil
): RevokeGrantResponse =
  let r = a.submit(
    Request(kind: rqRevoke, caller: caller, revoke: req), caller.isEngine, cancelled
  )
  if r.isNone:
    return revokeError(CaCode.Authority_unavailable)
  r.get.revoked

proc getGrant*(
    a: Authority, caller: CallerInfo, req: GetGrantRequest, cancelled: CancelFn = nil
): GetGrantResponse =
  let r =
    a.submit(Request(kind: rqGet, caller: caller, get: req), caller.isEngine, cancelled)
  if r.isNone:
    return getError(CaCode.Authority_unavailable)
  r.get.got

proc listGrants*(
    a: Authority, caller: CallerInfo, req: ListGrantsRequest, cancelled: CancelFn = nil
): ListGrantsResponse =
  let r = a.submit(
    Request(kind: rqList, caller: caller, list: req), caller.isEngine, cancelled
  )
  if r.isNone:
    return listError(CaCode.Authority_unavailable)
  r.get.listed

proc queryAudit*(
    a: Authority, caller: CallerInfo, req: QueryAuditRequest, cancelled: CancelFn = nil
): QueryAuditResponse =
  let r = a.submit(
    Request(kind: rqQuery, caller: caller, query: req), caller.isEngine, cancelled
  )
  if r.isNone:
    return queryError(CaCode.Authority_unavailable)
  r.get.queried

proc issueProtected*(
    a: Authority,
    source: string,
    target: Address,
    scopes: seq[Scope],
    expiresAt: Opt[uint64] = Opt.none(uint64),
    commitment: Opt[CommitmentRequirements] = Opt.none(CommitmentRequirements),
): Result[Grant, CaError] =
  ## [SPEC CA l.696] Issuance by the protected policy path (`source`), for
  ## the deployment's own grants: no consumer and no `issue` rule.
  let r = a.submit(
    Request(
      kind: rqIssueProtected,
      pSource: source,
      pTarget: target,
      pScopes: scopes,
      pExpires: expiresAt,
      pCommitment: commitment,
    ),
    true,
    nil,
  )
  if r.isNone:
    return err(caError(CaCode.Authority_unavailable))
  r.get.protected

proc revokeProtected*(
    a: Authority, source, grantId: string, reason = Opt.none(string)
): Result[Grant, CaError] =
  let r = a.submit(
    Request(kind: rqRevokeProtected, rSource: source, rGrant: grantId, rReason: reason),
    true,
    nil,
  )
  if r.isNone:
    return err(caError(CaCode.Authority_unavailable))
  r.get.protected

proc replacePolicy*(a: Authority, policy: openArray[byte]): Result[uint64, string] =
  ## Nim-only administration (§2.5): the new revision, effective when this
  ## returns. An unchanged digest changes nothing (§0.1 U4).
  let r = a.submit(Request(kind: rqReplacePolicy, policyBytes: @policy), true, nil)
  if r.isNone:
    return err("authority-unavailable")
  r.get.replaced

func watchEnded*(): WatchChangesResponse =
  ## `{}`: the watch ended by cancellation or close (CAP-0368).
  WatchChangesResponse(kind: LogosNSCapabilityAuthorityWatchChangesResponseKind.Map)

func watchError*(c: CaCode): WatchChangesResponse =
  WatchChangesResponse(
    kind: LogosNSCapabilityAuthorityWatchChangesResponseKind.Map_error,
    arm_Map_error:
      LogosNSCapabilityAuthorityWatchChangesResponseARMapErrorMap(error: errorValue(c)),
  )

proc watch*(
    a: Authority, caller: CallerInfo, consumer: Address
): Result[Watch, CaCode] =
  ## [SPEC CA §8.1] Registers a watch for `consumer`; the caller then takes
  ## its changes and must `unwatch` it.
  let r = a.submit(
    Request(kind: rqWatch, caller: caller, watchConsumer: consumer),
    caller.isEngine,
    nil,
  )
  if r.isNone:
    return err(CaCode.Authority_unavailable)
  r.get.watched

proc freeWatch(w: Watch) =
  w.ch.drainClose()
  freeBell(w.bell)
  deallocShared(w)

proc unwatch*(a: Authority, w: Watch) =
  ## Ends `w` and frees it, once the CA thread has let go: at once when the
  ## authority is open, else when its close reaches the watch. A watch the
  ## close already ended is freed without touching `a`, which may be gone; an
  ## `unwatch` never runs concurrently with `closeAuthority` (the provider's
  ## destroy follows every invocation).
  if not w.ended.load(moAcquire):
    let r = a.submit(Request(kind: rqUnwatch, watch: w), true, nil)
    if r.isNone:
      while not w.ended.load(moAcquire):
        w.bell.wait(Opt.some(getMonoTime() + initDuration(milliseconds = 50)))
  freeWatch(w)

proc watchCount*(a: Authority): int =
  ## Tests: the live watches.
  a.watching.load(moAcquire)

proc queuedRequests*(a: Authority): tuple[engine, module: int] =
  ## Tests: requests admitted and not yet taken by the CA thread.
  (a.engineInbox.peek(), a.moduleInbox.peek())

proc isEnded*(w: Watch): bool =
  w.ended.load(moAcquire)

proc overflowed*(w: Watch): bool =
  w.overflow.load(moAcquire)

proc nextChange*(w: Watch): Opt[seq[byte]] =
  ## The next admitted change's `observed_change` payload, if one is queued.
  try:
    let (ok, payload) = w.ch.tryRecv()
    if ok:
      return Opt.some(payload)
  except Exception:
    discard
  Opt.none(seq[byte])

proc waitChange*(w: Watch, deadline: MonoTime) =
  ## Until a change is offered, the watch ends, or `deadline`.
  w.bell.wait(Opt.some(deadline))

proc policyRevision*(a: Authority): uint64 =
  a.revision.load(moAcquire)

proc tick*(a: Authority) =
  ## Runs the timers now: for tests with a frozen clock.
  discard a.submit(Request(kind: rqTick), true, nil)

proc flushAudit*(a: Authority) =
  discard a.submit(Request(kind: rqFlush), true, nil)

proc injectWriteFailures*(a: Authority, next = 0, all = false) =
  ## Tests: the next `next` writes fail, or all of them while `all`.
  discard a.submit(Request(kind: rqInject, failNext: next, failAll: all), true, nil)
