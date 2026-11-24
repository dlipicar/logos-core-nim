## Installed records, responses, the handoff's construction and the admission bound (Tier 5
## step 5-5-1; DECISIONS G445, G450, G451, G452; docs/PACKAGE-MANAGER.md §8, §12, §13): the
## record and index codecs, every response encoder against the mirrored App A method types, the
## handoff's fields, configuration and refusals, and the exact 16 MiB edge.

import std/[sequtils, strutils]
import unittest2
import logos_sdk/commitment
import logos_sdk/iface/accept
import logos_sdk/kit/rc_types
import ../src/logos_core/pins as core_pins
import ../src/logos_core/runtime/configcheck
import ../src/logos_core/transport/envelope
import ../src/logos_core/pm/[admission, handoff, installed, responses]
import ./support/lgxbuild

# The spec's own schema, assembled here apart from installed.nim's ----------------------------

proc configurationTypes(): string =
  for d in rcDocuments()[2]:
    if "logos.module_configuration.configuration_declaration =" in d:
      return d
  doAssert false, "no Module Configuration types"

let spec = acceptContractSet(
  PackageManagerContractDocument,
  [],
  [PackageManifestDocument, configurationTypes()],
  AcceptOptions(system: true),
).get

proc validAs(v: CborValue, name: string): bool =
  let d = spec.primary.model.find(name)
  doAssert d.isSome, name
  spec.schemaSet.validates(0, d.get.body, v)

proc `[]`(v: CborValue, key: string): CborValue =
  v.lookup(key).get

proc has(v: CborValue, key: string): bool =
  v.lookup(key).isSome

proc put(m: CborValue, key: string, x: CborValue) =
  for e in m.entries.mitems:
    if e.key.getText == Opt.some(key):
      e.value = x
      return
  m.entries.add((cbor(key), x))

proc opened(bytes: openArray[byte]): CborValue =
  ## A record file with its embedded record decoded in place, to read or change.
  result = decodeCbor(bytes).get
  result.put("record", decodeCbor(result["record"].getBytes.get).get)

proc sealed(v: CborValue): seq[byte] =
  ## `opened`'s value encoded again, its record embedded as bytes.
  let w = decodeCbor(encodeCbor(v)).get
  w.put("record", cbor(encodeCbor(w["record"])))
  encodeCbor(w)

proc drop(m: CborValue, key: string) =
  m.entries.keepItIf(it.key.getText != Opt.some(key))

proc deep(v: CborValue): CborValue =
  decodeCbor(encodeCbor(v)).get

# Fixtures ------------------------------------------------------------------------------------

const
  Base = "/sentinel-state-dir/install/r/0123456789abcdef0123456789abcdef/a/"
    ## a state directory and a binding no public message may name (PKG-0360)
  Binding = "sentinel-binding"
  Linux = "linux-x86_64"
  Darwin = "darwin-aarch64"

let (orgKey, orgPub) = testKey(1)
let trust = trustInputOf([("org", orgPub, @["logos.example", "logos.wallet"])])
let signer = PackageSigner(profile: signingProfile(), key: orgPub)
let source = lgxSource(Binding, "logos.example@1.0.0")

let pkg = modulePackage(deps = [("logos.wallet", "1.0.0")])
let man = pkg.decoded
let com = man.commitment.get
let walletCom =
  modulePackage("logos.wallet", config = Opt.none(ConfigSpec)).decoded.commitment.get
let edges = @[
  ResolvedDependency(
    identity: PackageIdentity(package: "logos.wallet", version: "1.0.0"),
    commitment: walletCom,
  )
]

proc variantOf(m: Manifest, id: string): PackageVariant =
  for v in m.variants:
    if v.id == id:
      return v
  doAssert false, id

proc recordOf(
    p = pkg, variant = Linux, deps = edges, src = source
): (InstalledRecord, Manifest, ManifestCommitment) =
  let m = p.decoded
  let c = m.commitment.get
  (installedRecord(m, c, m.variantOf(variant), signer, src, deps), m, c)

let rec = recordOf()[0]

proc reader(
    p: ModulePackage, variant = Linux, altered = "", gone = ""
): ArtifactReader =
  ## The package's files as installed under `Base`: `altered` has its first byte flipped,
  ## `gone` is absent, and a read failure names its path, as the worker's would.
  let files = p.files
  result = proc(
      a: InstalledArtifact
  ): Result[seq[byte], string] {.gcsafe, raises: [].} =
    if a.path == gone:
      return err("no file at " & Base & a.path)
    for (id, fs) in files:
      if id == variant:
        for (q, d) in fs:
          if q == a.path:
            var b = d
            if q == altered:
              b[0] = b[0] xor 1
            return ok(b)
    err("no file at " & Base & a.path)

proc handoffOf(
    p = pkg, module = "alpha_module", t = trust, read = reader(pkg), variant = Linux
): Result[CborValue, HandoffError] =
  let (r, m, c) = recordOf(
    p,
    variant,
    if p.decoded.dependencies.len > 0:
      edges
    else:
      @[],
  )
  buildHandoff(r, Base, m, c, module, t, read)

# Installed records ------------------------------------------------------------------------

suite "installed records (G445)":
  test "[PKG-0172] [PKG-0177] [PKG-0178] [PKG-0291] [PKG-0618] [PKG-0619] [PKG-0620] [PKG-0624] a record is the App A installed_package_record, its local paths under the base":
    let v = recordValue(rec, Base)
    check v.validAs(InstalledRecordType)
    check checkType(InstalledRecordType, v).isOk
    check v["identity"].validAs("logos.package_manager.package_identity")
    check v["source"].validAs("logos.package_manager.package_source")
    check v["source"]["storage"] == cbor(Binding)
    # The selected variant's artifacts only (PM l.1172), each at its local path.
    let arts = v["artifacts"].items
    check arts.mapIt(it["id"].getText.get) ==
      @["alpha", "alpha-config", "alpha-defaults"]
    for a in arts:
      check a.validAs(InstalledArtifactType)
      check a["local_path"].getText.get.startsWith(Base)
    check arts[0]["local_path"] == cbor(Base & "lib/libalpha.so")
    check arts[0]["kind"] == cbor("module-binary")
    # The selected modules only, as signed (PM l.814-816): beta's artifact is darwin's.
    check v["modules"].items.len == 1
    check v["modules"].items[0] == man.modules[0].value
    check v["variant"] == cbor(Linux)
    check v["manifest_commitment"] == com.toCbor
    check v["resolved_dependencies"].items == edges.mapIt(it.toCbor)
    check v["signer"] == signer.toCbor
    # Both source kinds.
    let nix = PackageSource(kind: skNix, flakeRef: "github:logos/example")
    check recordValue(recordOf(src = nix)[0], Base).validAs(InstalledRecordType)
    # On darwin both modules are selected, in manifest order.
    let darwin = recordValue(recordOf(variant = Darwin)[0], Base)
    check darwin["modules"].items.mapIt(it["module"].getText.get) ==
      @["alpha_module", "beta_module"]

  test "a record from an opened archive is the record of its manifest and signer":
    let data = packed(pkg, "org", orgKey)
    let p = openLgx(data, trust, linuxHost, pathRules = PathRules()).get
    let r = installedRecord(p, source, edges)
    check recordValue(r, Base) == recordValue(rec, Base)
    check r.signer == signer
    check r.matchesManifest(man, com).isOk

  test "the record file round-trips with relative local paths, and is checked against its signed manifest":
    let f =
      RecordFile(record: rec, generation: 3, archiveDigest: blake3(bytesOf("archive")))
    let bytes = encodeRecordFile(f).get
    let v = opened(bytes)
    check v["format"] == cbor(1'u64)
    check v["record"]["artifacts"].items[0]["local_path"] == cbor("lib/libalpha.so")
    check sealed(v) == bytes
    let back = decodeRecordFile(bytes, man, com).get
    check back.generation == 3
    check back.archiveDigest == f.archiveDigest
    check recordValue(back.record, Base) == recordValue(rec, Base)
    check back.record.modules[0].configuration.isSome
    check encodeRecordFile(back).get == bytes
    check encodeRecordFile(RecordFile(record: rec, generation: 0)).isErr

    proc refused(change: proc(v: CborValue)): bool =
      let v = opened(bytes)
      change(v)
      decodeRecordFile(sealed(v), man, com).isErr

    # The record embedded as a map, not as its bytes; and bytes that are not one
    # deterministic value.
    check decodeRecordFile(encodeCbor(opened(bytes)), man, com).isErr
    block:
      let v = decodeCbor(bytes).get
      var inner = v["record"].getBytes.get
      inner.add(0)
      v.put("record", cbor(inner))
      check decodeRecordFile(encodeCbor(v), man, com).isErr

    check refused(
      proc(v: CborValue) =
        v.put("format", cbor(2'u64))
    )
    check refused(
      proc(v: CborValue) =
        v.put("generation", cbor(0'u64))
    )
    check refused(
      proc(v: CborValue) =
        v.put("extra", cbor(1'u64))
    )
    check refused(
      proc(v: CborValue) =
        v.drop("archive_digest")
    )
    check refused(
      proc(v: CborValue) =
        v["record"].put("variant", cbor(Darwin))
    )
    check refused(
      proc(v: CborValue) =
        v["record"]["artifacts"].items[1].put("hash", cbor(newSeq[byte](32)))
    )
    check refused(
      proc(v: CborValue) =
        v["record"]["artifacts"].items[0].put(
          "local_path", cbor("/abs/lib/libalpha.so")
        )
    )
    check refused(
      proc(v: CborValue) =
        v["record"]["artifacts"].items.setLen(2)
    )
    check refused(
      proc(v: CborValue) =
        v["record"]["resolved_dependencies"].items.setLen(0)
    )
    check refused(
      proc(v: CborValue) =
        # a widened declaration
        v["record"]["modules"].items[0]["implements"].items.add(commitmentValue(9))
    )
    check refused(
      proc(v: CborValue) =
        v["record"]["modules"].items.setLen(0)
    )
    check refused(
      proc(v: CborValue) =
        v["record"]["identity"].put("version", cbor("2.0.0"))
    )
    # Not deterministic: an unsorted map is not one Logos deterministic-CBOR value.
    var raw = bytes
    raw.add(0)
    check decodeRecordFile(raw, man, com).isErr
    # Another manifest, or another commitment.
    let other =
      modulePackage(version = "1.0.1", deps = [("logos.wallet", "1.0.0")]).decoded
    check decodeRecordFile(bytes, other, other.commitment.get).isErr
    check decodeRecordFile(bytes, man, walletCom).isErr

  test "the record keeps the selected modules in manifest order":
    let (r, m, c) = recordOf(variant = Darwin)
    let bytes = encodeRecordFile(RecordFile(record: r, generation: 1)).get
    check decodeRecordFile(bytes, m, c).isOk
    let v = opened(bytes)
    let mods = v["record"]["modules"].items
    v["record"].put("modules", cborArray(mods[1], mods[0]))
    check decodeRecordFile(sealed(v), m, c).isErr

  test "the index round-trips in identity order, each identity and rid once, within its bound":
    proc entry(rid, name, version: string, g = 1'u64): IndexEntry =
      IndexEntry(
        rid: rid,
        generation: g,
        identity: PackageIdentity(package: name, version: version),
      )

    let rid1 = repeat('a', 32)
    let rid2 = repeat('b', 32)
    let rid3 = "0123456789abcdef0123456789abcdef"
    let i = InstalledIndex(
      sequence: 7,
      records: @[
        entry(rid1, "logos.wallet", "1.0.0"),
        entry(rid2, "logos.example", "1.10.0", 2),
        entry(rid3, "logos.example", "1.2.0"),
      ],
    )
    let bytes = encodeIndex(i).get
    let back = decodeIndex(bytes).get
    check back.sequence == 7
    check back.records.mapIt($it.identity) ==
      @["logos.example@1.10.0", "logos.example@1.2.0", "logos.wallet@1.0.0"]
    check back.records[0].generation == 2
    check encodeIndex(back).get == bytes
    check decodeIndex(encodeIndex(InstalledIndex()).get).get.records.len == 0

    check encodeIndex(
      InstalledIndex(
        records: @[entry(rid1, "logos.a", "1.0.0"), entry(rid2, "logos.a", "1.0.0")]
      )
    ).isErr
    check encodeIndex(
      InstalledIndex(
        records: @[entry(rid1, "logos.a", "1.0.0"), entry(rid1, "logos.b", "1.0.0")]
      )
    ).isErr
    check encodeIndex(
      InstalledIndex(records: @[entry(repeat('A', 32), "logos.a", "1.0.0")])
    ).isErr
    check encodeIndex(
      InstalledIndex(records: @[entry(repeat('a', 31), "logos.a", "1.0.0")])
    ).isErr
    check encodeIndex(InstalledIndex(records: @[entry(rid1, "logos.a", "1.0.0", 0)])).isErr

    proc refused(change: proc(v: CborValue)): bool =
      let v = decodeCbor(bytes).get
      change(v)
      decodeIndex(encodeCbor(v)).isErr

    check refused(
      proc(v: CborValue) =
        v.put("format", cbor(2'u64))
    )
    check refused(
      proc(v: CborValue) =
        v.put("extra", cbor(1'u64))
    )
    check refused(
      proc(v: CborValue) =
        let r = v["records"].items
        v.put("records", cborArray(r[1], r[0], r[2]))
    )
    check refused(
      proc(v: CborValue) =
        v["records"].items[0].put("version", cbor("v1.10.0"))
    )
    check refused(
      proc(v: CborValue) =
        v["records"].items[0].put("rid", cbor(repeat('g', 32)))
    )
    check decodeIndex(newSeq[byte](MaxIndexBytes + 1)).isErr

# Responses ----------------------------------------------------------------------------------

const ResponseTypes = [
  "logos.package_manager.watch_installed_packages_response",
  "logos.package_manager.list_packages_response",
  "logos.package_manager.inspect_package_response",
  "logos.package_manager.install_package_response",
  "logos.package_manager.remove_package_response",
  "logos.package_manager.update_package_response",
  "logos.package_manager.list_installed_packages_response",
  "logos.package_manager.get_runtime_handoff_response",
]

suite "responses (G450)":
  test "[PKG-0356] [PKG-0357] [PKG-0628] each encoder gives its method's response variant; an error variant holds exactly one package error":
    let installed = installedResult(rec, Base)
    check installed.validAs("logos.package_manager.install_package_response")
    check installed.validAs("logos.package_manager.update_package_response")
    check not installed.has("error")
    check removedResult().validAs("logos.package_manager.remove_package_response")
    check removedResult().entries.len == 0
    let data = packed(modulePackage(config = Opt.none(ConfigSpec)), "org", orgKey)
    let opened = openLgx(data, trust, linuxHost, pathRules = PathRules()).get
    let inspection = inspectionResult(inspectRecord(opened.verified, source))
    check inspection.validAs("logos.package_manager.inspect_package_response")
    let h = handoffOf().get
    check handoffResult(h).validAs("logos.package_manager.get_runtime_handoff_response")
    let v = recordValue(rec, Base)
    check installedPage([v]).validAs(
      "logos.package_manager.list_installed_packages_response"
    )
    check installedPage([v, v], Opt.some(maxCursor())).validAs(
      "logos.package_manager.list_installed_packages_response"
    )
    check installedPage([]).validAs(
      "logos.package_manager.list_installed_packages_response"
    )
    for code in PackageErrorCode:
      for message in ["", "logos.example@1.0.0: a fixed cause"]:
        let e = errorResult(code, message)
        check e.entries.len == 1
        check e["error"].validAs(PackageErrorType)
        check e["error"]["code"] == cbor($code)
        check e["error"].has("message") == (message.len > 0)
        for t in ResponseTypes:
          check e.validAs(t)
    check errorResult(packageError(pecPackageInUse, "in use")) ==
      errorResult(pecPackageInUse, "in use")

  test "[PKG-0360] a message is cut to 512 bytes at a character boundary, and no refusal names a path or binding":
    let long = repeat("é", 300) # 600 bytes
    let cut = publicMessage(long)
    check cut.len == 512
    check cut == repeat("é", 256)
    check publicMessage(repeat('a', 511) & "é").len == 511
    check errorResult(pecInvalidRequest, long)["error"].validAs(PackageErrorType)
    check errorResult(pecInvalidRequest, long)["error"]["message"].getText.get.len == 512
    var refusals: seq[HandoffError]
    refusals.add(handoffOf(module = "beta_module").error)
    refusals.add(handoffOf(t = TrustInput()).error)
    refusals.add(handoffOf(read = reader(pkg, altered = "schema/alpha.cddl")).error)
    refusals.add(handoffOf(read = reader(pkg, gone = "data/alpha.cbor")).error)
    let invalid =
      modulePackage(config = Opt.some(tunerSpec(Opt.some(encodeCbor(cborMap())))))
    refusals.add(handoffOf(p = invalid, read = reader(invalid)).error)
    for r in refusals:
      checkpoint r.msg
      check Base notin r.msg
      check "sentinel" notin r.msg
      check Binding notin r.msg
      check $rec.identity in r.msg
    # What the read reported, with its path, is for the operator's log only.
    check (Base & "data/alpha.cbor") in refusals[3].detail

  test "[PKG-0361] [PKG-0362] a package error is a result in a successful response; what prevents a valid response is MODULE_ERROR with no detail":
    for code in PackageErrorCode:
      let m = Message(
        kind: mkResponse,
        response: Response(
          id: 1, ok: true, resultMap: errorResult(code), commitment: PayloadCommitment()
        ),
      )
      let back = checkMessage(decodeCbor(encodeMessage(m).get).get).get
      check back.response.ok
    let f = moduleError()
    check f.code == ecModule
    check f.message.isNone
    check f.detail.isNone
    check hrStateDamaged.code.isNone
    for r in HandoffRefusal:
      if r != hrStateDamaged:
        check r.code.isSome

  test "[PKG-0359] invalid-request is a refusal that repeats unchanged":
    let a = handoffOf(module = "beta_module")
    let b = handoffOf(module = "beta_module")
    check a.error.refusal == hrNotSelected
    check a.error.refusal.code == Opt.some(pecInvalidRequest)
    check a.error == b.error
    check handoffOf(module = "gamma_module").error.refusal == hrNotSelected

# The handoff ----------------------------------------------------------------------------------

suite "the handoff's construction (G451)":
  test "[PKG-0337] [PKG-0339] [PKG-0340] [PKG-0341] [PKG-0348] [PKG-0438] the fields come from the record, its retained signer and the signed manifest":
    let h = handoffOf().get
    check h.validAs(RuntimeHandoffType)
    check h["artifact"].validAs("logos.package_manager.runtime_artifact")
    check h["module"] == cbor("alpha_module")
    check h["signer"] == signer.toCbor
    check h["package"] == rec.identity.toCbor
    check h["manifest_commitment"] == com.toCbor
    let a = h["artifact"]
    check a["id"] == cbor("alpha")
    check a["local_path"] == cbor(Base & "lib/libalpha.so")
    check a["hash"] == cbor(man.variants[0].artifacts[0].hash)
    check a["hash_suite"] == cbor(HashSuiteId)
    # The hash is the signed one, whatever the file holds now: the Loader checks its copy.
    let altered = handoffOf(read = reader(pkg, altered = "lib/libalpha.so")).get
    check altered["artifact"]["hash"] == a["hash"]

  test "the declaration's contracts are carried as signed, and a record whose declaration was widened is refused":
    let h = handoffOf().get
    let d = man.modules[0].value
    for key in [
      "primary_contract", "implements", "extends", "requires", "requested_permissions"
    ]:
      checkpoint key
      check h[key] == d[key]
    let bare = handoffOf(p = modulePackage(contracts = false)).get
    for key in [
      "primary_contract", "implements", "extends", "requires", "requested_permissions"
    ]:
      check not bare.has(key)
    var widened = rec
    widened.modules[0].value = deep(widened.modules[0].value)
    widened.modules[0].value["implements"].items.add(commitmentValue(9))
    let r = buildHandoff(widened, Base, man, com, "alpha_module", trust, reader(pkg))
    check r.error.refusal == hrStateDamaged
    check r.error.refusal.code.isNone

  test "[PKG-0342] [PKG-0343] [PKG-0344] the configuration declaration: the schema text, the derived subtree root, the default, and no artifact id or path":
    let h = handoffOf().get
    let cfg = h["configuration"]
    let decl =
      LogosNSModuleConfigurationConfigurationDeclaration.decode(encodeCbor(cfg)).get
    let (schemaRoot, subtreeRoot) = rootsOf(tunerDocument, TunerRoot)
    check decl.schema.document == tunerDocument
    check decl.schema.root == TunerRoot
    check decl.schema.schema_commitment.schema_root == schemaRoot
    check decl.schema.schema_commitment.schema_subtree_root == subtreeRoot
    check decl.schema.live_reconfiguration.isNone
    check decl.default_value == Opt.some(tunerValue())
    # The Runtime's own check accepts it.
    check acceptConfiguration(encodeCbor(cfg)).isOk
    # No artifact id, package path or installed path.
    let text = textOf(encodeCbor(cfg))
    for s in [
      "alpha-config", "alpha-defaults", "schema/alpha.cddl", "data/alpha.cbor", Base
    ]:
      check s notin text
    # Live support is copied; a declaration without a default has none.
    let live =
      handoffOf(p = modulePackage(config = Opt.some(tunerSpec(live = true)))).get
    check live["configuration"]["schema"]["live_reconfiguration"] == cbor(true)
    let noDefault = handoffOf(
      p = modulePackage(config = Opt.some(tunerSpec(Opt.none(seq[byte]))))
    ).get
    check not noDefault["configuration"].has("default_value")
    check noDefault.validAs(RuntimeHandoffType)
    check not handoffOf(p = modulePackage(config = Opt.none(ConfigSpec))).get.has(
      "configuration"
    )

  test "[PKG-0341] [PKG-0344] refused: a withdrawn signer, a changed schema or default byte, a default that is not a value of its root, a module not selected":
    proc refusal(r: Result[CborValue, HandoffError]): HandoffRefusal =
      check r.isErr
      r.error.refusal

    let withdrawn = trustInputOf([("org", orgPub, @["logos.wallet"])])
    check handoffOf(t = withdrawn).refusal == hrSignerNotAccepted
    check hrSignerNotAccepted.code == Opt.some(pecSignature)
    check handoffOf(read = reader(pkg, altered = "schema/alpha.cddl")).refusal ==
      hrArtifactIntegrity
    check handoffOf(read = reader(pkg, altered = "data/alpha.cbor")).refusal ==
      hrArtifactIntegrity
    check handoffOf(read = reader(pkg, gone = "schema/alpha.cddl")).refusal ==
      hrArtifactIntegrity
    check hrArtifactIntegrity.code == Opt.some(pecArtifactIntegrity)
    let invalid =
      modulePackage(config = Opt.some(tunerSpec(Opt.some(encodeCbor(cborMap())))))
    check handoffOf(p = invalid, read = reader(invalid)).refusal == hrConfiguration
    check hrConfiguration.code == Opt.some(pecInvalidPackage)
    check handoffOf(module = "beta_module").refusal == hrNotSelected
    check hrNotInstalled.code == Opt.some(pecPackageNotInstalled)
    # On darwin beta is selected, and has no configuration.
    check handoffOf(
      module = "beta_module", variant = Darwin, read = reader(pkg, Darwin)
    ).isOk

# The admission bound --------------------------------------------------------------------------

proc pageBytes(r: InstalledRecord): int =
  envelopeBytes(installedPage([recordValue(r, Base)], Opt.some(maxCursor()))).get

proc installedBytes(r: InstalledRecord): int =
  envelopeBytes(installedResult(r, Base)).get

proc withArtifacts(n, pathLen: int): InstalledRecord =
  result = rec
  result.artifacts = @[]
  for i in 0 ..< n:
    result.artifacts.add(
      InstalledArtifact(
        id: "a" & align($i, 6, '0'), kind: akData, path: "p/" & repeat('x', pathLen - 2)
      )
    )

proc grow(r: var InstalledRecord, size: proc(r: InstalledRecord): int, target: int) =
  ## Lengthens artifact paths until `size(r)` is exactly `target`: a path of 256 to 65,535
  ## bytes has a three-byte head, so each byte added is one byte more.
  var s = size(r)
  var i = 0
  while s < target:
    let d = min(target - s, 900)
    r.artifacts[i].path.add(repeat('y', d))
    inc i
    s = size(r)
  doAssert s == target

suite "the admission bound (G452)":
  test "the response envelope's overhead is pinned":
    # The kind, the largest call id, the result and the payload commitment: 134 bytes around
    # an empty result, and each result byte one more.
    check envelopeBytes(cborMap()).get == 134
    let v = cborMap((cbor("installed"), recordValue(rec, Base)))
    check envelopeBytes(v).get == 134 + encodeCbor(v).len - 1

  test "[PKG-0468] [PKG-0469] the page with the largest cursor and call id at exactly 16 MiB passes; one byte more fails":
    let one = pageBytes(withArtifacts(1, 3000))
    let per = pageBytes(withArtifacts(2, 3000)) - one
    var r = withArtifacts(1 + (AdmissionLimit - one) div per, 3000)
    grow(r, pageBytes, AdmissionLimit)
    check pageBytes(r) == AdmissionLimit
    check admits(r, Base, []).isOk
    r.artifacts[^1].path.add("z")
    check pageBytes(r) == AdmissionLimit + 1
    check installedBytes(r) < AdmissionLimit
    let f = admits(r, Base, [])
    check f.isErr
    check f.error.result == arPage
    # The install and update result is checked too: made one byte over, it is the one that fails.
    grow(r, installedBytes, AdmissionLimit + 1)
    let g = admits(r, Base, [])
    check g.isErr
    check g.error.result == arInstalled

  test "[PKG-0469] each selected module's handoff is checked, its configuration included":
    let h = handoffOf().get
    check admits(rec, Base, [("alpha_module", h)]).isOk
    let big = deep(h)
    big.put("implements", cborArray(newSeqWith(120_000, commitmentValue(9))))
    check big.validAs(RuntimeHandoffType)
    let f = admits(rec, Base, [("alpha_module", h), ("alpha_module", big)])
    check f.isErr
    check f.error.result == arHandoff
    check f.error.module == "alpha_module"

  test "a local path over 4,096 bytes fails admission, as after the state directory moves":
    let longest = rec.artifacts.mapIt(it.path.len).max
    let fits = "/" & repeat('d', 4096 - longest - 2) & "/"
    check (fits & "schema/alpha.cddl").len == 4096
    check admits(rec, fits, []).isOk
    let f = admits(rec, "/d" & fits, [])
    check f.isErr
    check f.error.result == arInstalled
