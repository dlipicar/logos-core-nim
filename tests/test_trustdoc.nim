## The package trust file, `logos-core-nim.trust.v2` (Tier 5 step 5-3a-2;
## DECISIONS G396, G398, G137; C2, C3; PACKAGE MANAGER l.401-449, l.733-745):
## its schema and the v1 it still reads, the rules beyond the schema, the
## selections, and the conversion to the package-signing trust input that
## `verifyPackage` uses. Continuity and logosd's start are `test_daemon_config`.

import std/[sequtils, strutils]
import unittest2
import logos_sdk/cbor
import ../src/logos_core/crypto/slhdsa
import ../src/logos_core/package/[records, signing, trustdoc]

# Fixtures --------------------------------------------------------------------------

proc bytesOf(s: string): seq[byte] =
  @(s.toOpenArrayByte(0, s.high))

proc testKey(fill: byte): (SecretKey, PublicKey) =
  ## A fixed SLH-DSA-SHA2-192s key pair (FIPS 205 `slh_keygen_internal`).
  var a, b, c: Seed
  for i in 0 ..< N:
    a[i] = byte(i * 3) xor fill
    b[i] = byte(i * 5) xor fill
    c[i] = byte(i * 7) xor fill
  keyPairFromSeeds(a, b, c)

proc anchorOf(
    kid: string, names: openArray[string], development = false, fill = 1'u8
): LcnTrustAnchor =
  LcnTrustAnchor(
    kid: bytesOf(kid),
    public_key: newSeqWith(PublicKeyBytes, fill),
    packages: @names,
    development: development,
  )

func withKey(a: LcnTrustAnchor, n: int): LcnTrustAnchor =
  result = a
  result.public_key = newSeq[byte](n)

proc docOf(
    anchors: openArray[LcnTrustAnchor], revision = 2'u64, development = false
): LcnPackageTrust =
  LcnPackageTrust(
    revision: revision,
    development: development,
    signing: LcnTrustSigning(anchors: @anchors),
  )

proc full(): LcnPackageTrust =
  ## Two anchors, one of them a development anchor, with the switch on.
  docOf(
    [
      anchorOf("dev", ["logos.example"], development = true, fill = 2),
      anchorOf("org", ["logos.storage", "logos.wallet"]),
    ],
    revision = 7,
    development = true,
  )

proc manifestValue(): CborValue =
  ## A package with no module and one data artifact.
  let data = cborMap(
    (cbor("id"), cbor("data")),
    (cbor("kind"), cbor("data")),
    (cbor("path"), cbor("data/example.bin")),
    (cbor("hash"), cbor(newSeq[byte](32))),
  )
  let platform =
    cborMap((cbor("os"), cbor("linux")), (cbor("architecture"), cbor("x86_64")))
  cborMap(
    (cbor("package"), cbor("logos.example")),
    (cbor("version"), cbor("1.0.0")),
    (cbor("modules"), cborArray()),
    (
      cbor("variants"),
      cborArray(
        cborMap(
          (cbor("id"), cbor("linux-x86_64")),
          (cbor("platform"), platform),
          (cbor("artifacts"), cborArray(data)),
        )
      ),
    ),
  )

proc `[]`(v: CborValue, key: string): CborValue =
  v.lookup(key).get

proc refusal(t: LcnPackageTrust): string =
  let r = checkTrust(t)
  if r.isOk: "" else: r.error

proc decoded(v: CborValue): Result[LcnPackageTrust, string] =
  decodeTrust(encodeCbor(v))

# Suites ----------------------------------------------------------------------------

suite "pkg.trustdoc: the package trust file's schema [IMPL-DECISION G396]":
  test "[C2] v2 round-trips byte for byte; an unknown field in any of its five maps is refused":
    let t = full()
    let bytes = t.encode.get
    check decodeTrust(bytes).get == t
    check decodeTrust(bytes).get.encode.get == bytes
    check t.toCbor["format"].getText == Opt.some(TrustFormat)
    for target in ["top", "signing", "anchor", "catalog", "provenance"]:
      checkpoint target
      let v = t.toCbor
      let m =
        case target
        of "top":
          v
        of "signing":
          v["signing"]
        of "anchor":
          v["signing"]["anchors"].items[0]
        else:
          v[target]
      m.entries.add((cbor("other"), cbor(1)))
      check "does not match lcn.package_trust" in decoded(v).error

  test "[C2] only deterministic CBOR within 1 MiB, the only bound, exported":
    var trailing = full().encode.get
    trailing.add(0x00)
    check "not deterministic CBOR" in decodeTrust(trailing).error
    check "not deterministic CBOR" in decodeTrust([0xFF'u8]).error
    check MaxTrustBytes == 1024 * 1024
    check decodeTrust(newSeq[byte](MaxTrustBytes + 1)).error == "larger than 1 MiB"
    # Another format identifier, or a v2 field in a v1 file, is not read.
    let v2 = full().toCbor
    v2.entries.keepItIf(it.key.getText != Opt.some("format"))
    v2.entries.add((cbor("format"), cbor("logos-core-nim.trust.v3")))
    check "does not match lcn.package_trust" in decoded(v2).error
    let v1 = LcnTrustFile(revision: 2, development: true).toCbor
    v1.entries.add((cbor("signing"), full().signing.toCbor))
    check "does not match lcn.trust_file" in decoded(v1).error

  test "the signing profile is the mirrored baseline profile, and the floor is revision 1 with nothing in it":
    check ("profile: \"" & signingProfile() & "\"") in trustdocDocuments()[0]
    let other = full().toCbor
    let s = other["signing"]
    s.entries.keepItIf(it.key.getText != Opt.some("profile"))
    s.entries.add((cbor("profile"), cbor("logos.package-signing.other")))
    check "does not match lcn.package_trust" in decoded(other).error
    let f = floorTrust()
    check f.revision == FloorRevision and FloorRevision == 1
    check not f.development and f.signing.anchors.len == 0
    check f.catalog.selected.isNone and f.provenance.selected.isNone
    check checkTrust(f).isOk and acceptedSigning(f).get.len == 0

  test "[I114] a v1 file reads as the v2 content with no anchor and nothing selected":
    for (revision, development) in [(1'u64, false), (2'u64, true)]:
      let v1 = LcnTrustFile(revision: revision, development: development).encode.get
      check decodeTrust(v1).get ==
        LcnPackageTrust(revision: revision, development: development)
    check decodeTrust(LcnTrustFile(revision: 1).encode.get).get == floorTrust()

suite "pkg.trustdoc: the rules beyond the schema [IMPL-DECISION G396]":
  test "[PKG-0107] [PKG-0072] [PKG-0434] the canonical form: kids and names strictly ascending, at least one name, 48-byte keys, names of 1 to 128 bytes":
    check refusal(full()) == ""
    let a = anchorOf("a", ["x"])
    let b = anchorOf("b", ["x"])
    check "not in strictly ascending kid order" in refusal(docOf([b, a]))
    check "not in strictly ascending kid order" in refusal(docOf([a, a]))
    # Byte order, not length first: "a" < "a\0" < "b".
    check refusal(docOf([a, anchorOf("a\0", ["x"]), b])) == ""
    check "authorizes no package name" in refusal(docOf([anchorOf("a", [])]))
    check "not in strictly ascending byte order" in
      refusal(docOf([anchorOf("a", ["y", "x"])]))
    check "not in strictly ascending byte order" in
      refusal(docOf([anchorOf("a", ["x", "x"])]))
    check "below the compiled-in floor" in refusal(docOf([], revision = 0))
    # The bounds are the schema's: a key of 47 or 49 bytes, a name or kid of
    # 129 bytes, an empty kid or name.
    for bad in [
      anchorOf("a", ["x"]).withKey(47),
      anchorOf("a", ["x"]).withKey(49),
      anchorOf("a", [repeat('n', 129)]),
      anchorOf(repeat('k', 129), ["x"]),
      anchorOf("", ["x"]),
      anchorOf("a", [""]),
    ]:
      check "does not match lcn.package_trust" in decoded(docOf([bad]).toCbor).error
    check decoded(docOf([anchorOf("a", [repeat('n', 128)])]).toCbor).isOk
    # Two kids may share a key; only a shared kid is refused (PKG-0107).
    check refusal(
      docOf([anchorOf("a", ["x"], fill = 9), anchorOf("b", ["x"], fill = 9)])
    ) == ""

  test "[PKG-0071] [PKG-0073] exact names: byte equality, no folding or normalization, no special name":
    let composed = "café"
    let decomposed = "café"
    let t =
      docOf([anchorOf("org", ["*", "Storage_Module", decomposed])], development = false)
    check checkTrust(t).isOk
    let input = acceptedSigning(t).get
    check input.authorize(bytesOf("org"), "Storage_Module").isOk
    check input.authorize(bytesOf("org"), decomposed).isOk
    check input.authorize(bytesOf("org"), "*").isOk
    for other in [
      "storage_module", "STORAGE_MODULE", composed, "logos.storage", "**", ""
    ]:
      checkpoint other
      check input.authorize(bytesOf("org"), other).error == trNotAuthorized

  test "[IMPL-DECISION G137] [BCP-0094] [BCP-0103] a development anchor is in force only while the switch is on":
    let on = full()
    var off = on
    off.development = false
    let dev = on.signing.anchors[0]
    let org = on.signing.anchors[1]
    check on.inForce(dev) and on.inForce(org)
    check not off.inForce(dev) and off.inForce(org)
    let withSwitch = acceptedSigning(on).get
    let without = acceptedSigning(off).get
    check withSwitch.len == 2 and without.len == 1
    check withSwitch.authorize(bytesOf("dev"), "logos.example").isOk
    check without.authorize(bytesOf("dev"), "logos.example").error == trUnknownKid
    check without.authorize(bytesOf("org"), "logos.wallet").isOk

suite "pkg.trustdoc: catalog and provenance selections [IMPL-DECISION G398]":
  test "[C3] [PKG-0169] [PKG-0467] a selection is decoded, then refused naming it; both sections empty are accepted":
    var cat = full()
    cat.catalog.selected = Opt.some("logos.catalog.some-profile")
    let c = decodeTrust(cat.encode.get).get # decoded: `trust show` reads it
    check c.catalog.selected == Opt.some("logos.catalog.some-profile")
    check refusal(c) ==
      "this implementation supports no catalog profile; the file selects \"logos.catalog.some-profile\""
    var prov = full()
    prov.provenance.selected = Opt.some("logos.package-provenance.slsa-v1.2")
    let p = decodeTrust(prov.encode.get).get
    check refusal(p) ==
      "this implementation supports no provenance profile; the file selects \"logos.package-provenance.slsa-v1.2\""
    check acceptedSigning(p).error == refusal(p) # no conversion of a refused file
    # [PM l.736] The absence of a selection is stated: the sections are required.
    let both = full()
    check both.catalog.selected.isNone and both.provenance.selected.isNone
    check checkTrust(both).isOk
    for section in ["catalog", "provenance"]:
      checkpoint section
      let v = both.toCbor
      v.entries.keepItIf(it.key.getText != Opt.some(section))
      check "does not match lcn.package_trust" in decoded(v).error

  test "[PKG-0166] only the trust file selects a provenance profile":
    # A source's provenance locator is location data: it selects nothing
    # (PM l.862), and no rule or conversion takes a source.
    let entry = decodeCatalogEntry(
      cborMap(
        (
          cbor("identity"),
          cborMap(
            (cbor("package"), cbor("logos.example")), (cbor("version"), cbor("1.0.0"))
          ),
        ),
        (
          cbor("source"),
          cborMap(
            (cbor("kind"), cbor("lgx")),
            (cbor("storage"), cbor("main")),
            (cbor("object"), cbor(bytesOf("archive"))),
            (cbor("provenance_object"), cbor(bytesOf("provenance"))),
          ),
        ),
      )
    ).get
    check entry.source.provenanceLocator == Opt.some(bytesOf("provenance"))
    let t = full()
    check t.provenance.selected.isNone and checkTrust(t).isOk
    # A manifest cannot carry a selection: an added field is refused.
    let m = decodeManifest(encodeCbor(manifestValue())).get
    let v = decodeCbor(m.encoded).get
    v.entries.add((cbor("provenance"), cbor("logos.package-provenance.slsa-v1.2")))
    check $decodeManifest(encodeCbor(v)).error.code == "invalid-package"

suite "pkg.trustdoc: the accepted file feeds verification [IMPL-DECISION G396]":
  let (orgKey, orgPub) = testKey(1)
  let (devKey, devPub) = testKey(2)
  let t = docOf(
    [
      LcnTrustAnchor(
        kid: bytesOf("dev"),
        public_key: @devPub,
        packages: @["logos.example"],
        development: true,
      ),
      LcnTrustAnchor(
        kid: bytesOf("org"), public_key: @orgPub, packages: @["logos.other"]
      ),
    ],
    development = true,
  )
  let m = decodeManifest(encodeCbor(manifestValue())).get
  let byOrg = signManifest(m, bytesOf("org"), orgKey).get
  let byDev = signManifest(m, bytesOf("dev"), devKey).get

  proc outcome(cose: seq[byte], t: LcnPackageTrust): string =
    let r = verifyPackage(m.encoded, cose, acceptedSigning(t).get)
    if r.isOk:
      "ok"
    else:
      checkpoint r.error.msg
      $r.error.code

  test "[PKG-0074] [PKG-0075] a package verifies under a file anchor that names it, and not under one that does not":
    check outcome(byOrg, t) == "signature-verification-failed" # logos.other only
    var named = t
    named.signing.anchors[1].packages = @["logos.example", "logos.other"]
    check outcome(byOrg, named) == "ok"

  test "[PKG-0083] [BCP-0103] a development anchor verifies with the switch on, and not with it off":
    check outcome(byDev, t) == "ok"
    var off = t
    off.development = false
    check outcome(byDev, off) == "signature-verification-failed"
