## PM §5, §6, §11: package identities, source records, catalog entries,
## inspection records and resolved dependency edges. Each is validated against
## the mirrored CDDL (PM §5, §6, §11, with §4 and §4.3 for the types they
## name) plus the rules the CDDL does not express.

{.push raises: [].}

import std/strutils
import results
import ../cbor
import ../cddl/syntax
import ../commitment
import ../iface/accept
import ../pins
import ../crypto/slhdsa
import ./[errors, manifest, semver, signing]

export results, errors, manifest

const
  IdentityType* = "logos.package_manager.package_identity" ## [SPEC PM §5]
  SourceType* = "logos.package_manager.package_source" ## [SPEC PM §5]
  CatalogEntryType* = "logos.package_manager.package_catalog_entry" ## [SPEC PM §6]
  InspectRecordType* = "logos.package_manager.package_inspect_record" ## [SPEC PM §6]
  ResolvedDependencyType* = "logos.package_manager.resolved_package_dependency"
    ## [SPEC PM §11]
  ModuleRule = "_module"

type
  PackageIdentity* = object
    ## [SPEC PM §5] A package name and its complete version text.
    package*: string
    version*: string

  SourceKind* = enum
    skLgx = "lgx"
    skNix = "nix"

  PackageSource* = object
    ## [SPEC PM §5, §6] Location data only: a source establishes no trust.
    case kind*: SourceKind
    of skLgx:
      storage*: string ## a deployment-configured Logos Storage binding
      objectLocator*: seq[byte] ## `object`: the archive, opaque bytes
      provenanceLocator*: Opt[seq[byte]]
        ## `provenance_object`: untrusted location data; it selects no profile
    of skNix:
      flakeRef*: string
      attr*: Opt[string]
      lockedRef*: Opt[string]

  CatalogEntry* = object
    ## [SPEC PM §6] Availability in Logos terms: an exact identity and where to
    ## get it. It carries no manifest or trusted metadata.
    identity*: PackageIdentity
    source*: PackageSource

  ResolvedDependency* = object
    ## [SPEC PM §11] One recorded dependency edge: the selected identity and its
    ## exact manifest commitment.
    identity*: PackageIdentity
    commitment*: ManifestCommitment

  InspectRecord* = object
    ## [SPEC PM §6] Reported only after the manifest, signature and commitment
    ## were verified: `inspectRecord` takes a `VerifiedPackage`.
    signer*: PublicKey
    source*: PackageSource
    manifest*: Manifest
    commitment*: ManifestCommitment

# The record schema -----------------------------------------------------------------

type RecordSchema = ref object
  set: SchemaSet
  identity, source, entry, inspect, resolved: SchemaNode

proc ruleText(doc, name: string): Result[string, string] =
  ## The text of the rule `name` in `doc`, up to the next rule.
  let rules = parseSource(doc).valueOr:
    return err("a mirrored PM block does not parse: " & $error)
  var start = -1
  var stop = doc.len
  for r in rules:
    if r.name == name:
      start = r.pos
    elif start >= 0 and r.pos > start and r.pos < stop:
      stop = r.pos
  if start < 0:
    return err("no mirrored PM block defines " & name)
  ok(doc[start ..< stop].strip & "\n")

proc recordsDocument(): Result[string, string] =
  ## The records as the Package Manager's module document declares them (PM
  ## §15's `_module` rule, §16: they live in `logos.package_manager` and
  ## reference the `logos.package_manifest` supporting schema): PM §5's identity
  ## block, its `package_source` and `manifest_commitment` rules (its installed
  ## record names PM §10 types, built in tier 5), PM §4.3, §6 and §11.
  ok(
    ?ruleText(PackageManagerMethodsDocument, ModuleRule) & "\n" &
      PackageIdentityDocument.strip & "\n\n" &
      ?ruleText(PackageRecordsDocument, SourceType) & "\n" &
      ?ruleText(PackageRecordsDocument, CommitmentType) & "\n" &
      PackageSigningProfileDocument.strip & "\n\n" & PackageCatalogRecordsDocument.strip &
      "\n\n" & PackageResolvedDependencyDocument.strip & "\n"
  )

proc loadRecordSchema(): Result[RecordSchema, string] =
  let doc = ?recordsDocument()
  let c =
    ?acceptContractSet(doc, [], [PackageManifestDocument], AcceptOptions(system: true))
  let m = c.primary.model
  proc body(name: string): Result[SchemaNode, string] =
    let d = m.find(name).valueOr:
      return err("no " & name)
    ok(d.body)

  ok(
    RecordSchema(
      set: c.schemaSet,
      identity: ?body(IdentityType),
      source: ?body(SourceType),
      entry: ?body(CatalogEntryType),
      inspect: ?body(InspectRecordType),
      resolved: ?body(ResolvedDependencyType),
    )
  )

let recordSchema = block:
  let s = loadRecordSchema()
  doAssert s.isOk,
    "the pinned PM §5, §6 and §11 record schema does not load: " & s.error
  s.get

func schema(): RecordSchema =
  {.cast(noSideEffect).}:
    recordSchema

func check(node: SchemaNode, v: CborValue, what: string): Result[void, string] =
  let s = schema()
  s.set.validatePath(0, node, v).isOkOr:
    var at = ""
    for seg in error:
      at.add("/" & seg.getText.get(toDiag(seg)))
    return err("not a valid " & what & " at " & (if at.len == 0: "/" else: at))
  ok()

# Encoding --------------------------------------------------------------------------

func toCbor*(i: PackageIdentity): CborValue =
  cborMap((cbor("package"), cbor(i.package)), (cbor("version"), cbor(i.version)))

func toCbor*(s: PackageSource): CborValue =
  var m = cborMap((cbor("kind"), cbor($s.kind)))
  case s.kind
  of skLgx:
    m.entries.add((cbor("storage"), cbor(s.storage)))
    m.entries.add((cbor("object"), cbor(s.objectLocator)))
    if s.provenanceLocator.isSome:
      m.entries.add((cbor("provenance_object"), cbor(s.provenanceLocator.get)))
  of skNix:
    m.entries.add((cbor("flake_ref"), cbor(s.flakeRef)))
    if s.attr.isSome:
      m.entries.add((cbor("attr"), cbor(s.attr.get)))
    if s.lockedRef.isSome:
      m.entries.add((cbor("locked_ref"), cbor(s.lockedRef.get)))
  m

func encoded*(s: PackageSource): seq[byte] =
  ## [SPEC PM §11, §15] The Logos deterministic-CBOR source-record encoding
  ## that orders equivalent sources and `list_packages` results.
  encodeCbor(s.toCbor)

func `==`*(a, b: PackageSource): bool =
  a.encoded == b.encoded

func toCbor*(e: CatalogEntry): CborValue =
  cborMap((cbor("identity"), e.identity.toCbor), (cbor("source"), e.source.toCbor))

func toCbor*(d: ResolvedDependency): CborValue =
  cborMap(
    (cbor("identity"), d.identity.toCbor),
    (cbor("manifest_commitment"), d.commitment.toCbor),
  )

func signerValue(key: PublicKey): CborValue =
  cborMap((cbor("profile"), cbor(signingProfile())), (cbor("public_key"), cbor(key)))

func toCbor*(r: InspectRecord): CborValue =
  cborMap(
    (cbor("signer"), signerValue(r.signer)),
    (cbor("source"), r.source.toCbor),
    (cbor("manifest"), r.manifest.value),
    (cbor("manifest_commitment"), r.commitment.toCbor),
  )

# Decoding --------------------------------------------------------------------------

# The value has been validated against the schema before these run, so the
# fields they read exist with the declared types.

func text(v: CborValue, key: string): string =
  v.lookup(key).get.getText.get

func optText(v: CborValue, key: string): Opt[string] =
  let f = v.lookup(key)
  if f.isNone:
    Opt.none(string)
  else:
    f.get.getText

func optBytes(v: CborValue, key: string): Opt[seq[byte]] =
  let f = v.lookup(key)
  if f.isNone:
    Opt.none(seq[byte])
  else:
    f.get.getBytes

func checkIdentity(i: PackageIdentity): Result[void, string] =
  ## [SPEC PM §5] A package version is SemVer 2.0.0 text without a leading `v`
  ## or build metadata; the CDDL bounds only its length.
  parseSemVer(i.version).isOkOr:
    return err("version " & i.version & " is not a package version: " & error)
  ok()

func identityOf(v: CborValue): PackageIdentity =
  PackageIdentity(package: v.text("package"), version: v.text("version"))

func sourceOf(v: CborValue): PackageSource =
  if v.text("kind") == "lgx":
    PackageSource(
      kind: skLgx,
      storage: v.text("storage"),
      objectLocator: v.lookup("object").get.getBytes.get,
      provenanceLocator: v.optBytes("provenance_object"),
    )
  else:
    PackageSource(
      kind: skNix,
      flakeRef: v.text("flake_ref"),
      attr: v.optText("attr"),
      lockedRef: v.optText("locked_ref"),
    )

func checkSource(s: PackageSource): Result[void, string] =
  ## [SPEC PM §6] A provenance locator differs from the archive locator.
  if s.kind == skLgx and s.provenanceLocator == Opt.some(s.objectLocator):
    return err("provenance_object equals object")
  ok()

func decodeIdentity*(v: CborValue): Result[PackageIdentity, string] =
  ?check(schema().identity, v, IdentityType)
  let i = identityOf(v)
  ?checkIdentity(i)
  ok(i)

func decodeSource*(v: CborValue): Result[PackageSource, string] =
  ?check(schema().source, v, SourceType)
  let s = sourceOf(v)
  ?checkSource(s)
  ok(s)

func decodeCatalogEntry*(v: CborValue): Result[CatalogEntry, string] =
  ## [SPEC PM §6] One catalog entry: untrusted location data for an exact
  ## package identity.
  ?check(schema().entry, v, CatalogEntryType)
  let e = CatalogEntry(
    identity: identityOf(v.lookup("identity").get),
    source: sourceOf(v.lookup("source").get),
  )
  ?checkIdentity(e.identity)
  ?checkSource(e.source)
  ok(e)

func decodeResolvedDependency*(v: CborValue): Result[ResolvedDependency, string] =
  ?check(schema().resolved, v, ResolvedDependencyType)
  let d = ResolvedDependency(
    identity: identityOf(v.lookup("identity").get),
    commitment: ManifestCommitment.fromCbor(v.lookup("manifest_commitment").get).get,
  )
  ?checkIdentity(d.identity)
  ok(d)

func inspectRecord*(p: VerifiedPackage, source: PackageSource): InspectRecord =
  ## [SPEC PM §6] The inspection record of a package whose manifest, signature
  ## and commitment `verifyPackage` accepted, located by `source`.
  InspectRecord(
    signer: p.signer.key, source: source, manifest: p.manifest, commitment: p.commitment
  )

proc decodeInspectRecord*(v: CborValue): Result[InspectRecord, string] =
  ## [SPEC PM §6] An inspection record whose manifest is a valid package
  ## manifest and whose commitment is that manifest value's commitment.
  ?check(schema().inspect, v, InspectRecordType)
  let source = sourceOf(v.lookup("source").get)
  ?checkSource(source)
  let m = decodeManifest(encodeCbor(v.lookup("manifest").get)).valueOr:
    return err("the manifest is not valid: " & error.msg)
  let claimed = ManifestCommitment.fromCbor(v.lookup("manifest_commitment").get).get
  let computed = m.commitment.valueOr:
    return err("the manifest has no commitment: " & error.msg)
  if claimed != computed:
    return err("manifest_commitment is not the commitment of the manifest")
  var key: PublicKey
  let raw = v.lookup("signer").get.lookup("public_key").get.getBytes.get
  for i in 0 ..< PublicKeyBytes:
    key[i] = raw[i]
  ok(InspectRecord(signer: key, source: source, manifest: m, commitment: computed))

func identity*(m: Manifest): PackageIdentity =
  PackageIdentity(package: m.package, version: m.version)

func `$`*(i: PackageIdentity): string =
  i.package & "@" & i.version
