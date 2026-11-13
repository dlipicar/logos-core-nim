## Step 8b-3 (DECISIONS I85): call commitments and `call` audit records at the
## Runtime-controlled invocation boundary (CA §4, §9 l.1172-1215).
##
## - Commitments, always. Every route call and Runtime Control call computes
##   its request commitment and, for a successful response, its response
##   commitment (RUN-0332), retained or not. `CallTrail` keeps them for the
##   call; the call scope in the same record binds them to the route,
##   provider, contract, method and exact type (RUN-0333).
## - Capture at admission. When the allow decision applied to a call requires
##   retention, the Runtime thread captures its decision id, the enforced call
##   scope and the retention as one snapshot (`CallCapture`; CAP-0389,
##   CAP-0390). A cached call decision is named as itself (CAP-0391); a route
##   decision never authorizes a call. Nothing later changes the capture
##   (CAP-0392). [IMPL] The enforced scope is the call's own request scope:
##   it already names one route, one provider, the selected contract and one
##   method (or, for Runtime Control, the Runtime, the contract, one method and
##   the selectors the operation determines, `events` absent: CAP-0209), so an
##   allowed scope that admits the call covers it whole and has no narrowing
##   left to add (CA l.1178).
## - The record after the outcome (`callRecord`). A side appears only when it
##   was required, produced and committed (CAP-0210, CAP-0214); `success` only
##   when the call succeeded and every required side was committed (CAP-0212),
##   otherwise `failure`, with `commitments` omitted when none was retained
##   (CAP-0211, CAP-0213). Each commitment is the boundary's own, computed
##   from the schema-typed value under the method's defining contract, never a
##   root a party supplied (RUN-0335); for `logos.schema` that is the common
##   schema (CA l.1203-1204).
## - Retention (`AuditLog`). A ring of encoded records in shared memory,
##   appended from any thread under one lock, the oldest dropped first.
##   Retention duration and storage are deployment policy (CA l.1169) and the
##   Runtime may retain call records directly (CA l.1330): [IMPL] the last
##   `call_audit.call_records` records (default 4096), in memory, lost at
##   exit. Records hold no ticket, key or secret (CAP-0244, CAP-0257,
##   CAP-0264): a capture holds ids, a scope and flags only.

{.push raises: [].}

import std/locks
import results
import ../cbor
import ../authority/scopes
from ../transport/envelope import PayloadCommitment

export PayloadCommitment

const
  DefaultCallRecords* = 4096 ## [IMPL] `call_audit.call_records` when absent
  MaxCallRecords* = 1_000_000 ## [IMPL] its upper bound

type
  CallCapture* = object
    ## [SPEC CA l.1176-1177] The snapshot taken at admission; empty (nothing
    ## retained) for a decision without `retain-root`. Plain values only.
    decisionId*: string
    scope*: seq[byte] ## the enforced call scope, deterministic CBOR
    retainRequest*, retainResponse*: bool
    runtimeId*: string
    consumer*: string ## the consumer instance

  CallTrail* = object
    ## [SPEC RUNTIME l.832-841; RUN-0332] What the boundary committed for one
    ## call: the request once it validated, the response once it validated.
    request*: Opt[PayloadCommitment]
    response*: Opt[PayloadCommitment]
    succeeded*: bool ## the call returned a success to its caller

  RetainedRecord* = object
    index*: uint64 ## [IMPL] counts every record appended, from 0
    bytes*: seq[byte] ## the `audit_record`, deterministic CBOR

func retains*(c: CallCapture): bool =
  ## Whether the applied decision requires a call record.
  c.retainRequest or c.retainResponse

# The record ---------------------------------------------------------------------------

func valueCommitment(
    c: PayloadCommitment
): LogosNSCapabilityAuthorityAuditValueCommitment =
  LogosNSCapabilityAuthorityAuditValueCommitment(
    schema_subtree_root: @(c.subtreeRoot), value_root: @(c.valueRoot)
  )

func retained(
    c: CallCapture, t: CallTrail
): Opt[LogosNSCapabilityAuthorityCallCommitments] =
  ## [SPEC CA l.1191-1198] The sides required and committed, or none.
  let request = c.retainRequest and t.request.isSome
  let response = c.retainResponse and t.response.isSome
  if request:
    Opt.some(
      LogosNSCapabilityAuthorityCallCommitments(
        kind: LogosNSCapabilityAuthorityCallCommitmentsKind.Map_request,
        arm_Map_request: LogosNSCapabilityAuthorityCallCommitmentsARMapRequestMap(
          request: valueCommitment(t.request.get),
          response:
            if response:
              Opt.some(valueCommitment(t.response.get))
            else:
              Opt.none(LogosNSCapabilityAuthorityAuditValueCommitment),
        ),
      )
    )
  elif response:
    Opt.some(
      LogosNSCapabilityAuthorityCallCommitments(
        kind: LogosNSCapabilityAuthorityCallCommitmentsKind.Map_response,
        arm_Map_response: LogosNSCapabilityAuthorityCallCommitmentsARMapResponseMap(
          response: valueCommitment(t.response.get)
        ),
      )
    )
  else:
    Opt.none(LogosNSCapabilityAuthorityCallCommitments)

proc callRecord*(
    c: CallCapture, t: CallTrail, timestamp: uint64
): Result[AuditRecord, string] =
  ## [SPEC CA l.1172-1198] The `call` record of one call whose capture
  ## retains something, after its outcome.
  if not c.retains:
    return err("the applied decision requires no call record")
  let scope = Scope.decode(c.scope).valueOr:
    return err("the captured scope does not decode: " & error)
  let commitments = retained(c, t)
  let complete =
    (not c.retainRequest or t.request.isSome) and
    (not c.retainResponse or t.response.isSome)
  let consumer =
    Address(runtime_instance_id: c.runtimeId, module_instance_id: c.consumer)
  if t.succeeded and complete and commitments.isSome:
    ok(
      AuditRecord(
        kind: AuditKind.Call_success,
        arm_Call_success: LogosNSCapabilityAuthorityAuditRecordARCallSuccessMap(
          commitments: commitments.get,
          consumer: consumer,
          decision_id: c.decisionId,
          scopes: (scope,),
          timestamp: timestamp,
        ),
      )
    )
  else:
    ok(
      AuditRecord(
        kind: AuditKind.Call_failure,
        arm_Call_failure: LogosNSCapabilityAuthorityAuditRecordARCallFailureMap(
          commitments: commitments,
          consumer: consumer,
          decision_id: c.decisionId,
          scopes: (scope,),
          timestamp: timestamp,
        ),
      )
    )

# A capture handed to another thread ----------------------------------------------------

type SharedCapture* = object
  ## [IMPL] A capture and the request commitment in shared memory, for a call
  ## whose outcome is decided on another thread (a deferred provider's
  ## completion). Plain memory only: no garbage-collected value crosses.
  data: ptr UncheckedArray[byte]
  len: int
  request: PayloadCommitment
  hasRequest: bool

proc share*(c: CallCapture, t: CallTrail): ptr SharedCapture =
  ## Nil when `c` retains nothing.
  if not c.retains:
    return nil
  let bytes = encodeCbor(
    cborArray(
      cbor(c.decisionId),
      cbor(c.scope),
      cbor(c.retainRequest),
      cbor(c.retainResponse),
      cbor(c.runtimeId),
      cbor(c.consumer),
    )
  )
  result = createShared(SharedCapture)
  result.data = cast[ptr UncheckedArray[byte]](allocShared0(bytes.len))
  for i, b in bytes:
    result.data[i] = b
  result.len = bytes.len
  if t.request.isSome:
    result.request = t.request.get
    result.hasRequest = true

proc unshare*(p: ptr SharedCapture): (CallCapture, CallTrail) =
  ## The capture and a trail with its request commitment; frees `p`.
  if p == nil:
    return
  var bytes = newSeq[byte](p.len)
  for i in 0 ..< p.len:
    bytes[i] = p.data[i]
  if p.hasRequest:
    result[1].request = Opt.some(p.request)
  deallocShared(p.data)
  freeShared(p)
  let v = decodeCbor(bytes).valueOr:
    return
  if v.kind != ckArray or v.items.len != 6:
    return
  result[0] = CallCapture(
    decisionId: v.items[0].getText.get(""),
    scope: v.items[1].getBytes.get(@[]),
    retainRequest: v.items[2].getBool.get(false),
    retainResponse: v.items[3].getBool.get(false),
    runtimeId: v.items[4].getText.get(""),
    consumer: v.items[5].getText.get(""),
  )

# Retention ----------------------------------------------------------------------------

type
  Slot = object
    index: uint64
    data: ptr UncheckedArray[byte]
    len: int

  AuditLogObj = object
    lock: Lock
    capacity: int
    slots: ptr UncheckedArray[Slot]
    first: int ## the oldest record's slot
    count: int
    next: uint64 ## the index the next record gets

  AuditLog* = ptr AuditLogObj
    ## Shared by every thread of one engine; created and freed with it.

proc newAuditLog*(capacity: int): AuditLog =
  ## A ring of `capacity` records (`DefaultCallRecords` when 0).
  let n = (if capacity <= 0: DefaultCallRecords
  else: min(capacity, MaxCallRecords))
  result = createShared(AuditLogObj)
  initLock(result.lock)
  result.capacity = n
  result.slots = cast[ptr UncheckedArray[Slot]](allocShared0(n * sizeof(Slot)))

proc freeAuditLog*(log: AuditLog) =
  if log == nil:
    return
  for i in 0 ..< log.capacity:
    if log.slots[i].data != nil:
      deallocShared(log.slots[i].data)
  deallocShared(log.slots)
  deinitLock(log.lock)
  freeShared(log)

proc append*(log: AuditLog, bytes: openArray[byte]): uint64 =
  ## Keeps `bytes` as the newest record, dropping the oldest when full; its
  ## index.
  let data = cast[ptr UncheckedArray[byte]](allocShared0(max(bytes.len, 1)))
  for i, b in bytes:
    data[i] = b
  var gone: ptr UncheckedArray[byte] = nil
  withLock log.lock:
    result = log.next
    inc log.next
    var at: int
    if log.count < log.capacity:
      at = (log.first + log.count) mod log.capacity
      inc log.count
    else:
      at = log.first
      gone = log.slots[at].data
      log.first = (log.first + 1) mod log.capacity
    log.slots[at] = Slot(index: result, data: data, len: bytes.len)
  if gone != nil:
    deallocShared(gone)

proc copyOut(s: Slot): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len:
    result[i] = s.data[i]

proc records*(log: AuditLog): seq[RetainedRecord] =
  ## The retained records, oldest first.
  if log == nil:
    return
  withLock log.lock:
    for k in 0 ..< log.count:
      let s = log.slots[(log.first + k) mod log.capacity]
      result.add(RetainedRecord(index: s.index, bytes: copyOut(s)))

proc recordAt*(log: AuditLog, index: uint64): Opt[seq[byte]] =
  ## The record appended as `index`, while it is retained.
  if log == nil:
    return Opt.none(seq[byte])
  withLock log.lock:
    if log.count == 0:
      return Opt.none(seq[byte])
    let oldest = log.slots[log.first].index
    if index < oldest or index >= log.next:
      return Opt.none(seq[byte])
    let s = log.slots[(log.first + int(index - oldest)) mod log.capacity]
    return Opt.some(copyOut(s))

proc keep*(
    log: AuditLog, c: CallCapture, t: CallTrail, timestamp: uint64
): Result[uint64, string] =
  ## [SPEC CA l.1172-1174] The call's record after its outcome, retained;
  ## nothing when its capture retains nothing.
  if log == nil or not c.retains:
    return err("nothing to retain")
  let r = ?callRecord(c, t, timestamp)
  let bytes = ?encode(r)
  ok(log.append(bytes))
