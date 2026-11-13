## RUNTIME §3.6, §10.1 l.3801-3804; CA §3.3, §8 l.828-866: an instance's
## execution authorization once its decision allowed it (step 8b-2; DECISIONS
## I85). This module holds the record and the rules over it: its validity,
## when it is renewed, what a renewal's answer does, the policy-change
## retention rule and the grant endings. The engine keeps one record per
## instance and acts on what these say (`engine.nim`, `stopForAuthority`).
##
## Only a Capability Authority decision ends: internal, bootstrap and recovery
## authorizations have no validity end and the authority never touches them
## (plan §2.9).

{.push raises: [].}

import results
import ./[authz, authscopes]

export results

const
  MaxRenewLeadNs* = 30_000_000_000'i64
    ## [IMPL] renewal starts at most 30 s before the validity end, and never
    ## earlier than two thirds of the way through it
  MaxRetryNs* = 5_000_000_000'i64
    ## [IMPL] a renewal that failed is asked again after at most 5 s, or half
    ## of what is left, whichever is sooner

type
  ExecEnding* = enum
    ## Why an execution authorization ended: the instance's `failure`
    ## classification (RUNTIME l.3753; plan §2.17).
    eeNone = ""
    eeExpired = "authority-expired"
    eeRevoked = "authority-revoked"
    eeDenied = "authority-denied"
    eeFailed = "authority-evaluation-failed"

  ExecAuth* = object
    source*: PolicySource
    generation*: uint64 ## the binding generation it was decided under
    decisionId*: string
    policyRevision*: uint64
    validUntil*: Opt[uint64] ## wall-clock milliseconds
    deadline*: Opt[int64]
      ## the same end on the engine's monotonic clock, fixed when the decision
      ## was received, so a backward wall-clock step never extends it
    renewAt*: Opt[int64] ## monotonic nanoseconds
    grants*: seq[string] ## the grants the decision used
    request*: AuthzRequest ## what a renewal asks again
    renewing*: bool ## a renewal is being evaluated

func ends*(x: ExecAuth): bool =
  ## [SPEC CA l.828-866] Only a Capability Authority decision ends.
  x.source == psAuthority

func authorization*(
    a: AuthzAnswer, generation: uint64, wallNow: uint64, monoNow: int64
): ExecAuth =
  ## The record of an allow. [IMPL reading, plan §6.3] An allow without
  ## `valid_until` authorizes the execution it was asked for until it is
  ## invalidated: there is nothing to renew.
  result = ExecAuth(
    source: a.source,
    generation: generation,
    decisionId: a.decisionId,
    policyRevision: a.policyRevision,
    validUntil: a.validUntil,
    grants: a.grants,
    request: a.request,
  )
  if a.source == psAuthority and a.validUntil.isSome:
    let leftMs = int64(a.validUntil.get - min(a.validUntil.get, wallNow))
    let lifetime = leftMs * 1_000_000
    let deadline = monoNow + lifetime
    result.deadline = Opt.some(deadline)
    result.renewAt = Opt.some(deadline - min(MaxRenewLeadNs, lifetime div 3))

func expired*(x: ExecAuth, wallNow: uint64, monoNow: int64): bool =
  ## [SPEC CA l.857-858; CAP-0342] The validity end is reached on either
  ## clock.
  x.ends and x.validUntil.isSome and
    (wallNow >= x.validUntil.get or monoNow >= x.deadline.get)

func renewalDue*(x: ExecAuth, monoNow: int64): bool =
  x.ends and x.renewAt.isSome and not x.renewing and monoNow >= x.renewAt.get

func nextEvent*(x: ExecAuth): Opt[int64] =
  ## When the engine must look at this record again: the renewal time, or the
  ## validity end while a renewal is out.
  if not x.ends or x.deadline.isNone:
    return Opt.none(int64)
  if x.renewing:
    return x.deadline
  Opt.some(min(x.renewAt.get, x.deadline.get))

func retryLater*(x: var ExecAuth, monoNow: int64) =
  ## [SPEC CA l.861-862; CAP-0350, CAP-0351] A renewal failed for a reason
  ## that may pass: the authorization stays while it is valid on its own, is
  ## never extended, and the renewal is asked again before the end.
  x.renewing = false
  if x.deadline.isSome:
    let left = max(0'i64, x.deadline.get - monoNow)
    x.renewAt = Opt.some(monoNow + min(MaxRetryNs, left div 2))

func renewed*(
    x: var ExecAuth, a: AuthzAnswer, generation: uint64, wallNow: uint64, monoNow: int64
): ExecEnding =
  ## [SPEC CA §5.1 l.578-602; plan §2.9] What a renewal's answer does. An
  ## allow replaces the record, for the same request, so never wider. A deny
  ## ends it. An allow narrowed below the execution ends it as revoked [IMPL,
  ## as a narrowed route renewal, G170]. An evaluation failure leaves it as
  ## it is, to be asked again (`retryLater`).
  x.renewing = false
  case a.outcome
  of azAllow:
    if a.narrowed:
      return eeRevoked
    let request = x.request
    x = authorization(a, generation, wallNow, monoNow)
    x.request = request
    eeNone
  of azDeny:
    eeDenied
  of azEvaluationFailed, azRefused:
    x.retryLater(monoNow)
    eeNone

func onPolicyChange*(
    x: var ExecAuth, n: Notice, instance: string, generation: uint64
): ExecEnding =
  ## [SPEC CA l.845-850; CAP-0166 to CAP-0169] An authorization decided at or
  ## after the new revision does not depend on the transition. Otherwise it
  ## is retained only when the notice belongs to its binding, its previous
  ## revision is the authorization's, and a complete `affected_executions`
  ## leaves the instance out; it then moves to the new revision, no longer
  ## and no wider. Anything else ends it as revoked (plan §2.9).
  if not x.ends or x.policyRevision >= n.revision:
    return eeNone
  if x.generation == generation and n.previous == x.policyRevision and n.affected.isSome and
      instance notin n.affected.get:
    x.policyRevision = n.revision
    return eeNone
  eeRevoked

func onGrantEnded*(x: ExecAuth, grant: string, expired: bool): ExecEnding =
  ## [SPEC CA l.851-853, l.913; CAP-0170] A revoked or expired grant the
  ## decision used ends it; an unrelated grant does not.
  if not x.ends or grant notin x.grants:
    return eeNone
  if expired: eeExpired else: eeRevoked
