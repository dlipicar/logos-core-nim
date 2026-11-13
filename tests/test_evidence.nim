## Call evidence (step 8b-3; DECISIONS I85, plan cases E1-E6): the
## `logos.call-evidence.cose-sign1-slh-dsa-sha2-192s` profile (CA §9.1),
## producer and verifier, over synthetic `call` records of the meter kit
## contract, and the evidence key file. SLH-DSA-SHA2-192s signing is slow:
## four containers are signed and every other case reuses them or fails
## before a signature.

import std/[algorithm, os, posix, sequtils, strutils]
import unittest2
import ../src/logos_core/[cbor, commitment, hash]
import ../src/logos_core/iface/accept
import ../src/logos_core/crypto/[cose, slhdsa]
import ../src/logos_core/authority/scopes
import ../src/logos_core/runtime/evidence
from ../src/logos_core/package/signing import nil
import ./support/kitbuild

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "evidence" / kitVariant
removeDir(work)
createDir(work)

# A call record ------------------------------------------------------------------------

const
  Producer = "runtime-a"
  Kid = @[0x6B'u8, 0x31] # "k1"

let
  meterSet =
    acceptContractSet(readFile(repo / "spec/mirrors/IFC/3.9.1.module.cddl")).tryGet
  meterRoot = meterSet.primary.root
  meterModel = meterSet.primary.model

proc declRoot(name: string): seq[byte] =
  @(declarationRoot(meterModel, meterModel.find(name).get))

proc rootOf(declaration, diag: string): ValueRoot =
  meterSet.schemaSet.normalize(0, declaration, parseDiag(diag).get).tryGet

let
  request = rootOf("meter.read_request", "{\"channel\": 7}")
  response =
    rootOf("meter.read_response", "{\"label\": \"t\", \"reading\": {\"value\": 3}}")

proc commitmentOf(r: ValueRoot): ValueCommitment =
  ValueCommitment(
    schema_subtree_root: @(r.subtreeRoot), value_root: @(valueRoot(r).tryGet)
  )

proc callScope(methods = @[declRoot("meter.read")]): Scope =
  toScope(
    ProviderAccessScope(
      contract: SchemaCommitment(schema_root: @meterRoot),
      actions: @[PaAction(kind: PaActionKind.Call)],
      routes: Opt.some(@["route-1"]),
      providers: Opt.some(
        @[ProviderAddress(provider: "meter-1", runtime_instance_id: Opt.some(Producer))]
      ),
      access: Opt.some(RouteAccess(methods: Opt.some(methods))),
    )
  )

proc callRecord(
    scope = callScope(),
    requestSide = Opt.some(commitmentOf(request)),
    responseSide = Opt.some(commitmentOf(response)),
): AuditRecord =
  let c =
    if requestSide.isSome:
      LogosNSCapabilityAuthorityCallCommitments(
        kind: LogosNSCapabilityAuthorityCallCommitmentsKind.Map_request,
        arm_Map_request: LogosNSCapabilityAuthorityCallCommitmentsARMapRequestMap(
          request: requestSide.get, response: responseSide
        ),
      )
    else:
      LogosNSCapabilityAuthorityCallCommitments(
        kind: LogosNSCapabilityAuthorityCallCommitmentsKind.Map_response,
        arm_Map_response: LogosNSCapabilityAuthorityCallCommitmentsARMapResponseMap(
          response: responseSide.get
        ),
      )
  AuditRecord(
    kind: AuditKind.Call_success,
    arm_Call_success: LogosNSCapabilityAuthorityAuditRecordARCallSuccessMap(
      commitments: c,
      consumer: Address(runtime_instance_id: Producer, module_instance_id: "orch"),
      decision_id: "d-1",
      scopes: (scope,),
      timestamp: 1_000,
    ),
  )

# Proofs --------------------------------------------------------------------------------

proc proof(r: ValueRoot, path: openArray[Segment]): seq[byte] =
  encodeCbor(toCbor(viewOf(r, path).tryGet))

proc pathKey(p: seq[byte]): seq[byte] =
  encodeCbor(toCbor(parseView(decodeCbor(p).tryGet).tryGet.path))

proc ascending(ps: seq[seq[byte]]): seq[seq[byte]] =
  ## Ordered by the encoded semantic path, bytewise (CA l.1294-1296).
  ps.sorted(
    proc(a, b: seq[byte]): int =
      let (x, y) = (pathKey(a), pathKey(b))
      for i in 0 ..< min(x.len, y.len):
        if x[i] != y[i]:
          return cmp(x[i], y[i])
      cmp(x.len, y.len)
  )

let
  requestProofs =
    ascending(@[proof(request, []), proof(request, [fieldSegment("channel")])])
  responseProofs = ascending(
    @[
      proof(response, []),
      proof(response, [fieldSegment("label")]),
      proof(response, [fieldSegment("reading"), fieldSegment("value")]),
    ]
  )

proc proofs(
    request = Opt.none(seq[seq[byte]]), response = Opt.none(seq[seq[byte]])
): Opt[EvidenceProofs] =
  Opt.some(EvidenceProofs(request: request, response: response))

let defining = DefiningContract(
  schemaRoot: meterRoot,
  profileId: SpecProfile.profileId,
  suiteId: SpecProfile.suiteId,
  modelId: request.modelId,
  schema: ViewSchema(set: meterSet.schemaSet, doc: 0),
)

var asked: seq[(seq[byte], seq[byte])] ## what the resolver was asked

proc meterResolver(contract, declaration: seq[byte]): Opt[DefiningContract] =
  {.cast(gcsafe).}:
    asked.add((contract, declaration))
    if contract == @meterRoot and declaration == declRoot("meter.read"):
      Opt.some(defining)
    else:
      Opt.none(DefiningContract)

# Keys and the four containers ----------------------------------------------------------

proc seeded(x: byte): Seed =
  for i in 0 ..< N:
    result[i] = x + byte(i)

let
  (key, pub) = keyPairFromSeeds(seeded(1), seeded(40), seeded(80))
  (otherKey, otherPub) = keyPairFromSeeds(seeded(2), seeded(41), seeded(81))

proc context(
    producer = Producer, publicKey = pub, resolver: ContractResolver = meterResolver
): EvidenceContext =
  result = newEvidenceContext(resolver)
  check result.accept(Kid, producer, publicKey).isOk

proc signedDeterministic(payload: seq[byte]): seq[byte] =
  ## A container over `payload` with a deterministic signature.
  var (c, tbs) = cose.unsignedCose(Kid, payload, evidenceAad())
  c.signature = signDeterministic(key, tbs).tryGet
  encodeCoseSign1(c)

var signer = newEvidenceSigner(Kid, Producer, key).tryGet
let
  plain = signer.exportEvidence(callRecord()).tryGet # 1: hedged, no proofs
  withProofs = signedDeterministic(
    # 2: deterministic, both sides proved
    encode(
      buildClaim(
        Producer,
        callRecord(),
        proofs(Opt.some(requestProofs), Opt.some(responseProofs)),
      ).tryGet
    ).tryGet
  )
  otherRoots = signedDeterministic(
    # 3: a proof of another value than the one committed
    encode(
      buildClaim(
        Producer,
        callRecord(
          requestSide =
            Opt.some(commitmentOf(rootOf("meter.read_request", "{\"channel\": 8}")))
        ),
        proofs(Opt.some(@[proof(request, [fieldSegment("channel")])])),
      ).tryGet
    ).tryGet
  )
  otherProfile = block:
    # 4: a claim naming another profile, signed under this one
    var v = decodeCbor(encode(buildClaim(Producer, callRecord()).tryGet).tryGet).tryGet
    for e in v.entries.mitems:
      if e[0].getText.get("") == "profile":
        e[1] = cbor(signing.signingProfile())
    signedDeterministic(encodeCbor(v))
signer.clear()

func swapped(container: openArray[byte], f: proc(a: var CborValue)): seq[byte] =
  ## `container` with its COSE array changed by `f`, re-encoded.
  var v = decodeCbor(container).get
  {.cast(noSideEffect).}:
    f(v.content)
  encodeCbor(v)

# E1-E4 ------------------------------------------------------------------------------

suite "run.evidence: the container (CA §9.1 l.1219-1287)":
  test "[CAP-0216] [CAP-0222] [CAP-0223] [CAP-0225] [CAP-0394] [CAP-0396] [CAP-0403] [CAP-0404] [CAP-0406] [CAP-0407] a hedged and a deterministic container each verify: tag 18, a protected header of exactly kid, an empty unprotected header, the claim embedded, pure SLH-DSA-SHA2-192s with the empty context over the profile's external_aad":
    for c in [plain, withProofs]:
      let v = verifyEvidence(c, context())
      check v.isOk
      check v.get.kid == Kid
      check v.get.producer == Producer
      check encode(v.get.record).tryGet == encode(callRecord()).tryGet
      let d = decodeCbor(c).tryGet
      check d.kind == ckTag and d.tag == 18
      let s = decodeCoseSign1Structure(c).tryGet
      check s.protectedBytes == encodeCbor(cborMap((cbor(4'u64), cbor(Kid))))
      check d.content.items[1].entries.len == 0
      check s.payload == encode(EvidenceClaim.decode(s.payload).tryGet).tryGet
      check s.signature.len == SignatureBytes
      # [CAP-0396] [CAP-0404] The signed message is the Sig_structure with
      # the profile's bytes as external_aad, no prefix added to it.
      check evidenceAad() ==
        @("logos.call-evidence.cose-sign1-slh-dsa-sha2-192s".toOpenArrayByte(0, 47))
      check verify(
        pub, sigStructure(s.protectedBytes, s.payload, evidenceAad()), s.signature
      )
      check not verify(
        pub,
        sigStructure(s.protectedBytes, s.payload, signing.externalAad()),
        s.signature,
      )
    check verifyEvidence(plain, context()).get.proofs.isNone
    check verifyEvidence(withProofs, context()).get.proofs ==
      proofs(Opt.some(requestProofs), Opt.some(responseProofs))
    # [CAP-0406] Hedged signing fails when randomness fails.
    proc broken(dest: var openArray[byte]): bool =
      false

    check signEvidence(buildClaim(Producer, callRecord()).tryGet, Kid, key, broken).isErr
    check signEvidence(buildClaim(Producer, callRecord()).tryGet, @[], key).isErr

  test "[CAP-0224] [CAP-0395] [CAP-0408] [CAP-0414] a malformed or non-deterministic container, an alg header (even the fixed one), another header, a detached payload, a wrong signature length or a changed byte is rejected, nothing repaired":
    let ctx = context()
    proc rejects(c: openArray[byte]): bool =
      verifyEvidence(c, ctx).isErr

    let untagged = encodeCbor(decodeCbor(plain).get.content)
    check rejects(untagged)
    check rejects(
      plain.swapped(
        proc(a: var CborValue) =
          a.items[0] =
            cbor(encodeCbor(cborMap((cbor(1'u64), cbor(-1)), (cbor(4'u64), cbor(Kid)))))
      )
    )
    check rejects(
      plain.swapped(
        proc(a: var CborValue) =
          a.items[0] = cbor(
            encodeCbor(cborMap((cbor(4'u64), cbor(Kid)), (cbor(5'u64), cbor(@[0'u8]))))
          )
      )
    )
    check rejects(
      plain.swapped(
        proc(a: var CborValue) =
          a.items[1] = cborMap((cbor(4'u64), cbor(Kid)))
      )
    )
    check rejects(
      plain.swapped(
        proc(a: var CborValue) =
          a.items[2] = cborNull()
      )
    )
    check rejects(
      plain.swapped(
        proc(a: var CborValue) =
          a.items[3] = cbor(a.items[3].getBytes.get[0 ..< SignatureBytes - 1])
      )
    )
    check rejects(
      plain.swapped(
        proc(a: var CborValue) =
          a.items[3] = cbor(a.items[3].getBytes.get & @[0'u8])
      )
    )
    # A non-minimal length on the outer array: the same items, not
    # deterministic.
    var loose = plain
    let at = 1 # after the tag byte 0xD2
    check loose[at] == 0x84
    loose = loose[0 ..< at] & @[0x98'u8, 0x04] & loose[at + 1 .. ^1]
    check rejects(loose)
    # One flipped signature bit, one flipped payload bit.
    for i in [plain.len - 1, plain.len div 2]:
      var c = plain
      c[i] = c[i] xor 1
      check rejects(c)

  test "[CAP-0397] [CAP-0398] [CAP-0399] [CAP-0400] the verifier takes the profile, algorithm and external_aad from its own context; a claim naming another profile is rejected after verification, with no retry":
    # The container is signed correctly over this profile's Sig_structure; its
    # claim names the package-signing profile.
    let s = decodeCoseSign1Structure(otherProfile).tryGet
    check verify(
      pub, sigStructure(s.protectedBytes, s.payload, evidenceAad()), s.signature
    )
    let r = verifyEvidence(otherProfile, context())
    check r.isErr
    check "profile" in r.error or "call_evidence_claim" in r.error

  test "[CAP-0226] [CAP-0227] [CAP-0229] [CAP-0231] [CAP-0233] each accepted kid names one producer and one 48-byte key, once; an unknown or revoked kid, another key or another producer is rejected":
    var ctx = newEvidenceContext(meterResolver)
    check ctx.accept(Kid, Producer, pub).isOk
    check ctx.accept(Kid, Producer, otherPub).isErr
    check ctx.accept(Kid, "runtime-b", pub).isErr
    check ctx.accept(@[0x6B'u8, 0x32], Producer, pub[0 ..< 47]).isErr
    check ctx.accept(@[], Producer, pub).isErr
    check ctx.accept(newSeq[byte](129), Producer, pub).isErr
    check ctx.accept(@[0x6B'u8, 0x32], "", pub).isErr
    check verifyEvidence(plain, ctx).isOk
    ctx.revoke(Kid)
    check verifyEvidence(plain, ctx).isErr
    check verifyEvidence(plain, newEvidenceContext()).isErr
    check verifyEvidence(plain, context(publicKey = otherPub)).isErr
    let other = verifyEvidence(plain, context(producer = "runtime-b"))
    check other.isErr and "producer" in other.error

# E5-E6 -------------------------------------------------------------------------------

suite "run.evidence: the claim and its proofs (CA §9.1 l.1289-1316)":
  test "[CAP-0232] [CAP-0234] [CAP-0235] [CAP-0236] [CAP-0409] [CAP-0410] [CAP-0411] [CAP-0412] [CAP-0413] a claim holds one call record and, when present, proofs per side that are verified views in strictly ascending path order beside a commitment; nothing is sorted or deduplicated":
    check buildClaim(Producer, callRecord()).isOk
    check buildClaim("", callRecord()).isErr
    # [CAP-0232] Only a call record with one call scope.
    let policy = AuditRecord(
      kind: AuditKind.Policy_change_success,
      arm_Policy_change_success:
        LogosNSCapabilityAuthorityAuditRecordARPolicyChangeSuccessMap(timestamp: 1),
    )
    check buildClaim(Producer, policy).isErr
    check buildClaim(
      Producer, callRecord(callScope(@[declRoot("meter.read"), declRoot("meter.read")]))
    ).isErr
    # [CAP-0234] [CAP-0409] No empty proofs, no empty side.
    check buildClaim(Producer, callRecord(), proofs()).isErr
    check buildClaim(Producer, callRecord(), proofs(Opt.some(newSeq[seq[byte]]()))).isErr
    # [CAP-0412] The same path once on each side.
    check buildClaim(
      Producer,
      callRecord(),
      proofs(Opt.some(@[proof(request, [])]), Opt.some(@[proof(response, [])])),
    ).isOk
    # [CAP-0410] [CAP-0411] [CAP-0413] Order and duplicates, as received.
    check buildClaim(
      Producer, callRecord(), proofs(response = Opt.some(responseProofs.reversed))
    ).isErr
    check buildClaim(
      Producer, callRecord(), proofs(Opt.some(@[requestProofs[1], requestProofs[1]]))
    ).isErr
    # [CAP-0235] Each a verified view.
    check buildClaim(Producer, callRecord(), proofs(Opt.some(@[encodeCbor(cbor(1))]))).isErr
    # [CAP-0236] Beside a commitment on its side.
    check buildClaim(
      Producer,
      callRecord(responseSide = Opt.none(ValueCommitment)),
      proofs(response = Opt.some(@[proof(response, [])])),
    ).isErr
    check buildClaim(
      Producer,
      callRecord(requestSide = Opt.none(ValueCommitment)),
      proofs(Opt.some(@[proof(request, [])])),
    ).isErr

  test "[CAP-0237] [CAP-0238] [CAP-0239] [CAP-0240] each proof is checked against the method's defining contract, found from the signed call scope, and against the signed commitment, then verified as a view":
    asked = @[]
    check verifyEvidence(withProofs, context()).isOk
    check asked == @[(@meterRoot, declRoot("meter.read"))]
    # No resolver, or none for this method.
    check verifyEvidence(withProofs, context(resolver = nil)).isErr
    proc nothing(contract, declaration: seq[byte]): Opt[DefiningContract] =
      Opt.none(DefiningContract)

    check verifyEvidence(withProofs, context(resolver = nothing)).isErr
    # [CAP-0237] Another schema root, profile, suite or model.
    var variants: seq[DefiningContract]
    for i in 0 .. 3:
      var d = defining
      case i
      of 0:
        d.schemaRoot[0] = d.schemaRoot[0] xor 1
      of 1:
        d.profileId &= "x"
      of 2:
        d.suiteId &= "x"
      else:
        d.modelId &= "x"
      variants.add(d)
    for d in variants:
      {.cast(gcsafe).}:
        let only = d
        let r = verifyEvidence(
          withProofs,
          context(
            resolver = proc(c, m: seq[byte]): Opt[DefiningContract] =
              {.cast(gcsafe).}:
                Opt.some(only)
          ),
        )
        check r.isErr and "defining contract" in r.error
    # [CAP-0240] The view checked under a schema that is not its own.
    let foreign = acceptContractSet(
      "_module = \"other_module\"\n\nother.x = {\n  a: uint32,\n}\n"
    ).tryGet
    var wrongSchema = defining
    wrongSchema.schema = ViewSchema(set: foreign.schemaSet, doc: 0)
    let r = verifyEvidence(
      withProofs,
      context(
        resolver = proc(c, m: seq[byte]): Opt[DefiningContract] =
          {.cast(gcsafe).}:
            Opt.some(wrongSchema)
      ),
    )
    check r.isErr and "does not verify" in r.error
    # [CAP-0239] A proof of another value than the one committed.
    let mismatch = verifyEvidence(otherRoots, context())
    check mismatch.isErr and "roots" in mismatch.error

suite "run.evidence: the key (CA §9.1 l.1265-1287)":
  test "[CAP-0230] [CAP-0402] the evidence key file is an absolute path to a regular 96-byte file of this user's with mode 0600 whose public half its seeds derive":
    let path = work / "evidence.key"
    proc put(p: string, bytes: openArray[byte], mode = 0o600) =
      removeFile(p)
      writeFile(p, cast[string](@bytes))
      check chmod(cstring(p), Mode(mode)) == 0

    # [CAP-0402] A key from FIPS 205 key generation.
    var (generated, generatedPub) = generateKeyPair().tryGet
    put(path, generated)
    let loaded = loadEvidenceKey(path)
    check loaded.isOk
    check loaded.get == generated
    check publicKey(loaded.get) == generatedPub
    generated.clear()
    check generated == default(SecretKey)
    check loadEvidenceKey("evidence.key").isErr
    check loadEvidenceKey(work / "absent.key").isErr
    check loadEvidenceKey(work).isErr
    put(path, key, 0o644)
    check loadEvidenceKey(path).error.contains("0600")
    put(path, key, 0o400)
    check loadEvidenceKey(path).isErr
    put(path, key[0 ..< 95])
    check loadEvidenceKey(path).isErr
    put(path, @key & @[0'u8])
    check loadEvidenceKey(path).isErr
    var altered = key
    altered[95] = altered[95] xor 1
    put(path, altered)
    check loadEvidenceKey(path).error.contains("derive")
    put(path, key)
    let link = work / "link.key"
    removeFile(link)
    createSymlink(path, link)
    check loadEvidenceKey(path).isOk
    check loadEvidenceKey(link).isErr
