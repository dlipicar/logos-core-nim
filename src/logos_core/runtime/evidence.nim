## Step 8b-3 (DECISIONS I85): the `logos.call-evidence.cose-sign1-slh-dsa-sha2-192s`
## profile (CA §9.1), which every conforming Runtime implements (CAP-0216): one
## complete `call` audit record and zero or more verified-view proofs, signed
## by the producing Runtime.
##
## The container is `crypto/cose.nim`'s COSE_Sign1, shared with package
## signing: tag 18, a protected header of exactly `kid`, an empty unprotected
## header, an embedded payload, and pure SLH-DSA-SHA2-192s with the empty
## context over the `Sig_structure` (CAP-0222 to CAP-0225, CAP-0394,
## CAP-0403 to CAP-0405), whose `external_aad` is the UTF-8 profile
## identifier (CAP-0396). Its payload is the deterministic-CBOR
## `call_evidence_claim`.
##
## - Producer: `buildClaim` checks the record and any proofs; `signEvidence`
##   signs hedged, fails when randomness fails, and checks the signature
##   under the key's own public key before it returns (CAP-0406). The Runtime
##   retains no verified views in Tier 4, so the claims it exports carry no
##   proofs (CAP-0409).
## - Verifier: `verifyEvidence` against an `EvidenceContext` built from
##   protected input: each accepted `kid` bound to one producer and one exact
##   48-byte public key, for call evidence only (CAP-0226, CAP-0227,
##   CAP-0229), and a resolver for the defining contracts of signed call
##   scopes. The profile, algorithm, structure and `external_aad` come from
##   this module, never from the container (CAP-0397, CAP-0398); a failed
##   verification is final, with no retry (CAP-0400).
## - The key: `loadEvidenceKey` reads the host's 96-byte FIPS 205 secret key
##   file (`call_audit.evidence`); `EvidenceSigner` holds it and is cleared
##   when dropped (CAP-0230). It is never a package signing key (CAP-0401).
##
## A container is a statement by its producer. It is never authorization
## material (CAP-0256), proves no package or provider trust, and is not fresh.

{.push raises: [].}

import std/tables
from std/os import isAbsolute
import results
import ../cbor
import ../hash/[hashinput, view]
import ../authority/scopes
import ../crypto/[cose, slhdsa]

when not defined(windows):
  import std/posix

export
  results, cose.CoseError, slhdsa.SecretKey, slhdsa.PublicKey, slhdsa.clear,
  view.ViewSchema

type
  EvidenceClaim* = LogosNSCapabilityAuthorityCallEvidenceClaim
  EvidenceProofs* = LogosNSCapabilityAuthorityCallEvidenceProofs
  ValueCommitment* = LogosNSCapabilityAuthorityAuditValueCommitment

  DefiningContract* = object
    ## [SPEC CA l.1199-1206] What a method's defining contract supplies to the
    ## verification of a proof: its schema root, hash profile, hash suite and
    ## commitment-model revision, and the schema a verified view is checked
    ## against (HASH §8, G120).
    schemaRoot*: Digest
    profileId*, suiteId*, modelId*: string
    schema*: ViewSchema

  ContractResolver* = proc(
    contract: seq[byte], declaration: seq[byte]
  ): Opt[DefiningContract] {.gcsafe, raises: [].}
    ## [SPEC CA l.1302; CAP-0238] The defining contract of the method whose
    ## declaration root is `declaration`, on the selected contract whose schema
    ## root is `contract` (for `logos.schema`, the common schema); none when
    ## the verifier does not know it.

  EvidenceKey = object
    producer: string
    publicKey: PublicKey

  EvidenceContext* = object ## [SPEC CA l.1254-1270] The verifier's protected context.
    keys: Table[seq[byte], EvidenceKey]
    resolver: ContractResolver

  VerifiedEvidence* = object
    kid*: seq[byte]
    producer*: string
    record*: AuditRecord
    proofs*: Opt[EvidenceProofs]

  EvidenceSigner* = object
    ## [SPEC CA l.1272-1276] The producer's evidence key, held by the host.
    kid*: seq[byte]
    producer*: string
    key: SecretKey
    publicKey*: PublicKey

func evidenceProfile*(): string =
  ## [SPEC CA l.1228] The profile identifier, from the mirrored CDDL.
  LogosNSCapabilityAuthorityCallEvidenceProfileLiteral

func evidenceAad*(): seq[byte] =
  ## [SPEC CA l.1257; CAP-0396] The `external_aad`: the profile identifier's
  ## UTF-8 bytes, from this module's own context.
  let p = evidenceProfile()
  @(p.toOpenArrayByte(0, p.high))

# The record and the proofs -----------------------------------------------------------

func isCallScope(s: Scope): bool =
  ## [SPEC CA l.1182-1188; CAP-0207, CAP-0209] A provider-access scope with
  ## the `call` action, one route, one provider and one method declaration
  ## root (and no event); or a Runtime Control scope with exactly one method
  ## and no events.
  case s.kind
  of skProvider:
    let p = s.pa
    p.actions.len == 1 and p.actions[0].kind == PaActionKind.Call and p.routes.isSome and
      p.routes.get.len == 1 and p.providers.isSome and p.providers.get.len == 1 and
      p.access.isSome and p.access.get.methods.isSome and
      p.access.get.methods.get.len == 1 and p.access.get.publish_events.isNone and
      p.access.get.subscribe_events.isNone
  of skControl:
    let r = s.rc
    r.methods.isSome and r.methods.get.len == 1 and r.events.isNone
  else:
    false

func callParts(
    r: AuditRecord
): Result[(Scope, Opt[LogosNSCapabilityAuthorityCallCommitments]), string] =
  case r.kind
  of AuditKind.Call_success:
    ok((r.arm_Call_success.scopes[0], Opt.some(r.arm_Call_success.commitments)))
  of AuditKind.Call_failure:
    ok((r.arm_Call_failure.scopes[0], r.arm_Call_failure.commitments))
  else:
    err("the record is not a call record")

func sides(
    c: Opt[LogosNSCapabilityAuthorityCallCommitments]
): (Opt[ValueCommitment], Opt[ValueCommitment]) =
  if c.isNone:
    return
  let v = c.get
  case v.kind
  of LogosNSCapabilityAuthorityCallCommitmentsKind.Map_request:
    (Opt.some(v.arm_Map_request.request), v.arm_Map_request.response)
  of LogosNSCapabilityAuthorityCallCommitmentsKind.Map_response:
    (Opt.none(ValueCommitment), Opt.some(v.arm_Map_response.response))

func commitmentOk(c: ValueCommitment): bool =
  c.schema_subtree_root.len == 32 and c.value_root.len == 32

proc checkCallRecord*(r: AuditRecord): Result[void, string] =
  ## [SPEC CA l.1172-1198; CAP-0232] The `call` audit-record rules a signed
  ## record satisfies: a `call` variant whose one scope is a call scope;
  ## commitments of 32-byte roots, non-empty on success (the CDDL forbids an
  ## empty `call_commitments`).
  let (scope, commitments) = ?callParts(r)
  if not isCallScope(scope):
    return err("the record's scope is not one call scope")
  let (q, s) = sides(commitments)
  if (q.isSome and not commitmentOk(q.get)) or (s.isSome and not commitmentOk(s.get)):
    return err("a commitment is not two 32-byte roots")
  ok()

func bytewise(a, b: openArray[byte]): int =
  ## Bytewise lexicographic order.
  for i in 0 ..< min(a.len, b.len):
    if a[i] != b[i]:
      return (if a[i] < b[i]: -1 else: 1)
  cmp(a.len, b.len)

func pathKey(view: VerifiedView): seq[byte] =
  ## [SPEC CA l.1294-1296] The ordering key: the deterministic encoding of the
  ## decoded semantic path, verified-view field 7.
  encodeCbor(toCbor(view.path))

proc parseProof(bytes: openArray[byte]): Result[VerifiedView, string] =
  ## [CAP-0235] Exactly one Logos deterministic-CBOR `verified-view`.
  let v = decodeCbor(bytes).valueOr:
    return err("a proof is not deterministic CBOR: " & $error)
  let view = parseView(v).valueOr:
    return err("a proof is not a verified view: " & $error)
  ok(view)

proc checkSide(
    proofs: Opt[seq[seq[byte]]], commitment: Opt[ValueCommitment], side: string
): Result[seq[VerifiedView], string] =
  ## [SPEC CA l.1291-1300; CAP-0409 to CAP-0413, CAP-0236] One side's proofs:
  ## absent or non-empty, each a verified view, strictly ascending by semantic
  ## path with no path twice (never sorted or deduplicated here), and only
  ## beside a commitment on the same side.
  if proofs.isNone:
    return ok(newSeq[VerifiedView]())
  if proofs.get.len == 0:
    return err("an empty " & side & " proof array")
  if commitment.isNone:
    return err("a " & side & " proof without a " & side & " commitment")
  var views: seq[VerifiedView]
  var last: seq[byte]
  for i, p in proofs.get:
    let view = ?parseProof(p)
    let key = pathKey(view)
    if i > 0 and bytewise(key, last) <= 0:
      return err("the " & side & " proofs are not in strictly ascending path order")
    last = key
    views.add(view)
  ok(views)

proc checkProofs(
    r: AuditRecord, proofs: Opt[EvidenceProofs]
): Result[(seq[VerifiedView], seq[VerifiedView]), string] =
  if proofs.isNone:
    return ok((newSeq[VerifiedView](), newSeq[VerifiedView]()))
  let p = proofs.get
  if p.request.isNone and p.response.isNone:
    return err("proofs without a request or a response proof") # CAP-0234
  let (_, commitments) = ?callParts(r)
  let (q, s) = sides(commitments)
  let requestViews = ?checkSide(p.request, q, "request")
  let responseViews = ?checkSide(p.response, s, "response")
  ok((requestViews, responseViews))

# Producer -----------------------------------------------------------------------------

proc buildClaim*(
    producer: string, record: AuditRecord, proofs = Opt.none(EvidenceProofs)
): Result[EvidenceClaim, string] =
  ## [SPEC CA l.1222-1243, l.1289-1300] The claim for one complete `call`
  ## record produced by `producer`'s invocation boundary.
  if producer.len == 0:
    return err("no producer")
  ?checkCallRecord(record)
  discard ?checkProofs(record, proofs)
  ok(
    EvidenceClaim(
      profile: evidenceProfile(), producer: producer, record: record, proofs: proofs
    )
  )

proc signEvidence*(
    claim: EvidenceClaim,
    kid: openArray[byte],
    key: SecretKey,
    random: RandomSource = osRandom,
): Result[seq[byte], string] =
  ## [SPEC CA l.1246-1283] The container for `claim` under `kid`: pure
  ## SLH-DSA-SHA2-192s with the empty context over the `Sig_structure`,
  ## hedged with fresh bytes from `random` and failing when it cannot supply
  ## them (CAP-0403 to CAP-0406). [IMPL] The signature is checked under the
  ## key's own public key before it is returned.
  if kid.len < MinCoseKidBytes or kid.len > MaxCoseKidBytes:
    return err("a kid is 1 to 128 bytes")
  let payload = encode(claim).valueOr:
    return err("the claim does not encode: " & error)
  var (c, tbs) = unsignedCose(kid, payload, evidenceAad())
  let sig = sign(key, tbs, random = random).valueOr:
    return err("signing failed: " & error)
  if not verify(publicKey(key), tbs, sig):
    return err("the signature does not verify under the key")
  c.signature = sig
  ok(encodeCoseSign1(c))

proc newEvidenceSigner*(
    kid: openArray[byte], producer: string, key: SecretKey
): Result[EvidenceSigner, string] =
  if kid.len < MinCoseKidBytes or kid.len > MaxCoseKidBytes:
    return err("a kid is 1 to 128 bytes")
  if producer.len == 0:
    return err("no producer")
  ok(EvidenceSigner(kid: @kid, producer: producer, key: key, publicKey: publicKey(key)))

proc clear*(s: var EvidenceSigner) =
  ## [SPEC CA l.1272-1276; CAP-0230] Overwrites the secret key; its holder
  ## calls this when it is done with it.
  clear(s.key)

proc exportEvidence*(
    s: EvidenceSigner,
    record: AuditRecord,
    proofs = Opt.none(EvidenceProofs),
    random: RandomSource = osRandom,
): Result[seq[byte], string] =
  ## A signed container for `record`, produced by this signer's Runtime.
  let claim = ?buildClaim(s.producer, record, proofs)
  signEvidence(claim, s.kid, s.key, random)

proc exportRecord*(
    s: EvidenceSigner, recordBytes: openArray[byte], random: RandomSource = osRandom
): Result[seq[byte], string] =
  ## A container for one retained record, as its deterministic CBOR, with no
  ## proofs.
  let record = AuditRecord.decode(recordBytes).valueOr:
    return err("the retained record does not decode: " & error)
  s.exportEvidence(record, random = random)

# The key file -----------------------------------------------------------------------------

proc loadEvidenceKey*(path: string): Result[SecretKey, string] =
  ## [SPEC CA l.1272-1276; plan §2.15] The FIPS 205 SLH-DSA-SHA2-192s secret
  ## key in `path`: an absolute path to a regular file (not a link) of exactly
  ## 96 bytes, owned by this process's user with mode 0600 on POSIX [IMPL;
  ## not checked on Windows], whose public key half is the one its seeds
  ## derive (FIPS 205 Algorithm 18). The bytes read are cleared.
  if not isAbsolute(path):
    return err("the evidence key file is not an absolute path")
  when not defined(windows):
    var st: Stat
    if lstat(cstring(path), st) != 0:
      return err("the evidence key file cannot be read")
    if not S_ISREG(st.st_mode):
      return err("the evidence key file is not a regular file")
    if st.st_uid != getuid():
      return err("the evidence key file is not owned by this process's user")
    if (int(st.st_mode) and 0o777) != 0o600:
      return err("the evidence key file's mode is not 0600")
    if st.st_size != SecretKeyBytes:
      return err("the evidence key file is not 96 bytes")
  var key: SecretKey
  var f: File
  if not open(f, path, fmRead):
    return err("the evidence key file cannot be read")
  let n =
    try:
      readBuffer(f, addr key[0], SecretKeyBytes)
    except IOError:
      -1
  var extra: byte
  let more =
    try:
      readBuffer(f, addr extra, 1)
    except IOError:
      -1
  close(f)
  if n != SecretKeyBytes or more != 0:
    clear(key)
    return err("the evidence key file is not 96 bytes")
  var skSeed, skPrf, pkSeed: Seed
  for i in 0 ..< N:
    skSeed[i] = key[i]
    skPrf[i] = key[N + i]
    pkSeed[i] = key[2 * N + i]
  var (derived, _) = keyPairFromSeeds(skSeed, skPrf, pkSeed)
  let same = derived == key
  clear(derived)
  zeroMem(addr skSeed[0], N)
  zeroMem(addr skPrf[0], N)
  if not same:
    clear(key)
    return err("the evidence key's public key is not the one its seeds derive")
  ok(key)

# Verifier ---------------------------------------------------------------------------------

proc newEvidenceContext*(resolver: ContractResolver = nil): EvidenceContext =
  EvidenceContext(resolver: resolver)

proc accept*(
    ctx: var EvidenceContext,
    kid: openArray[byte],
    producer: string,
    publicKey: openArray[byte],
): Result[void, string] =
  ## [SPEC CA l.1265-1270; CAP-0226, CAP-0227, CAP-0229] Accepts one
  ## call-evidence key: `kid` names exactly one producer and one exact 48-byte
  ## public key, and two keys never share a `kid`.
  if kid.len < MinCoseKidBytes or kid.len > MaxCoseKidBytes:
    return err("a kid is 1 to 128 bytes")
  if producer.len == 0:
    return err("no producer")
  if publicKey.len != PublicKeyBytes:
    return err("an SLH-DSA-SHA2-192s public key is 48 bytes")
  if @kid in ctx.keys:
    return err("a kid is accepted once")
  var pk: PublicKey
  for i, b in publicKey:
    pk[i] = b
  ctx.keys[@kid] = EvidenceKey(producer: producer, publicKey: pk)
  ok()

proc revoke*(ctx: var EvidenceContext, kid: openArray[byte]) =
  ## [SPEC CA l.1283-1285; CAP-0231] Evidence under a revoked `kid` is
  ## rejected, all of it.
  ctx.keys.del(@kid)

func structureError(f: CoseFailure): string =
  case f.kind
  of ceNotCbor:
    "the container is not deterministic CBOR: " & f.detail
  of ceNotTagged:
    "the container is not a tagged COSE_Sign1"
  of ceNotFour:
    "a COSE_Sign1 is an array of four elements"
  of ceProtectedNotBytes:
    "the protected header is not a byte string"
  of ceProtectedNotCbor:
    "the protected header is not deterministic CBOR: " & f.detail
  of ceProtectedNotMap:
    "the protected header is not a map"
  of ceAlgPresent:
    "an explicit alg header is refused: the algorithm is fixed"
  of ceNotOnlyKid:
    "the protected header holds exactly kid"
  of ceKidNotBytes:
    "the kid is not a byte string"
  of ceKidSize:
    "the kid is not 1 to 128 bytes"
  of ceUnprotectedNotEmpty:
    "the unprotected header is not an empty map"
  of cePayloadDetached:
    "the payload is missing or detached"
  of ceSignatureNotBytes:
    "the signature is not a byte string"
  of ceSignatureSize:
    "the signature is not 16224 bytes"

func callScopeIds(s: Scope): (seq[byte], seq[byte]) =
  ## The selected contract's schema root and the one method declaration root.
  case s.kind
  of skProvider:
    let p = s.pa
    (p.contract.schema_root, p.access.get.methods.get[0])
  of skControl:
    let r = s.rc
    (r.contract.schema_root, r.methods.get[0])
  else:
    (newSeq[byte](), newSeq[byte]())

proc checkView(
    view: VerifiedView, commitment: ValueCommitment, d: DefiningContract
): Result[void, string] =
  ## [SPEC CA l.1302-1309; CAP-0237, CAP-0239, CAP-0240]
  if view.schemaRoot != d.schemaRoot or view.profileId != d.profileId or
      view.suiteId != d.suiteId or view.modelId != d.modelId:
    return err("a proof is not under the method's defining contract")
  if @(view.subtreeRoot) != commitment.schema_subtree_root or
      @(view.valueRoot) != commitment.value_root:
    return err("a proof's roots are not the signed commitment's")
  verifyView(view, d.schema).isOkOr:
    return err("a proof does not verify: " & $error)
  ok()

proc verifyEvidence*(
    container: openArray[byte], ctx: EvidenceContext
): Result[VerifiedEvidence, string] =
  ## [SPEC CA §9.1 l.1246-1316] In order: the COSE structure (CAP-0414,
  ## CAP-0395); a known, unrevoked `kid` (CAP-0231); FIPS 205 `slh_verify`
  ## over the `Sig_structure` with this profile's `external_aad`, accepting
  ## deterministic and hedged signatures and repairing nothing (CAP-0407,
  ## CAP-0408); the claim as deterministic CBOR of `call_evidence_claim`; its
  ## profile (CAP-0399); its producer, the kid's (CAP-0233); the record
  ## rules (CAP-0232); and the proofs (CAP-0234 to CAP-0240, CAP-0409 to
  ## CAP-0413). Any failure rejects the whole container, with no retry under
  ## another context (CAP-0400).
  let c = decodeCoseSign1Structure(container).valueOr:
    return err(structureError(error))
  let key = ctx.keys.getOrDefault(c.kid, EvidenceKey())
  if key.producer.len == 0:
    return err("the kid is unknown or revoked")
  if not verify(
    key.publicKey, sigStructure(c.protectedBytes, c.payload, evidenceAad()), c.signature
  ):
    return err("the signature does not verify under the kid's key")
  let claim = EvidenceClaim.decode(c.payload).valueOr:
    return err("the claim is not a call_evidence_claim: " & error)
  if claim.profile != evidenceProfile():
    return err("the claim names another profile")
  if claim.producer != key.producer:
    return err("the producer is not the one authorized for the kid")
  ?checkCallRecord(claim.record)
  let (requestViews, responseViews) = ?checkProofs(claim.record, claim.proofs)
  if requestViews.len + responseViews.len > 0:
    if ctx.resolver.isNil:
      return err("no defining contract is known for the proofs")
    let (scope, commitments) = ?callParts(claim.record)
    let (contract, declaration) = callScopeIds(scope)
    let d = ctx.resolver(contract, declaration).valueOr:
      return err("the method's defining contract is not known")
    let (q, s) = sides(commitments)
    for v in requestViews:
      ?checkView(v, q.get, d)
    for v in responseViews:
      ?checkView(v, s.get, d)
  ok(
    VerifiedEvidence(
      kid: c.kid, producer: claim.producer, record: claim.record, proofs: claim.proofs
    )
  )
