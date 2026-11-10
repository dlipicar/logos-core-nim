## HASH §6, §7.1: domain-separated hash inputs and the BLAKE3-256 suite.
##
## Every digest is BLAKE3-256 over the deterministic CBOR encoding of
## `{0: domain tag, 1: hash profile id, 2: hash suite id, 3: commitment-model
## revision, 4: payload}` [SPEC HASH §6]. The three ids are the spec's pinned
## values (`pins.nim`), carried in a `HashProfile` so a verifier can be handed
## another profile and reject what it does not know.

{.push raises: [].}

import ../[cbor, pins]
import ../crypto/blake3

export cbor

const DigestLen* = Blake3OutLen ## [SPEC HASH §6.1] 32 bytes

type
  Digest* = array[DigestLen, byte]
    ## A BLAKE3-256 digest; also the type of schema roots and subtree roots.

  HashProfile* = object
    profileId*: string
    suiteId*: string
    modelId*: string ## the semantic commitment-model revision

  Domain* = enum
    ## Hash domain tags: COMMITMENT §6 schema domains and HASH §5 value domains.
    dSchemaRoot = "logos.schema.root"
    dSchemaNode = "logos.schema.node"
    dSchemaLeaf = "logos.schema.leaf"
    dSchemaReference = "logos.schema.reference"
    dValueRoot = "logos.value.root"
    dMap = "logos.value.map"
    dField = "logos.value.field"
    dAbsent = "logos.value.absent"
    dList = "logos.value.list"
    dListChunk = "logos.value.list-chunk"
    dPackedChunk = "logos.value.packed-scalar-list-chunk"
    dTuple = "logos.value.tuple"
    dTupleElement = "logos.value.tuple-element"
    dChoice = "logos.value.choice"
    dScalar = "logos.value.scalar"
    dBstr = "logos.value.bstr"
    dBstrDirect = "logos.value.bstr-direct"
    dBstrChunk = "logos.value.bstr-chunk"
    dTstr = "logos.value.tstr"
    dTstrDirect = "logos.value.tstr-direct"
    dTstrChunk = "logos.value.tstr-chunk"
    dReference = "logos.value.reference"
    dBranch = "logos.value.branch"

const SpecProfile* = HashProfile(
  profileId: HashProfileId, suiteId: HashSuiteId, modelId: CommitmentModelId
) ## The only profile this implementation produces [SPEC HASH §2, §6.1].

func parseDomain*(tag: string): Opt[Domain] =
  for d in Domain:
    if $d == tag:
      return Opt.some(d)
  Opt.none(Domain)

func cbor*(d: Digest): CborValue =
  cbor(d.toOpenArray(0, d.high))

func toDigest*(v: CborValue): Opt[Digest] =
  ## A byte string of exactly 32 bytes [SPEC HASH §6: other lengths are rejected].
  if v.kind != ckBytes or v.bytes.len != DigestLen:
    return Opt.none(Digest)
  var d: Digest
  for i in 0 ..< DigestLen:
    d[i] = v.bytes[i]
  Opt.some(d)

func hashInput*(domain: Domain, payload: CborValue, profile = SpecProfile): CborValue =
  ## [SPEC HASH §6, §7.1] The canonical hash input record.
  cborMap(
    (cbor(0'u64), cbor($domain)),
    (cbor(1'u64), cbor(profile.profileId)),
    (cbor(2'u64), cbor(profile.suiteId)),
    (cbor(3'u64), cbor(profile.modelId)),
    (cbor(4'u64), payload),
  )

func digestOfInput*(encoded: openArray[byte]): Digest =
  ## [SPEC HASH §6.1] Plain unkeyed BLAKE3, first 32 bytes of output.
  blake3(encoded)

func digestOf*(domain: Domain, payload: CborValue, profile = SpecProfile): Digest =
  ## The digest of `payload` under `domain`: BLAKE3-256 of the deterministic
  ## CBOR encoding of its hash input [SPEC HASH §6].
  digestOfInput(encodeCbor(hashInput(domain, payload, profile)))
