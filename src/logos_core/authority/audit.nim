## Capability Authority audit records: fields, retention, queries [IMPL]
## (CA §9; decisions G51, G52; DECISIONS I84).
##
## Every record gets a sequence number, strictly increasing at recording.
## Queries order by `(timestamp desc, seq desc)`: reverse recording order for
## equal timestamps (CAP-0386).
##
## Where a record lives:
## - an issue, revoke or expiry success: in its grant's document, retained
##   with the grant (`grants.nim`);
## - a policy change: in the state's meta file, the newest `policyRecords`;
## - every other record: in segments of `segmentRecords`, written behind.
##   `policy.audit.records` bounds them all together, across all consumers
##   (§0.1 U6); the oldest whole segment goes first.

{.push raises: [].}

import std/[algorithm, deques, sets]
import results
import ./[policy, scopes]

export results

type
  StoredRecord* = object
    seq*: uint64
    record*: AuditRecord
    bytes*: seq[byte] ## its deterministic-CBOR encoding
    subject*: Opt[FactsSnapshot]
      ## the facts of its consumer, else of its target, when recorded:
      ## local detail (CA l.1349), for visibility

  Segment* = object
    first*: uint64
    records*: seq[StoredRecord]
    written*: int ## how many of `records` the file on disk holds

  AuditLog* = object
    segments*: Deque[Segment]
    count*: int ## records in `segments`
    decisionIds*: HashSet[string] ## of the retained evaluation records

proc encodeRecord*(r: AuditRecord): Result[seq[byte], string] =
  encode(r)

func timestamp*(r: AuditRecord): uint64 =
  case r.kind
  of AuditKind.Call_failure: r.arm_Call_failure.timestamp
  of AuditKind.Call_success: r.arm_Call_success.timestamp
  of AuditKind.Evaluate_allow: r.arm_Evaluate_allow.timestamp
  of AuditKind.Evaluate_deny: r.arm_Evaluate_deny.timestamp
  of AuditKind.Evaluate_failure: r.arm_Evaluate_failure.timestamp
  of AuditKind.Grant_expired_success: r.arm_Grant_expired_success.timestamp
  of AuditKind.Issue_grant_deny: r.arm_Issue_grant_deny.timestamp
  of AuditKind.Issue_grant_failure: r.arm_Issue_grant_failure.timestamp
  of AuditKind.Issue_grant_success: r.arm_Issue_grant_success.timestamp
  of AuditKind.Policy_change_success: r.arm_Policy_change_success.timestamp
  of AuditKind.Revoke_grant_failure: r.arm_Revoke_grant_failure.timestamp
  of AuditKind.Revoke_grant_success: r.arm_Revoke_grant_success.timestamp

func consumer*(r: AuditRecord): Opt[Address] =
  case r.kind
  of AuditKind.Call_failure:
    Opt.some(r.arm_Call_failure.consumer)
  of AuditKind.Call_success:
    Opt.some(r.arm_Call_success.consumer)
  of AuditKind.Evaluate_allow:
    Opt.some(r.arm_Evaluate_allow.consumer)
  of AuditKind.Evaluate_deny:
    Opt.some(r.arm_Evaluate_deny.consumer)
  of AuditKind.Evaluate_failure:
    Opt.some(r.arm_Evaluate_failure.consumer)
  of AuditKind.Grant_expired_success:
    Opt.none(Address)
  of AuditKind.Issue_grant_deny:
    Opt.some(r.arm_Issue_grant_deny.consumer)
  of AuditKind.Issue_grant_failure:
    Opt.some(r.arm_Issue_grant_failure.consumer)
  of AuditKind.Issue_grant_success:
    r.arm_Issue_grant_success.consumer
  of AuditKind.Policy_change_success:
    Opt.none(Address)
  of AuditKind.Revoke_grant_failure:
    Opt.some(r.arm_Revoke_grant_failure.consumer)
  of AuditKind.Revoke_grant_success:
    r.arm_Revoke_grant_success.consumer

func target*(r: AuditRecord): Opt[Address] =
  case r.kind
  of AuditKind.Grant_expired_success:
    Opt.some(r.arm_Grant_expired_success.target)
  of AuditKind.Issue_grant_deny:
    Opt.some(r.arm_Issue_grant_deny.target)
  of AuditKind.Issue_grant_failure:
    Opt.some(r.arm_Issue_grant_failure.target)
  of AuditKind.Issue_grant_success:
    Opt.some(r.arm_Issue_grant_success.target)
  of AuditKind.Revoke_grant_failure:
    r.arm_Revoke_grant_failure.target
  of AuditKind.Revoke_grant_success:
    Opt.some(r.arm_Revoke_grant_success.target)
  else:
    Opt.none(Address)

func grantId*(r: AuditRecord): Opt[string] =
  case r.kind
  of AuditKind.Grant_expired_success:
    Opt.some(r.arm_Grant_expired_success.grant_id)
  of AuditKind.Issue_grant_success:
    Opt.some(r.arm_Issue_grant_success.grant_id)
  of AuditKind.Revoke_grant_failure:
    Opt.some(r.arm_Revoke_grant_failure.grant_id)
  of AuditKind.Revoke_grant_success:
    Opt.some(r.arm_Revoke_grant_success.grant_id)
  else:
    Opt.none(string)

func decisionId*(r: AuditRecord): Opt[string] =
  case r.kind
  of AuditKind.Call_failure:
    Opt.some(r.arm_Call_failure.decision_id)
  of AuditKind.Call_success:
    Opt.some(r.arm_Call_success.decision_id)
  of AuditKind.Evaluate_allow:
    Opt.some(r.arm_Evaluate_allow.decision_id)
  of AuditKind.Evaluate_deny:
    Opt.some(r.arm_Evaluate_deny.decision_id)
  else:
    Opt.none(string)

# Segments ---------------------------------------------------------------------------

func unwritten*(log: AuditLog): int =
  for s in log.segments:
    result += s.records.len - s.written

proc add*(log: var AuditLog, r: StoredRecord, segmentRecords: int) =
  if log.segments.len == 0 or log.segments.peekLast.records.len >= segmentRecords:
    log.segments.addLast Segment(first: r.seq)
  log.segments.peekLast.records.add r
  inc log.count
  let d = r.record.decisionId
  if d.isSome:
    log.decisionIds.incl d.get

proc dropOldest*(log: var AuditLog): Segment =
  ## Removes the oldest segment, returning it.
  result = log.segments.popFirst()
  log.count -= result.records.len
  for r in result.records:
    let d = r.record.decisionId
    if d.isSome:
      log.decisionIds.excl d.get

func overBound*(log: AuditLog, bound: int): bool =
  ## Whether the oldest segment must go: more than `bound` records, and more
  ## than one segment (the open tail is never dropped).
  log.count > bound and log.segments.len > 1

# Queries ----------------------------------------------------------------------------

type AuditQuery* = object
  recordConsumer*: Opt[Address]
  target*: Opt[Address]
  decisionId*: Opt[string]
  grantId*: Opt[string]
  since*: Opt[uint64] ## inclusive
  until*: Opt[uint64] ## exclusive

func selects*(q: AuditQuery, r: AuditRecord): bool =
  ## [SPEC CA l.1120-1135] The filters, each on a record field. Every one may
  ## name a historical address (l.79).
  let ts = r.timestamp
  if q.since.isSome and ts < q.since.get:
    return false
  if q.until.isSome and ts >= q.until.get:
    return false
  if q.recordConsumer.isSome and r.consumer != q.recordConsumer:
    return false
  if q.target.isSome and r.target != q.target:
    return false
  if q.decisionId.isSome and r.decisionId != q.decisionId:
    return false
  if q.grantId.isSome and r.grantId != q.grantId:
    return false
  true

proc newestFirst*(rs: var seq[StoredRecord]) =
  ## `(timestamp desc, seq desc)` (CAP-0386, G51).
  rs.sort(
    proc(a, b: StoredRecord): int =
      let ta = a.record.timestamp
      let tb = b.record.timestamp
      if ta != tb:
        return (if ta > tb: -1 else: 1)
      if a.seq > b.seq:
        -1
      elif a.seq < b.seq:
        1
      else:
        0
  )
