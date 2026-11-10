## PM §4, §4.1, §4.3: the `logos.package-signing.cose-sign1-ed25519` profile.
## `manifest.cose` is a tagged COSE_Sign1 (RFC 9052) whose embedded payload is
## the Logos deterministic-CBOR signature claim; the protected header holds
## exactly `alg` = -19 (Ed25519, RFC 9864) and `kid`.
##
## The claim schema is the mirrored PM §4.3 block plus the
## `logos.package_manager.manifest_commitment` rule cut from the mirrored PM §5
## block, accepted as one supporting schema. The outer COSE structure and the
## protected header use RFC 8949 §4.2.1 core deterministic encoding, which at
## spec f4f83471 imposes the same bytes as the Logos profile, so the one
## encoder and strict decoder serve both (I9).

{.push raises: [].}

import std/strutils
import results
import ../base/hex
import ../cbor
import ../cddl/syntax
import ../commitment
import ../hash
import ../iface/accept
import ../crypto/ed25519
import ./[errors, manifest, trust]

export results, errors, manifest, trust

const
  CoseSign1Tag* = 18'u64 ## [SPEC PM §4.3] RFC 9052 tagged COSE_Sign1
  CoseHeaderAlg* = 1'u64 ## RFC 9052 `alg`
  CoseHeaderKid* = 4'u64 ## RFC 9052 `kid`
  CoseAlgEd25519* = -19'i64 ## [SPEC PM §4.3] RFC 9864 fully specified Ed25519
  SignatureContext* = "Signature1" ## RFC 9052 §4.4
  ClaimType* = "logos.package_manager.package_signature_claim"
  ProfileType* = "logos.package_manager.package_signing_profile"
  CommitmentType* = "logos.package_manager.manifest_commitment"

type
  CoseSign1* = object
    protectedBytes*: seq[byte] ## the serialized protected header map
    kid*: seq[byte]
    payload*: seq[byte] ## the embedded claim bytes
    signature*: Signature

  VerifiedPackage* = object ## A manifest whose signature PM §4.1 and §4.3 accept.
    manifest*: Manifest
    commitment*: ManifestCommitment
    signer*: TrustAnchor

# The claim schema ------------------------------------------------------------------

type ClaimSchema = ref object
  set: SchemaSet
  claim: SchemaNode
  profile: string ## the profile identifier literal

proc claimDocument(): Result[string, string] =
  ## PM §4.3's block and, from PM §5's, the text of the one rule it uses.
  let rules = parseSource(PackageRecordsDocument).valueOr:
    return err("PM §5 does not parse: " & $error)
  var start = -1
  var stop = PackageRecordsDocument.len
  for r in rules:
    if r.name == CommitmentType:
      start = r.pos
    elif start >= 0 and r.pos > start and r.pos < stop:
      stop = r.pos
  if start < 0:
    return err("PM §5 does not define " & CommitmentType)
  ok(
    PackageSigningProfileDocument.strip & "\n\n" &
      PackageRecordsDocument[start ..< stop].strip & "\n"
  )

proc loadClaimSchema(): Result[ClaimSchema, string] =
  let doc = ?claimDocument()
  let c = ?acceptContractSet(doc, opts = AcceptOptions(system: true))
  let m = c.primary.model
  let claim = m.find(ClaimType).valueOr:
    return err("no " & ClaimType)
  let p = m.find(ProfileType).valueOr:
    return err("no " & ProfileType)
  if p.body.kind != snLiteral or p.body.literal.kind != skTstr:
    return err(ProfileType & " is not a text literal")
  ok(ClaimSchema(set: c.schemaSet, claim: claim.body, profile: p.body.literal.text))

let claimSchema = block:
  let s = loadClaimSchema()
  doAssert s.isOk, "the pinned PM §4.3 / §5 claim schema does not load: " & s.error
  s.get

func claims(): ClaimSchema =
  {.cast(noSideEffect).}:
    claimSchema

func signingProfile*(): string =
  ## [SPEC PM §4.3] The profile identifier, read from the mirrored CDDL.
  claims().profile

func claimValue*(c: ManifestCommitment): CborValue =
  cborMap(
    (cbor("profile"), cbor(signingProfile())), (cbor("manifest_commitment"), c.toCbor)
  )

func claimPayload*(c: ManifestCommitment): Result[seq[byte], string] =
  ## [SPEC PM §4.3] The payload: the Logos deterministic-CBOR claim, checked
  ## against `package_signature_claim` before it is signed.
  let v = claimValue(c)
  let s = claims()
  s.set.validatePath(0, s.claim, v).isOkOr:
    return err("the claim does not match " & ClaimType)
  ok(encodeCbor(v))

# COSE_Sign1 ------------------------------------------------------------------------

func protectedHeader*(kid: openArray[byte]): seq[byte] =
  ## [SPEC PM §4.3] Exactly `alg` and `kid`, core deterministic.
  encodeCbor(
    cborMap(
      (cbor(CoseHeaderAlg), cbor(CoseAlgEd25519)), (cbor(CoseHeaderKid), cbor(@kid))
    )
  )

func sigStructure*(protectedBytes, payload: openArray[byte]): seq[byte] =
  ## [SPEC PM §4.3] RFC 9052 §4.4 `Sig_structure` for `Signature1`: the
  ## protected header bytes, a zero-length `external_aad`, the payload bytes.
  encodeCbor(
    cborArray(
      cbor(SignatureContext),
      cbor(@protectedBytes),
      cbor(newSeq[byte]()),
      cbor(@payload),
    )
  )

func encodeCoseSign1*(c: CoseSign1): seq[byte] =
  encodeCbor(
    cborTag(
      CoseSign1Tag,
      cborArray(cbor(c.protectedBytes), cborMap(), cbor(c.payload), cbor(c.signature)),
    )
  )

func unsignedCose*(kid, payload: openArray[byte]): (CoseSign1, seq[byte]) =
  ## The COSE_Sign1 for `payload` under `kid` before its signature, and the
  ## `Sig_structure` bytes to sign.
  let cose =
    CoseSign1(protectedBytes: protectedHeader(kid), kid: @kid, payload: @payload)
  (cose, sigStructure(cose.protectedBytes, cose.payload))

func toBeSigned*(
    m: Manifest, kid: openArray[byte]
): Result[(CoseSign1, seq[byte]), PackageError] =
  ## The unsigned object for `m` under `kid`, and the bytes to sign: what an
  ## external signer receives (`lcn-pkg sign --emit-tbs`).
  if kid.len < MinKidBytes or kid.len > MaxKidBytes:
    return err(packageError(pecInvalidRequest, "a kid is 1 to 128 bytes"))
  let c = ?m.commitment
  let payload = claimPayload(c).valueOr:
    return err(packageError(pecInvalidPackage, error))
  ok(unsignedCose(kid, payload))

proc signManifest*(
    m: Manifest, kid: openArray[byte], key: SigningKey
): Result[seq[byte], PackageError] =
  ## `manifest.cose` for `m`, signed with `key` under `kid`.
  var (cose, tbs) = ?toBeSigned(m, kid)
  cose.signature = key.sign(tbs)
  ok(encodeCoseSign1(cose))

func attachSignature*(
    m: Manifest, kid: openArray[byte], signature: openArray[byte]
): Result[seq[byte], PackageError] =
  ## `manifest.cose` from a signature made elsewhere over `toBeSigned`'s bytes
  ## (`lcn-pkg sign --attach-sig`). The signature is not checked here.
  if signature.len != SignatureLen:
    return err(packageError(pecInvalidRequest, "an Ed25519 signature is 64 bytes"))
  var (cose, _) = ?toBeSigned(m, kid)
  for i in 0 ..< SignatureLen:
    cose.signature[i] = signature[i]
  ok(encodeCoseSign1(cose))

func refuse(msg: string): PackageError =
  packageError(pecSignature, msg)

func decodeCoseSign1*(data: openArray[byte]): Result[CoseSign1, PackageError] =
  ## [SPEC PM §4.3] The structural checks: deterministic CBOR, tag 18, four
  ## elements, a protected header of exactly `alg` = -19 and a 1..128-byte
  ## `kid`, an empty unprotected header, an embedded payload, and a 64-byte
  ## signature. Every failure is `signature-verification-failed`.
  let v = decodeCbor(data).valueOr:
    return err(refuse("manifest.cose is not deterministic CBOR: " & $error))
  if v.kind != ckTag or v.tag != CoseSign1Tag:
    return err(refuse("manifest.cose is not a tagged COSE_Sign1"))
  let a = v.content
  if a.kind != ckArray or a.items.len != 4:
    return err(refuse("a COSE_Sign1 is an array of four elements"))
  let protectedBytes = a.items[0].getBytes.valueOr:
    return err(refuse("the protected header is not a byte string"))
  let h = decodeCbor(protectedBytes).valueOr:
    return err(refuse("the protected header is not deterministic CBOR: " & $error))
  if h.kind != ckMap or h.entries.len != 2:
    return err(refuse("the protected header holds exactly alg and kid"))
  let alg = h.lookup(CoseHeaderAlg)
  let kidValue = h.lookup(CoseHeaderKid)
  if alg.isNone or kidValue.isNone:
    return err(refuse("the protected header holds exactly alg and kid"))
  if alg.get.kind != ckNint or alg.get.nint != uint64(-1 - CoseAlgEd25519):
    return err(refuse("the algorithm is not -19 (Ed25519)"))
  let kid = kidValue.get.getBytes.valueOr:
    return err(refuse("the kid is not a byte string"))
  if kid.len < MinKidBytes or kid.len > MaxKidBytes:
    return err(refuse("the kid is not 1 to 128 bytes"))
  if a.items[1].kind != ckMap or a.items[1].entries.len != 0:
    return err(refuse("the unprotected header is not an empty map"))
  let payload = a.items[2].getBytes.valueOr:
    return err(refuse("the payload is missing or detached"))
  let sig = a.items[3].getBytes.valueOr:
    return err(refuse("the signature is not a byte string"))
  if sig.len != SignatureLen:
    return err(refuse("the signature is not 64 bytes"))
  var c = CoseSign1(protectedBytes: protectedBytes, kid: kid, payload: payload)
  for i in 0 ..< SignatureLen:
    c.signature[i] = sig[i]
  ok(c)

proc verifyPackage*(
    manifestCbor, manifestCose: openArray[byte], trust: TrustInput
): Result[VerifiedPackage, PackageError] =
  ## [SPEC PM §4, §4.1, §4.3] In order: the manifest decodes and validates
  ## (`invalid-package` otherwise); then, each failure being
  ## `signature-verification-failed`, the COSE structure, an accepted `kid`,
  ## the Ed25519 signature [IMPL-DECISION G42], the claim schema and profile,
  ## every commitment field against the commitment computed from
  ## `manifest.cbor`, and the signer's authorization for the exact package name.
  let m = ?decodeManifest(manifestCbor)
  let computed = ?m.commitment
  let cose = ?decodeCoseSign1(manifestCose)
  let anchor = trust.anchor(cose.kid).valueOr:
    return err(refuse("no accepted trust anchor has kid " & cose.kid.toHex))
  if not verify(
    anchor.key, sigStructure(cose.protectedBytes, cose.payload), cose.signature
  ):
    return err(refuse("the signature does not verify under kid " & cose.kid.toHex))
  let claim = decodeCbor(cose.payload).valueOr:
    return err(refuse("the claim is not Logos deterministic CBOR: " & $error))
  let s = claims()
  s.set.validatePath(0, s.claim, claim).isOkOr:
    return err(refuse("the claim does not match " & ClaimType))
  if claim.lookup("profile").get.getText.get != signingProfile():
    return err(refuse("the claim names another profile"))
  let signed = ManifestCommitment.fromCbor(claim.lookup("manifest_commitment").get).valueOr:
    return err(refuse("the claim's manifest commitment is malformed"))
  if signed != computed:
    return err(
      refuse(
        "the signed manifest commitment is not the one computed from manifest.cbor"
      )
    )
  let signer = trust.authorize(cose.kid, m.package).valueOr:
    return err(refuse("kid " & cose.kid.toHex & ": " & $error & " (" & m.package & ")"))
  ok(VerifiedPackage(manifest: m, commitment: computed, signer: signer))
