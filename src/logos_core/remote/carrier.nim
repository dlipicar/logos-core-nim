## The remote control channel (Tier 5 step 5-7a-1; DECISIONS G410, G411)
## [IMPL]: one connected `AF_UNIX` stream socket pair between logosd and one
## remote process (`logos_remote`, 5-7a-2), or between logosd and its key
## holder (`logos_keyholder`). Every side uses this module.
##
## - **Frames.** As the Module Host carrier's (`runtime/carrier.nim`): a 4-byte
##   big-endian length, then one Logos deterministic-CBOR `lcn.rch_message`
##   (`carrier.cddl`, codecs in `carrier_types.nim`). The body limit is the
##   Transport floor plus 64 KiB, so the snapshot of a 16 MiB remote trust
##   input fits. A frame over it, one that does not decode, or one a side does
##   not expect ends the channel.
## - **Lanes.** A message's `kind` fixes its lane (the schema's comment). A
##   sign request names no role: logosd fixed it for the process.
## - **No payload.** Nothing here carries a module payload: the snapshot, the
##   sign exchange and, in tests, the key (5-7a plan §3.16).
##
## Generated case objects never cross threads: as on the Module Host carrier,
## threads hand each other frame bytes and decode their own copy.

{.push raises: [], gcsafe.}

import results
import ../transport/framing
import ../transport/tls/[signing, trust]
import ./carrier_types

export carrier_types, framing, signing

const RchFrameLimit* = uint32(MinFrameLimit + 64 * 1024)
  ## [IMPL] the largest frame body either side accepts

proc newRchReader*(): FrameReader =
  newFrameReader(RchFrameLimit).expect("the channel limit is over the floor")

# Messages ------------------------------------------------------------------------------

template arm(T: typedesc, k, field: untyped) =
  func toMessage*(x: sink T): LcnRchMessage =
    LcnRchMessage(kind: LcnRchMessageKind.k, field: x)

arm(LcnRchSnapshot, lcn_Rch_snapshot, arm_lcn_Rch_snapshot)
arm(LcnRchTestKey, lcn_Rch_test_key, arm_lcn_Rch_test_key)
arm(LcnRchSign, lcn_Rch_sign, arm_lcn_Rch_sign)
arm(LcnRchHolderSign, lcn_Rch_holder_sign, arm_lcn_Rch_holder_sign)
arm(LcnRchSigned, lcn_Rch_signed, arm_lcn_Rch_signed)
arm(LcnRchSignRefused, lcn_Rch_sign_refused, arm_lcn_Rch_sign_refused)

proc frameOf*(m: LcnRchMessage): Result[seq[byte], string] =
  ## The length prefix and the encoded message.
  let body = ?encode(m)
  let f = frame(body, RchFrameLimit).valueOr:
    return err("a channel message of " & $error.declared & " bytes does not fit")
  ok(f)

proc decodeMessage*(body: openArray[byte]): Result[LcnRchMessage, string] =
  ## One frame body as one message; anything else ends the channel.
  LcnRchMessage.decode(body)

# The sign exchange -----------------------------------------------------------------------

func roleChoice*(role: TlsRole): LcnRchHolderSignRoleChoice =
  case role
  of tlsClient:
    LcnRchHolderSignRoleChoice(kind: LcnRchHolderSignRoleChoiceKind.Client)
  of tlsServer:
    LcnRchHolderSignRoleChoice(kind: LcnRchHolderSignRoleChoiceKind.Server)

func roleOf*(c: LcnRchHolderSignRoleChoice): TlsRole =
  case c.kind
  of LcnRchHolderSignRoleChoiceKind.Client: tlsClient
  of LcnRchHolderSignRoleChoiceKind.Server: tlsServer

func signRequest*(id: uint64, alg: uint16, input: seq[byte]): LcnRchMessage =
  toMessage(LcnRchSign(id: id, alg: alg, input: input))

func holderRequest*(
    id: uint64, role: TlsRole, alg: uint16, input: seq[byte]
): LcnRchMessage =
  ## A sign request relayed to the key holder under logosd's `id`, with the
  ## role logosd fixed for the process that asked.
  toMessage(LcnRchHolderSign(id: id, role: roleChoice(role), alg: alg, input: input))

func signAnswer*(id: uint64, r: SignResult): LcnRchMessage =
  ## `signed`, or `sign_refused` with its reason.
  case r.status
  of ssSigned:
    toMessage(LcnRchSigned(id: id, signature: r.signature))
  of ssRefused:
    toMessage(
      LcnRchSignRefused(
        id: id,
        reason:
          LcnRchSignRefusedReasonChoice(kind: LcnRchSignRefusedReasonChoiceKind.Refused),
      )
    )
  of ssUnavailable:
    toMessage(
      LcnRchSignRefused(
        id: id,
        reason: LcnRchSignRefusedReasonChoice(
          kind: LcnRchSignRefusedReasonChoiceKind.Unavailable
        ),
      )
    )

func isAnswer*(m: LcnRchMessage): bool =
  m.kind in {LcnRchMessageKind.lcn_Rch_signed, LcnRchMessageKind.lcn_Rch_sign_refused}

func answerId*(m: LcnRchMessage): uint64 =
  ## The request an answer names; 0 for any other message.
  case m.kind
  of LcnRchMessageKind.lcn_Rch_signed: m.arm_lcn_Rch_signed.id
  of LcnRchMessageKind.lcn_Rch_sign_refused: m.arm_lcn_Rch_sign_refused.id
  else: 0

func answerOf*(m: LcnRchMessage): SignResult =
  ## The result an answer carries; `unavailable` for any other message.
  case m.kind
  of LcnRchMessageKind.lcn_Rch_signed:
    signed(m.arm_lcn_Rch_signed.signature)
  of LcnRchMessageKind.lcn_Rch_sign_refused:
    case m.arm_lcn_Rch_sign_refused.reason.kind
    of LcnRchSignRefusedReasonChoiceKind.Refused:
      refused()
    of LcnRchSignRefusedReasonChoiceKind.Unavailable:
      unavailable()
  else:
    unavailable()

func withId*(m: LcnRchMessage, id: uint64): LcnRchMessage =
  ## An answer renamed to `id` (logosd's relay maps the key holder's ids back
  ## to each process's own); any other message unchanged.
  result = m
  case result.kind
  of LcnRchMessageKind.lcn_Rch_signed:
    result.arm_lcn_Rch_signed.id = id
  of LcnRchMessageKind.lcn_Rch_sign_refused:
    result.arm_lcn_Rch_sign_refused.id = id
  else:
    discard

# The snapshot ---------------------------------------------------------------------------

func statusChoice(s: RecordStatus): LcnRchRecordStatusChoice =
  case s
  of rsActive:
    LcnRchRecordStatusChoice(kind: LcnRchRecordStatusChoiceKind.Active)
  of rsRevoked:
    LcnRchRecordStatusChoice(kind: LcnRchRecordStatusChoiceKind.Revoked)
  of rsConflicting:
    LcnRchRecordStatusChoice(kind: LcnRchRecordStatusChoiceKind.Conflicting)

func statusOf(c: LcnRchRecordStatusChoice): RecordStatus =
  case c.kind
  of LcnRchRecordStatusChoiceKind.Active: rsActive
  of LcnRchRecordStatusChoiceKind.Revoked: rsRevoked
  of LcnRchRecordStatusChoiceKind.Conflicting: rsConflicting

func snapshotMessage*(t: TrustSnapshot): LcnRchMessage =
  ## [B3; G408] What the verifier of this start holds, anchors and records
  ## each ascending, so one snapshot is always one message.
  var s = LcnRchSnapshot(revision: t.anchorRevision)
  for id in t.anchorIds:
    s.anchors.add(LcnRchAnchor(id: id, certificate: t.anchor(id).get))
  for runtime in t.runtimes:
    let r = t.record(runtime).get
    s.records.add(
      LcnRchRecord(
        runtime_instance_id: r.runtime,
        revision: r.revision,
        status: statusChoice(r.status),
        anchor:
          if r.status == rsActive:
            Opt.some(r.anchor)
          else:
            Opt.none(string),
        keys: r.spkis,
      )
    )
  toMessage(s)

proc snapshotOf*(m: LcnRchSnapshot): Result[TrustSnapshot, string] =
  ## The snapshot a remote process verifies with, checked as logosd's own is
  ## (`trust.newTrustSnapshot`); an `active` record names its anchor, a
  ## `revoked` one holds no key.
  var anchors: seq[(string, seq[byte])]
  for a in m.anchors:
    anchors.add((a.id, a.certificate))
  var records: seq[EnrollmentRecord]
  for r in m.records:
    let status = statusOf(r.status)
    case status
    of rsActive:
      if r.anchor.isNone:
        return err("an active record of " & r.runtime_instance_id & " names no anchor")
    of rsRevoked:
      if r.anchor.isSome or r.keys.len > 0:
        return err(
          "a revoked record of " & r.runtime_instance_id & " holds an anchor or a key"
        )
    of rsConflicting:
      if r.anchor.isSome:
        return
          err("a conflicting record of " & r.runtime_instance_id & " names an anchor")
    records.add(
      EnrollmentRecord(
        runtime: r.runtime_instance_id,
        revision: r.revision,
        status: status,
        anchor: r.anchor.get(""),
        spkis: r.keys,
      )
    )
  newTrustSnapshot(m.revision, anchors, records)

{.pop.}
