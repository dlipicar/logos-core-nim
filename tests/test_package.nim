## PM §3, §4, §4.1, §4.3, §5, §8, §9, §11, §14: the package manifest, its value
## commitment, package-signing trust input and the COSE_Sign1 profile.

import std/[algorithm, json, os, sequtils, strutils]
import unittest2
import ../src/logos_core/base/hex
import ../src/logos_core/[cbor, commitment, hash, pins]
import ../src/logos_core/iface/accept
import ../src/logos_core/cddl/syntax
import ../src/logos_core/package/[semver, signing]
import ./support/specdata

# Fixtures --------------------------------------------------------------------------

proc commitmentValue(fill: byte): CborValue =
  ## A `logos.schema_commitment` with an arbitrary root.
  cborMap(
    (cbor("commitment_model"), cbor(CommitmentModelId)),
    (cbor("schema_root"), cbor(newSeqWith(32, fill))),
    (cbor("hash_profile"), cbor(HashProfileId)),
    (cbor("hash_suite"), cbor(HashSuiteId)),
  )

proc byBytes(xs: seq[CborValue]): seq[CborValue] =
  xs.sorted(
    proc(a, b: CborValue): int =
      cmpBytes(encodeCbor(a), encodeCbor(b))
  )

proc artifact(id, kind, path: string, fill = 0'u8): CborValue =
  cborMap(
    (cbor("id"), cbor(id)),
    (cbor("kind"), cbor(kind)),
    (cbor("path"), cbor(path)),
    (cbor("hash"), cbor(newSeqWith(32, fill))),
  )

proc platform(os = "", arch = "", abi = ""): CborValue =
  var entries: seq[CborEntry]
  if os.len > 0:
    entries.add((cbor("os"), cbor(os)))
  if arch.len > 0:
    entries.add((cbor("architecture"), cbor(arch)))
  if abi.len > 0:
    entries.add((cbor("abi"), cbor(abi)))
  cborMap(entries)

proc variant(id: string, p: CborValue, artifacts: seq[CborValue]): CborValue =
  cborMap(
    (cbor("id"), cbor(id)),
    (cbor("platform"), p),
    (cbor("artifacts"), cborArray(artifacts)),
  )

proc base(): CborValue =
  ## A manifest using every field: two modules, two variants, two dependencies.
  let alpha = cborMap(
    (cbor("module"), cbor("alpha_module")),
    (cbor("artifact"), cbor("alpha")),
    (cbor("primary_contract"), commitmentValue(1)),
    (cbor("implements"), cborArray(byBytes(@[commitmentValue(2), commitmentValue(3)]))),
    (
      cbor("requires"),
      cborArray(
        cborMap(
          (cbor("contract"), commitmentValue(4)), (cbor("cardinality"), cbor("single"))
        )
      ),
    ),
    (
      cbor("requested_permissions"),
      cborArray(
        cborMap(
          (cbor("permission"), cbor("logos.storage.read")),
          (cbor("constraints"), cbor(encodeCbor(cborMap()))),
          (cbor("reason"), cbor("caches blocks")),
        ),
        cborMap(
          (cbor("permission"), cbor("logos.storage.write")),
          (cbor("constraints"), cbor(encodeCbor(cborMap()))),
        ),
      ),
    ),
    (
      cbor("configuration"),
      cborMap(
        (cbor("schema_artifact"), cbor("alpha-config")),
        (cbor("root"), cbor("alpha_config")),
        (cbor("schema_commitment"), commitmentValue(5)),
        (cbor("default_artifact"), cbor("alpha-defaults")),
        (cbor("live_reconfiguration"), cbor(true)),
      ),
    ),
  )
  let beta =
    cborMap((cbor("module"), cbor("beta_module")), (cbor("artifact"), cbor("beta")))
  let linux = variant(
    "linux-x86_64",
    platform("linux", "x86_64", "gnu"),
    @[
      artifact("alpha", "module-binary", "lib/libalpha.so", 1),
      artifact("alpha-config", "schema", "schema/alpha.cddl", 2),
      artifact("alpha-defaults", "data", "data/alpha.cbor", 3),
      artifact("beta", "module-binary", "lib/libbeta.so", 4),
    ],
  )
  let darwin = variant(
    "darwin-aarch64",
    platform("darwin", "aarch64"),
    @[
      artifact("alpha", "module-binary", "lib/libalpha.dylib", 5),
      artifact("alpha-config", "schema", "schema/alpha.cddl", 2),
      artifact("alpha-defaults", "data", "data/alpha.cbor", 3),
    ],
  )
  cborMap(
    (cbor("package"), cbor("logos.example")),
    (cbor("version"), cbor("1.2.3")),
    (cbor("modules"), cborArray(alpha, beta)),
    (cbor("variants"), cborArray(linux, darwin)),
    (
      cbor("dependencies"),
      cborArray(
        cborMap(
          (cbor("package"), cbor("logos.base")),
          (
            cbor("requirement"),
            cborMap(
              (cbor("kind"), cbor("compatible")), (cbor("version"), cbor("1.0.0"))
            ),
          ),
        ),
        cborMap(
          (cbor("package"), cbor("logos.util")),
          (
            cbor("requirement"),
            cborMap(
              (cbor("kind"), cbor("exact")), (cbor("version"), cbor("0.3.0-rc.1"))
            ),
          ),
        ),
      ),
    ),
  )

proc `[]`(v: CborValue, key: string): CborValue =
  v.lookup(key).get

proc put(m: CborValue, key: string, x: CborValue) =
  for e in m.entries.mitems:
    if e.key.getText == Opt.some(key):
      e.value = x
      return
  m.entries.add((cbor(key), x))

proc drop(m: CborValue, key: string) =
  m.entries.keepItIf(it.key.getText != Opt.some(key))

proc verdict(v: CborValue): string =
  let r = decodeManifest(encodeCbor(v))
  if r.isOk:
    "ok"
  else:
    checkpoint r.error.msg
    if existsEnv("LCN_TEST_TRACE"):
      echo "    ", r.error.msg
    $r.error.code

proc mutated(f: proc(m: CborValue)): string =
  let m = base()
  f(m)
  verdict(m)

proc alpha(m: CborValue): CborValue =
  m["modules"].items[0]

proc linux(m: CborValue): CborValue =
  m["variants"].items[0]

proc seed(fill: byte): Seed =
  var s: Seed
  for i in 0 ..< SeedLen:
    s[i] = fill
  s

proc bytesOf(s: string): seq[byte] =
  @(s.toOpenArrayByte(0, s.high))

# Suites ----------------------------------------------------------------------------

suite "pkg.manifest: the PM §4 schema and the manifest value commitment":
  test "[PKG-0035] [PKG-0036] [PKG-0037] [PKG-0038] [PKG-0039] [PKG-0040] [PKG-0041] [PKG-0042] [PKG-0043] [PKG-0044] [PKG-0045] [PKG-0046] [PKG-0047] [PKG-0048] [PKG-0049] [PKG-0050] [PKG-0051] [PKG-0052] the mirrored CDDL is a supporting schema with the pinned roots":
    let c = manifestContracts()
    check c.primary.model.namespace == ManifestNamespace
    check c.primary.root.toHex == pin("pkg-manifest-schema-root")
    let d = c.primary.model.find(ManifestType).get
    check declarationRoot(c.primary.model, d).toHex == pin("pkg-manifest-subtree-root")

  test "[PKG-0027] [PKG-0028] [PKG-0029] [PKG-0258] a manifest using every field decodes":
    let m = decodeManifest(encodeCbor(base()))
    check m.isOk
    let x = m.get
    check x.package == "logos.example"
    check x.modules.mapIt(it.module) == @["alpha_module", "beta_module"]
    check x.variants.mapIt(it.id) == @["linux-x86_64", "darwin-aarch64"]
    check x.variants[0].platform.abi == Opt.some("gnu")
    check x.variants[1].platform.abi.isNone
    check x.modules[0].configuration.get.liveReconfiguration
    check x.modules[0].requestedPermissions[0].reason == Opt.some("caches blocks")
    check x.dependencies[1].kind == rkExact
    check x.encoded == encodeCbor(base())

  test "[PKG-0256] [PKG-0258] values outside the CDDL are invalid-package":
    check mutated(
      proc(m: CborValue) =
        m.put("extra", cbor(1))
    ) == "invalid-package"
    check mutated(
      proc(m: CborValue) =
        m.drop("modules")
    ) == "invalid-package"
    check mutated(
      proc(m: CborValue) =
        m.put("package", cbor(""))
    ) == "invalid-package"
    check mutated(
      proc(m: CborValue) =
        m.put("package", cbor("p".repeat(129)))
    ) == "invalid-package"
    check mutated(
      proc(m: CborValue) =
        m.linux["artifacts"].items[0].put("kind", cbor("exe"))
    ) == "invalid-package"
    check mutated(
      proc(m: CborValue) =
        m.linux["artifacts"].items[0].put("hash", cbor(newSeq[byte](31)))
    ) == "invalid-package"
    check mutated(
      proc(m: CborValue) =
        m.linux["platform"].put("cpu", cbor("x"))
    ) == "invalid-package"
    check mutated(
      proc(m: CborValue) =
        m.alpha["configuration"].put("live_reconfiguration", cbor(false))
    ) == "invalid-package"

  test "[IMPL-DECISION G156] an artifact without its hash fails the manifest CDDL: invalid-package":
    # PM §8 l.1000 names artifact-integrity-failed, but the §4 CDDL requires the
    # field, and §8 l.974 makes a CDDL failure invalid-package (reported as NP-15).
    check mutated(
      proc(m: CborValue) =
        m.linux["artifacts"].items[0].drop("hash")
    ) == "invalid-package"

  test "[PKG-0257] [PKG-0027] non-deterministic CBOR is invalid-package":
    var b = encodeCbor(base())
    check b[0] == 0xa5
    var long = @[0xb8'u8, 0x05] & b[1 .. ^1] # a non-shortest map head
    check decodeManifest(long).error.code == pecInvalidPackage
    check decodeManifest(b & @[0x00'u8]).error.code == pecInvalidPackage

  test "[PKG-0030] the 4 MiB bound is the pinned one":
    check pin("pkg-manifest-max-size") == "4 MiB"
    check MaxManifestBytes == 4 * 1024 * 1024
    let big = base()
    big.alpha["requested_permissions"].items[0].put(
      "constraints", cbor(encodeCbor(cbor(newSeq[byte](MaxManifestBytes))))
    )
    let r = decodeManifest(encodeCbor(big))
    check r.error.code == pecInvalidPackage
    check "4 MiB" in r.error.msg

  test "[PKG-0061] [PKG-0062] [PKG-0063] [PKG-0064] [PKG-0065] the commitment binds the model, both pinned roots and the value root":
    let m = decodeManifest(encodeCbor(base())).get
    let c = m.commitment.get
    check c.commitmentModel == pin("commitment-model-id")
    check c.schemaRoot.toHex == pin("pkg-manifest-schema-root")
    check c.schemaSubtreeRoot.toHex == pin("pkg-manifest-subtree-root")
    check c.hashProfile == pin("hash-profile-id")
    check c.hashSuite == pin("hash-suite-id")
    let r = manifestContracts().schemaSet.normalize(0, ManifestType, base()).get
    check c.valueRoot == valueRoot(r).get
    let other = base()
    other.put("version", cbor("1.2.4"))
    check decodeManifest(encodeCbor(other)).get.commitment.get.valueRoot != c.valueRoot
    check ManifestCommitment.fromCbor(c.toCbor) == Opt.some(c)

suite "pkg.validation: the manifest rules beyond the CDDL (PM §5, §8, §9, §11)":
  test "[PKG-0173] [PKG-0174] variants and each variant's artifacts are non-empty":
    check mutated(
      proc(m: CborValue) =
        m.put("variants", cborArray())
    ) == "invalid-package"
    check mutated(
      proc(m: CborValue) =
        m.linux.put("artifacts", cborArray())
    ) == "invalid-package"

  test "[PKG-0175] [PKG-0176] [PKG-0260] versions are SemVer 2.0.0 without v or build metadata":
    for b in [
      "v1.2.3", "1.2", "1.2.3+build.5", "01.2.3", "1.2.3-", "1.2.3-a..b", "1.2.3-01"
    ]:
      let bad = b
      checkpoint bad
      check mutated(
        proc(m: CborValue) =
          m.put("version", cbor(bad))
      ) == "invalid-package"
    for g in ["0.0.0", "1.2.3-alpha.1", "10.20.30-rc.1.x-y", "18446744073709551616.0.0"]:
      let good = g
      checkpoint good
      check mutated(
        proc(m: CborValue) =
          m.put("version", cbor(good))
      ) == "ok"
    check mutated(
      proc(m: CborValue) =
        m["dependencies"].items[0]["requirement"].put("version", cbor("1.0"))
    ) == "invalid-package"

  test "[PKG-0298] a compatible requirement names no pre-release; an exact one may":
    check mutated(
      proc(m: CborValue) =
        m["dependencies"].items[0]["requirement"].put("version", cbor("1.0.0-rc.1"))
    ) == "invalid-package"
    check verdict(base()) == "ok" # logos.util requires exactly 0.3.0-rc.1

  test "[PKG-0261] [PKG-0262] [PKG-0057] variant ids and artifact ids are unique; artifacts are in id order":
    check mutated(
      proc(m: CborValue) =
        m["variants"].items[1].put("id", cbor("linux-x86_64"))
    ) == "invalid-package"
    check mutated(
      proc(m: CborValue) =
        m.linux["artifacts"].items[1].put("id", cbor("alpha"))
    ) == "invalid-package"
    check mutated(
      proc(m: CborValue) =
        m.linux["artifacts"].items.reverse()
    ) == "invalid-package"
    check mutated(
      proc(m: CborValue) =
        m["variants"].items.reverse()
    ) == "ok" # variant order is significant, not canonical

  test "[PKG-0266] [PKG-0284] [PKG-0057] modules are unique and in name order":
    check mutated(
      proc(m: CborValue) =
        m["modules"].items.reverse()
    ) == "invalid-package"
    check mutated(
      proc(m: CborValue) =
        m["modules"].items[1].put("module", cbor("alpha_module"))
    ) == "invalid-package"

  test "[PKG-0267] [PKG-0284] one artifact implements at most one module":
    check mutated(
      proc(m: CborValue) =
        m["modules"].items[1].put("artifact", cbor("alpha"))
    ) == "invalid-package"

  test "[PKG-0056] [PKG-0059] [PKG-0263] the implementation artifact occurs somewhere, always as module-binary":
    check mutated(
      proc(m: CborValue) =
        m["modules"].items[1].put("artifact", cbor("gamma"))
    ) == "invalid-package"
    check mutated(
      proc(m: CborValue) =
        m["variants"].items[1]["artifacts"].items[0].put("kind", cbor("resource"))
    ) == "artifact-integrity-failed"

  test "[PKG-0053] [PKG-0054] [PKG-0264] configuration artifacts are in every variant that has the module":
    check mutated(
      proc(m: CborValue) =
        m["variants"].items[1]["artifacts"].items.delete(2)
    ) == "invalid-package"
    check mutated(
      proc(m: CborValue) =
        m.linux["artifacts"].items.delete(1)
    ) == "invalid-package"
    check mutated(
      proc(m: CborValue) =
        m.linux["artifacts"].items[1].put("kind", cbor("data"))
    ) == "artifact-integrity-failed"
    # beta's variant set is narrower; another module may share alpha's schema.
    check mutated(
      proc(m: CborValue) =
        m["modules"].items[1].put("configuration", m.alpha["configuration"])
    ) == "ok"
    # Without the module's implementation, a variant needs no configuration artifacts.
    check mutated(
      proc(m: CborValue) =
        m["variants"].items[1].put(
          "artifacts", cborArray(artifact("beta", "module-binary", "lib/libbeta.dylib"))
        )
    ) == "ok"

  test "[PKG-0055] [PKG-0285] [PKG-0057] implements, requires and requested permissions are unique and ordered":
    check mutated(
      proc(m: CborValue) =
        m.alpha["implements"].items.reverse()
    ) == "invalid-package"
    check mutated(
      proc(m: CborValue) =
        m.alpha.put("implements", cborArray(commitmentValue(2), commitmentValue(2)))
    ) == "invalid-package"
    check mutated(
      proc(m: CborValue) =
        m.alpha["requires"].items.add(m.alpha["requires"].items[0])
    ) == "invalid-package"
    check mutated(
      proc(m: CborValue) =
        m.alpha["requested_permissions"].items.reverse()
    ) == "invalid-package"
    check mutated(
      proc(m: CborValue) =
        m.alpha["requested_permissions"].items[1].put(
          "permission", cbor("logos.storage.read")
        )
    ) == "invalid-package"

  test "[PKG-0286] [PKG-0296] optional arrays are non-empty when present":
    for f in ["implements", "requires", "requested_permissions"]:
      let field = f
      checkpoint field
      check mutated(
        proc(m: CborValue) =
          m.alpha.put(field, cborArray())
      ) == "invalid-package"
      check mutated(
        proc(m: CborValue) =
          m.alpha.drop(field)
      ) == "ok"
    check mutated(
      proc(m: CborValue) =
        m.put("dependencies", cborArray())
    ) == "invalid-package"
    check mutated(
      proc(m: CborValue) =
        m.drop("dependencies")
    ) == "ok"

  test "[PKG-0265] [PKG-0297] [PKG-0057] dependency names are unique and in order":
    check mutated(
      proc(m: CborValue) =
        m["dependencies"].items.reverse()
    ) == "invalid-package"
    check mutated(
      proc(m: CborValue) =
        m["dependencies"].items[1].put("package", cbor("logos.base"))
    ) == "invalid-package"

  test "[PKG-0334] permission constraints are one Logos deterministic-CBOR value":
    check mutated(
      proc(m: CborValue) =
        m.alpha["requested_permissions"].items[0].put(
          "constraints", cbor(@[0xa0'u8, 0x00])
        )
    ) == "invalid-package"
    check mutated(
      proc(m: CborValue) =
        m.alpha["requested_permissions"].items[0].put(
          "constraints", cbor(@[0xb8'u8, 0x00])
        )
    ) == "invalid-package"

  test "[PKG-0268] a schema commitment record must match logos.schema_commitment":
    check mutated(
      proc(m: CborValue) =
        m.alpha["primary_contract"].put("hash_suite", cbor("logos.hash-suite.sha256"))
    ) == "invalid-package"
    check mutated(
      proc(m: CborValue) =
        m.alpha["primary_contract"].put("schema_root", cbor(newSeq[byte](31)))
    ) == "invalid-package"

  test "[PKG-0274] [PKG-0278] [PKG-0279] [PKG-0280] [PKG-0281] artifact paths stay inside the variant":
    for b in [
      "/etc/passwd", "../x", "lib/../../x", "https://example.org/x", "C:/x", "lib\\x"
    ]:
      let bad = b
      checkpoint bad
      check mutated(
        proc(m: CborValue) =
          m.linux["artifacts"].items[0].put("path", cbor(bad))
      ) == "artifact-integrity-failed"
    check checkArtifactPath("lib/./x.so").isOk # LGX path rules reject it later

  test "[PKG-0259] the manifest names the selected package reference":
    let m = decodeManifest(encodeCbor(base())).get
    check m.checkIdentity("logos.example", "1.2.3").isOk
    check m.checkIdentity("logos.example", "1.2.4").error.code == pecInvalidPackage
    check m.checkIdentity("Logos.example", "1.2.3").error.code == pecInvalidPackage

suite "pkg.semver: SemVer 2.0.0 precedence (PM §5, §11)":
  test "[PKG-0175] the SemVer 2.0.0 §11 example orders":
    let order = [
      "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
      "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "2.0.0", "2.1.0", "2.1.1",
      "18446744073709551616.0.0",
    ]
    for i in 1 ..< order.len:
      checkpoint order[i - 1] & " < " & order[i]
      check parseSemVer(order[i - 1]).get < parseSemVer(order[i]).get
      check not (parseSemVer(order[i]).get < parseSemVer(order[i - 1]).get)
    check cmp(parseSemVer("1.0.0-rc.1").get, parseSemVer("1.0.0-rc.1").get) == 0
    check $parseSemVer("1.0.0-rc.1").get == "1.0.0-rc.1"

suite "pkg.errors: the PM §14 error codes":
  test "[PKG-0358] the code enum is the mirrored CDDL choice, in order":
    let rules = parseSource(PackageErrorsDocument).get
    var codes: seq[string]
    for r in rules:
      if r.name == "logos.package_manager.package_error_code":
        for alt in r.typ.unwrap.alternatives:
          codes.add(alt.literal.text)
    check codes == PackageErrorCode.toSeq.mapIt($it)

suite "pkg.trust: package-signing trust input (PM §4.1, §4.3)":
  let a = keyFromSeed(seed(1)).publicKey
  let b = keyFromSeed(seed(2)).publicKey

  test "[PKG-0071] [PKG-0072] [PKG-0097] [PKG-0106] [PKG-0107] each kid maps to one key; kids are unique; name sets are non-empty":
    var t: TrustInput
    check t.addAnchor(bytesOf("org-1"), a, ["logos.storage"]).isOk
    check t.addAnchor(bytesOf("org-1"), b, ["logos.storage"]).isErr
    check t.addAnchor(bytesOf("org-2"), b, []).isErr
    check t.addAnchor(newSeq[byte](), b, ["x"]).isErr
    check t.addAnchor(newSeq[byte](129), b, ["x"]).isErr
    check t.addAnchor(bytesOf("org-2"), b[0 .. 30], ["x"]).isErr
    check t.addAnchor(bytesOf("org-2"), b, [""]).isErr
    check t.len == 1
    check t.anchor(bytesOf("org-1")).get.key == a

  test "[IMPL-DECISION G42] trust input refuses small-order and non-canonical keys":
    var t: TrustInput
    for e in SmallOrderEncodings:
      check t.addAnchor(bytesOf("k"), e, ["x"]).isErr
    check t.len == 0

  test "[PKG-0073] [PKG-0074] [PKG-0075] authorization is exact byte equality":
    var t: TrustInput
    check t.addAnchor(bytesOf("org"), a, ["logos.storage", "café"]).isOk
    check t.authorize(bytesOf("org"), "logos.storage").isOk
    check t.authorize(bytesOf("org"), "café").isOk
    for other in [
      "Logos.storage", "logos.storage2", "logos", "*", "logos.*", "cafe\u0301"
    ]:
      checkpoint other
      check t.authorize(bytesOf("org"), other).error == trNotAuthorized
    check t.authorize(bytesOf("nobody"), "logos.storage").error == trUnknownKid

  test "[PKG-0078] one signer may sign several names, and several signers one name":
    var t: TrustInput
    check t.addAnchor(bytesOf("one"), a, ["p", "q"]).isOk
    check t.addAnchor(bytesOf("two"), b, ["p"]).isOk
    check t.authorize(bytesOf("one"), "q").isOk
    check t.authorize(bytesOf("two"), "p").isOk
    check t.authorize(bytesOf("two"), "q").error == trNotAuthorized

suite "pkg.cose: the COSE_Sign1 Ed25519 profile (PM §4, §4.3)":
  let doc = parseJson(readRepoFile("tests/vectors/package/cose.json"))
  let manifest = decodeManifest(encodeCbor(base())).get
  let key = keyFromSeed(seed(7))
  let kid = bytesOf("logos-test")
  var trust: TrustInput
  doAssert trust.addAnchor(kid, key.publicKey, ["logos.example"]).isOk

  proc resign(cose: CoseSign1, k = key): seq[byte] =
    ## `cose` with its payload and header as given, freshly signed.
    var c = cose
    c.signature = k.sign(sigStructure(c.protectedBytes, c.payload))
    encodeCoseSign1(c)

  proc outcome(coseBytes: seq[byte], t = trust): string =
    let r = verifyPackage(manifest.encoded, coseBytes, t)
    if r.isOk:
      "ok"
    else:
      checkpoint r.error.msg
      if existsEnv("LCN_TEST_TRACE"):
        echo "    ", r.error.msg
      $r.error.code

  let signed = signManifest(manifest, kid, key).get
  let parsed = decodeCoseSign1(signed).get

  test "[PKG-0095] [PKG-0096] the profile identifier comes from the mirrored CDDL":
    check signingProfile() == doc["profile"].getStr
    check signingProfile() == "logos.package-signing.cose-sign1-ed25519"

  test "[PKG-0099] [PKG-0100] [PKG-0101] [PKG-0102] [PKG-0103] [PKG-0104] the container matches the oracle's bytes":
    for v in doc["vectors"]:
      checkpoint v["name"].getStr
      let (cose, tbs) =
        unsignedCose(hexBytes(v["kid"].getStr), hexBytes(v["payload"].getStr))
      check cose.protectedBytes.toHex == v["protected"].getStr
      check tbs.toHex == v["tbs"].getStr
      var full = cose
      let k = keyFromSeed(
        block:
          var s: Seed
          let b = hexBytes(v["seed"].getStr)
          for i in 0 ..< SeedLen:
            s[i] = b[i]
          s
      )
      check k.publicKey.toHex == v["public_key"].getStr
      full.signature = k.sign(tbs)
      check full.signature.toHex == v["signature"].getStr
      check encodeCoseSign1(full).toHex == v["cose"].getStr
      let back = decodeCoseSign1(hexBytes(v["cose"].getStr)).get
      check back.kid.toHex == v["kid"].getStr
      check back.payload.toHex == v["payload"].getStr

  test "[PKG-0098] [PKG-0105] [PKG-0066] [PKG-0179] the payload is the Logos det-CBOR claim binding the manifest commitment":
    let claim = decodeCbor(parsed.payload).get
    check claim.lookup("profile").get.getText.get == signingProfile()
    check ManifestCommitment.fromCbor(claim.lookup("manifest_commitment").get).get ==
      manifest.commitment.get
    check parsed.payload == claimPayload(manifest.commitment.get).get

  test "[PKG-0068] [PKG-0074] [PKG-0110] a signed manifest verifies":
    let r = verifyPackage(manifest.encoded, signed, trust)
    check r.isOk
    check r.get.signer.kid == kid
    check r.get.commitment == manifest.commitment.get

  test "external signing: --emit-tbs then --attach-sig gives the same object":
    let (_, tbs) = toBeSigned(manifest, kid).get
    check attachSignature(manifest, kid, key.sign(tbs)).get == signed
    check attachSignature(manifest, kid, newSeq[byte](63)).isErr

  test "[PKG-0109] [PKG-0111] malformed structure, headers or encoding are signature-verification-failed":
    let sig = @(parsed.signature)
    proc raw(items: varargs[CborValue]): seq[byte] =
      encodeCbor(cborTag(18, cborArray(items)))

    let p = cbor(parsed.protectedBytes)
    let body = cbor(parsed.payload)
    let cases = {
      "untagged": encodeCbor(cborArray(p, cborMap(), body, cbor(sig))),
      "tag 17": encodeCbor(cborTag(17, cborArray(p, cborMap(), body, cbor(sig)))),
      "three elements": raw(p, cborMap(), body),
      "detached payload": raw(p, cborMap(), cborNull(), cbor(sig)),
      "unprotected kid": raw(p, cborMap((cbor(4'u64), cbor(kid))), body, cbor(sig)),
      "63-byte signature": raw(p, cborMap(), body, cbor(sig[0 .. 62])),
      "65-byte signature": raw(p, cborMap(), body, cbor(sig & @[0'u8])),
      "protected not bstr": raw(cborMap(), cborMap(), body, cbor(sig)),
      "trailing byte": signed & @[0'u8],
      "non-shortest head": @[0xd2'u8, 0x98, 0x04] & signed[2 .. ^1],
    }
    for (name, bytes) in cases:
      checkpoint name
      check outcome(bytes) == "signature-verification-failed"

  test "[PKG-0101] [PKG-0102] [PKG-0109] protected headers other than alg -19 and kid fail, even when signed":
    proc header(entries: varargs[CborEntry]): seq[byte] =
      encodeCbor(cborMap(entries))

    let cases = {
      "alg -8 (EdDSA)": header((cbor(1'u64), cbor(-8'i64)), (cbor(4'u64), cbor(kid))),
      "no alg": header((cbor(4'u64), cbor(kid))),
      "no kid": header((cbor(1'u64), cbor(-19'i64))),
      "crit": header(
        (cbor(1'u64), cbor(-19'i64)),
        (cbor(2'u64), cborArray(cbor(4'u64))),
        (cbor(4'u64), cbor(kid)),
      ),
      "content type": header(
        (cbor(1'u64), cbor(-19'i64)),
        (cbor(3'u64), cbor(0'u64)),
        (cbor(4'u64), cbor(kid)),
      ),
      "kid text":
        header((cbor(1'u64), cbor(-19'i64)), (cbor(4'u64), cbor("logos-test"))),
      "kid 129 bytes":
        header((cbor(1'u64), cbor(-19'i64)), (cbor(4'u64), cbor(newSeq[byte](129)))),
      "alg text": header((cbor(1'u64), cbor("Ed25519")), (cbor(4'u64), cbor(kid))),
    }
    for (name, h) in cases:
      checkpoint name
      var c = parsed
      c.protectedBytes = h
      check outcome(resign(c)) == "signature-verification-failed"
    var c = parsed
    c.protectedBytes =
      @[0xa2'u8, 0x04, 0x4a] & kid & @[0x01'u8, 0x32] # keys out of order
    check outcome(resign(c)) == "signature-verification-failed"

  test "[PKG-0068] [PKG-0075] [PKG-0109] unknown kid, wrong key, bad signature and unauthorized signer fail":
    var other: TrustInput
    check other.addAnchor(bytesOf("someone-else"), key.publicKey, ["logos.example"]).isOk
    check outcome(signed, other) == "signature-verification-failed"
    var wrongKey: TrustInput
    check wrongKey.addAnchor(kid, keyFromSeed(seed(8)).publicKey, ["logos.example"]).isOk
    check outcome(signed, wrongKey) == "signature-verification-failed"
    var bad = signed
    bad[^1] = bad[^1] xor 1
    check outcome(bad) == "signature-verification-failed"
    var otherName: TrustInput
    check otherName.addAnchor(kid, key.publicKey, ["logos.other"]).isOk
    check outcome(signed, otherName) == "signature-verification-failed"

  test "[PKG-0066] [PKG-0068] [PKG-0110] a claim that differs from the computed commitment fails, even when signed":
    let c = manifest.commitment.get
    proc claimWith(f: proc(claim: CborValue)): seq[byte] =
      let claim = claimValue(c)
      f(claim)
      var cose = parsed
      cose.payload = encodeCbor(claim)
      resign(cose)

    let cases = {
      "other profile": claimWith(
        proc(x: CborValue) =
          x.put("profile", cbor("logos.package-signing.other"))
      ),
      "other value root": claimWith(
        proc(x: CborValue) =
          x["manifest_commitment"].put("value_root", cbor(newSeq[byte](32)))
      ),
      "other subtree root": claimWith(
        proc(x: CborValue) =
          x["manifest_commitment"].put("schema_subtree_root", cbor(newSeq[byte](32)))
      ),
      "other model": claimWith(
        proc(x: CborValue) =
          x["manifest_commitment"].put(
            "commitment_model", cbor("logos.commitment-model.2027-01")
          )
      ),
      "extra field": claimWith(
        proc(x: CborValue) =
          x.put("signed_at", cbor(0'u64))
      ),
      "no commitment": claimWith(
        proc(x: CborValue) =
          x.drop("manifest_commitment")
      ),
    }
    for (name, bytes) in cases:
      checkpoint name
      check outcome(bytes) == "signature-verification-failed"
    var cose = parsed
    check parsed.payload[0] == 0xa2
    cose.payload = @[0xb8'u8, 0x02] & parsed.payload[1 .. ^1] # a non-shortest map head
    check outcome(resign(cose)) == "signature-verification-failed"
    # A signature over another manifest's claim fails for this one.
    let other = base()
    other.put("version", cbor("1.2.4"))
    let otherSigned = signManifest(decodeManifest(encodeCbor(other)).get, kid, key).get
    check outcome(otherSigned) == "signature-verification-failed"

  test "[PKG-0068] a manifest that does not decode is invalid-package before any signature check":
    check verifyPackage(@[0xa0'u8], signed, trust).error.code == pecInvalidPackage

suite "pkg.ownership: shared type ownership (PM §16)":
  test "[PKG-0413] the interface, transport, commitment and hash layers do not import the Package Manager code":
    # Contract identity and the commitment, hash and transport rules are defined
    # without the package layer: no module of theirs imports it.
    let root = currentSourcePath().parentDir.parentDir / "src" / "logos_core"
    var checked = 0
    for layer in ["iface", "transport", "commitment", "hash", "cbor", "cddl"]:
      var files = @[root / layer & ".nim"]
      for f in walkDirRec(root / layer):
        files.add(f)
      for f in files:
        if not f.endsWith(".nim") or not fileExists(f):
          continue
        inc checked
        for line in readFile(f).splitLines:
          let l = line.strip
          if l.startsWith("import ") or l.startsWith("from ") or l.startsWith(
            "include "
          ):
            checkpoint f & ": " & l
            check "package" notin l
    check checked > 20
