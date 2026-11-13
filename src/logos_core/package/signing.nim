## PM §4, §4.1, §4.3: the `logos.package-signing.cose-sign1-slh-dsa-sha2-192s`
## profile. `manifest.cose` is a tagged COSE_Sign1 (RFC 9052) whose embedded
## payload is the Logos deterministic-CBOR signature claim; the protected header
## holds exactly `kid`. The algorithm is implicit and fixed (RFC 9052 App. A):
## pure SLH-DSA-SHA2-192s (FIPS 205) with the zero-length context over the
## `Sig_structure`, whose `external_aad` is the profile identifier. Nothing in
## the received object selects the algorithm, the profile or the context. The
## structure is `crypto/cose.nim`'s, shared with call evidence (I85).
##
## The claim schema is the mirrored PM §4.3 block plus the
## `logos.package_manager.manifest_commitment` rule cut from the mirrored PM §5
## block, accepted as one supporting schema.

{.push raises: [].}

import std/strutils
import results
import ../base/[hex, perthread]
import ../cbor
import ../cddl/syntax
import ../commitment
import ../hash
import ../iface/accept
import ../crypto/[cose, slhdsa]
import ./[errors, manifest, trust]

export results, errors, manifest, trust
export
  CoseSign1, CoseSign1Tag, CoseHeaderAlg, CoseHeaderKid, SignatureContext,
  protectedHeader, encodeCoseSign1

const
  ClaimType* = "logos.package_manager.package_signature_claim"
  ProfileType* = "logos.package_manager.package_signing_profile"
  CommitmentType* = "logos.package_manager.manifest_commitment"
  SignerType* = "logos.package_manager.package_signer"

type VerifiedPackage* = object ## A manifest whose signature PM §4.1 and §4.3 accept.
  manifest*: Manifest
  commitment*: ManifestCommitment
  signer*: TrustAnchor

# The claim schema ------------------------------------------------------------------

type ClaimSchema = ref object
  set: SchemaSet
  claim: SchemaNode
  signer: SchemaNode
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
  let signer = m.find(SignerType).valueOr:
    return err("no " & SignerType)
  let p = m.find(ProfileType).valueOr:
    return err("no " & ProfileType)
  if p.body.kind != snLiteral or p.body.literal.kind != skTstr:
    return err(ProfileType & " is not a text literal")
  ok(
    ClaimSchema(
      set: c.schemaSet,
      claim: claim.body,
      signer: signer.body,
      profile: p.body.literal.text,
    )
  )

proc loadPinnedClaimSchema(): ClaimSchema =
  let s = loadClaimSchema()
  doAssert s.isOk, "the pinned PM §4.3 / §5 claim schema does not load: " & s.error
  s.get

perThread(claimSchema, ClaimSchema, loadPinnedClaimSchema())
discard claimSchema()

func claims(): ClaimSchema =
  {.cast(noSideEffect).}:
    claimSchema()

func signingProfile*(): string =
  ## [SPEC PM §4.3] The profile identifier, read from the mirrored CDDL.
  claims().profile

func externalAad*(): seq[byte] =
  ## [SPEC PM §4.3] The `Sig_structure`'s `external_aad`: the UTF-8 bytes of
  ## the profile identifier, from this verifier's own context.
  let p = signingProfile()
  @(p.toOpenArrayByte(0, p.high))

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

func sigStructure*(protectedBytes, payload: openArray[byte]): seq[byte] =
  ## [SPEC PM §4.3] RFC 9052 §4.4 `Sig_structure` for `Signature1` with the
  ## profile identifier as `external_aad`.
  cose.sigStructure(protectedBytes, payload, externalAad())

func unsignedCose*(kid, payload: openArray[byte]): (CoseSign1, seq[byte]) =
  ## The COSE_Sign1 for `payload` under `kid` before its signature, and the
  ## `Sig_structure` bytes to sign.
  cose.unsignedCose(kid, payload, externalAad())

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
    m: Manifest, kid: openArray[byte], key: SecretKey, random: RandomSource = osRandom
): Result[seq[byte], PackageError] =
  ## `manifest.cose` for `m`, signed with `key` under `kid`: pure
  ## SLH-DSA-SHA2-192s, hedged with fresh bytes from `random`, failing when it
  ## cannot supply them [SPEC PM §4.3]. The signature is checked against the
  ## key's own public key before it is returned [IMPL].
  var (cose, tbs) = ?toBeSigned(m, kid)
  let sig = sign(key, tbs, random = random).valueOr:
    return err(packageError(pecInvalidRequest, "signing failed: " & error))
  if not verify(publicKey(key), tbs, sig):
    return err(
      packageError(pecInvalidRequest, "the signature does not verify under the key")
    )
  cose.signature = sig
  ok(encodeCoseSign1(cose))

func attachSignature*(
    m: Manifest, kid: openArray[byte], signature: openArray[byte]
): Result[seq[byte], PackageError] =
  ## `manifest.cose` from a signature made elsewhere over `toBeSigned`'s bytes
  ## (`lcn-pkg sign --attach-sig`). The signature is not checked here.
  if signature.len != SignatureBytes:
    return err(
      packageError(pecInvalidRequest, "an SLH-DSA-SHA2-192s signature is 16224 bytes")
    )
  var (cose, _) = ?toBeSigned(m, kid)
  cose.signature = @signature
  ok(encodeCoseSign1(cose))

func refuse(msg: string): PackageError =
  packageError(pecSignature, msg)

func packageRefusal(f: CoseFailure): PackageError =
  refuse(
    case f.kind
    of ceNotCbor:
      "manifest.cose is not deterministic CBOR: " & f.detail
    of ceNotTagged:
      "manifest.cose is not a tagged COSE_Sign1"
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
  )

func decodeCoseSign1*(data: openArray[byte]): Result[CoseSign1, PackageError] =
  ## [SPEC PM §4.3] The structural checks (`decodeCoseSign1Structure`): every
  ## failure is `signature-verification-failed`.
  let c = decodeCoseSign1Structure(data).valueOr:
    return err(packageRefusal(error))
  ok(c)

proc verifyPackage*(
    manifestCbor, manifestCose: openArray[byte], trust: TrustInput
): Result[VerifiedPackage, PackageError] =
  ## [SPEC PM §4, §4.1, §4.3] In order: the manifest decodes and validates
  ## (`invalid-package` otherwise); then, each failure being
  ## `signature-verification-failed`, the COSE structure, an accepted `kid`,
  ## the SLH-DSA-SHA2-192s signature under that kid's key (FIPS 205 `slh_verify`
  ## with the zero-length context, no retry), the claim schema and profile,
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

func signerRecord*(v: VerifiedPackage): CborValue =
  ## [SPEC PM §4.3] The `package_signer` record of the verification that
  ## accepted `v`: the profile and the exact public-key bytes, not the kid.
  ## Retaining it with installed state and reporting it in inspections and
  ## handoffs is the Package Manager's (tier 5).
  let r = cborMap(
    (cbor("profile"), cbor(signingProfile())),
    (cbor("public_key"), cbor(@(v.signer.key))),
  )
  let s = claims()
  doAssert s.set.validatePath(0, s.signer, r).isOk, "package_signer drifted"
  r
