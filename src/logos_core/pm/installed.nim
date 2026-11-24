## The installed record, its file and the index (Tier 5 step 5-5-1; DECISIONS G445;
## docs/PACKAGE-MANAGER.md §8; PACKAGE MANAGER §5 l.778-830, §10 l.1149-1197).
##
## - **The record** is PM §5's `installed_package_record`: the retained signer, the identity, the
##   source, the selected variant, the manifest commitment, the selected module declarations in
##   manifest order (l.814-816), the selected variant's artifacts (l.1172) and the recorded
##   dependency edges (l.1337-1341). It is built from a verified package only, and every load
##   checks it again against its signed manifest (`matchesManifest`).
## - **`local_path`** is `base & path`: `path` is the artifact's variant-relative path, and `base`
##   the record's absolute `a/` directory, which the store rebuilds from the current state
##   directory at each start (G444). The record file stores the relative paths (`base` empty).
## - **The files** are `installed.cddl`'s, a supporting schema of the `lcn` namespace of its own
##   (BCP-0104: no `logos.` name is ours). Each is checked on every load against that text, and
##   the record it embeds, and each index identity, against the pinned App A types (PM l.1842-1845:
##   App A governs); then against the rules the schema cannot say.
## - **The contract schema** (`checkType`) is App A with the manifest schema (PM §4) and the Module
##   Configuration types (CONFIGURATION §9) it names, as the Package Manager's module document
##   declares them. The results, handoff and admission modules check their values with it.

{.push raises: [].}

import std/[algorithm, strutils]
import results
import logos_sdk/base/[hex, perthread]
import logos_sdk/cbor
import logos_sdk/commitment
import logos_sdk/crypto/blake3
import logos_sdk/iface/accept
import ../crypto/slhdsa
import ../pins
import ../package/[lgx, manifest, records, signing]
import ./contractset

export results, blake3, manifest, records, signing

const
  InstalledRecordType* = "logos.package_manager.installed_package_record"
    ## [SPEC PM §5]
  InstalledArtifactType* = "logos.package_manager.installed_artifact" ## [SPEC PM §10]
  RuntimeHandoffType* = "logos.package_manager.runtime_handoff" ## [SPEC PM §12]
  PackageErrorType* = "logos.package_manager.package_error" ## [SPEC PM §14]
  PackageIdentityType* = "logos.package_manager.package_identity" ## [SPEC PM §5]
  RecordFileType* = "lcn.pm_installed_record"
    ## `installed.cddl`: `m/record.<generation>`
  IndexType* = "lcn.pm_installed_index" ## `installed.cddl`: `install/index`
  FileFormat* = 1'u64 ## [G445] both files' `format`
  RidChars* = 32 ## [G444] a rid: 32 lowercase hexadecimal digits (128 random bits)
  MaxIndexBytes* = 64 * 1024 * 1024
    ## [G445] the index's bounded read: at least 200,000 records at the longest identities
  InstalledCddl = staticRead("installed.cddl")

type
  InstalledArtifact* = object
    ## [SPEC PM §10] One artifact of the selected variant, as the signed manifest declares it.
    id*: string
    kind*: ArtifactKind
    path*: string ## the variant-relative path: `local_path` below the record's `a/`
    hash*: Digest ## the signed BLAKE3-256 of its exact bytes

  InstalledRecord* = object ## [SPEC PM §5] One installed package record.
    signer*: PackageSigner ## the retained `package_signer` (PKG-0438)
    identity*: PackageIdentity
    source*: PackageSource
    variant*: string ## the selected variant's id
    commitment*: ManifestCommitment
    modules*: seq[ModuleDeclaration]
      ## the selected module declarations, in manifest order (PM l.814-816)
    artifacts*: seq[InstalledArtifact] ## the selected variant's, in manifest order
    resolvedDependencies*: seq[ResolvedDependency]
      ## one edge per direct manifest dependency, in declaration order (PM l.1337-1341)

  StoreFault* = enum
    sfInUse = "the installation root is in use"
    sfDamaged = "the installed state is damaged"
    sfWrite = "a write to the state filesystem failed"
    sfEscaped = "an extracted path escaped its realization root"
    sfIntegrity = "retained artifact bytes are absent or changed"
    sfPaths = "the package's paths are not installable under this root's rules"
    sfAdmission = "a required result does not fit the admission bound"
    sfIndexBound = "the index would pass its bound"
    sfConflict = "the identity is already installed"
    sfSource = "the archive's source no longer gives the judged package"
      ## [G446] the extraction pass met a difference: `package-unavailable` (PM §8 l.1094)
    sfStopped = "stopped"

  StoreError* = object
    fault*: StoreFault
    identity*: Opt[PackageIdentity] ## the record concerned, when there is one (R3)
    detail*: string ## for the operator's log only: paths and system errors

  RetiredItem* = object
    ## [R1] What a commit stopped naming: a record directory, or one generation of a record.
    rid*: string
    generation*: uint64 ## 0: the whole directory; else `m/record.<generation>`

  Retired* = object
    sequence*: uint64 ## the commit that retired it
    item*: RetiredItem

  Collected* = object
    deleted*: int
    failures*: seq[string]
      ## for the operator's log; each is tried again at the next collect
    failed*: seq[RetiredItem] ## not deleted: retired still, for the next collect
    refused*: seq[RetiredItem]
      ## [Fable's 5-5-4 check §1.4] named by the index: never deleted, and reported

  RecordFile* = object ## [G445] `m/record.<generation>`.
    record*: InstalledRecord
    generation*: uint64 ## from 1
    archiveDigest*: Blake3Digest ## the archive it was installed from (diagnostics)

  IndexEntry* = object ## [G445] One committed record.
    rid*: string
    generation*: uint64
    identity*: PackageIdentity

  InstalledIndex* = object ## [G445] `install/index`: the committed set.
    sequence*: uint64 ## commits so far
    records*: seq[IndexEntry] ## by identity: package name bytes, then version text bytes

# The contract schema ---------------------------------------------------------------

type PmContract = ref object
  set: SchemaSet
  model: SchemaModel
  files: SchemaSet ## `installed.cddl`, on its own
  filesModel: SchemaModel

proc loadContract(): Result[PmContract, string] =
  let c = ?pmContractSet()
  # [IMPL] An ordinary supporting schema, resolved against itself and the common schema
  # only: what it embeds from App A is checked against App A by `checkType`.
  let f = ?acceptContractSet(InstalledCddl, [], [], AcceptOptions())
  ok(
    PmContract(
      set: c.schemaSet,
      model: c.primary.model,
      files: f.schemaSet,
      filesModel: f.primary.model,
    )
  )

proc loadPinnedContract(): PmContract =
  let c = loadContract()
  doAssert c.isOk, "the pinned PACKAGE MANAGER App A schema does not load: " & c.error
  c.get

perThread(pmContract, PmContract, loadPinnedContract())
discard pmContract()

func contract(): PmContract =
  {.cast(noSideEffect).}:
    pmContract()

func checkType*(name: string, v: CborValue): Result[void, string] =
  ## `v` against the Package Manager's type `name`: App A's, or `installed.cddl`'s.
  let c = contract()
  let files = name.startsWith("lcn.")
  let found = (if files: c.filesModel else: c.model).find(name)
  if found.isNone:
    return err(
      (if files: "installed.cddl" else: "the Package Manager schema") & " has no " & name
    )
  let d = found.get
  (if files: c.files else: c.set).validatePath(0, d.body, v).isOkOr:
    var at = ""
    for seg in error:
      at.add("/" & seg.getText.get(toDiag(seg)))
    return err("not a valid " & name & " at " & (if at.len == 0: "/" else: at))
  ok()

# Building --------------------------------------------------------------------------

func isRid*(s: string): bool =
  ## [G444] 32 lowercase hexadecimal digits.
  s.len == RidChars and s.allCharsInSet({'0' .. '9', 'a' .. 'f'})

func variantIndex(m: Manifest, id: string): int =
  for i, v in m.variants:
    if v.id == id:
      return i
  -1

func installedArtifacts(v: PackageVariant): seq[InstalledArtifact] =
  for a in v.artifacts:
    result.add(InstalledArtifact(id: a.id, kind: a.kind, path: a.path, hash: a.hash))

func selectedModules(m: Manifest, v: PackageVariant): seq[ModuleDeclaration] =
  ## [SPEC PM §5 l.814-816, §7.1 l.966-968] The declarations whose implementation artifact
  ## occurs in `v`, in manifest order.
  for d in m.modules:
    for a in v.artifacts:
      if a.id == d.artifact:
        result.add(d)
        break

func installedRecord*(
    m: Manifest,
    commitment: ManifestCommitment,
    variant: PackageVariant,
    signer: PackageSigner,
    source: PackageSource,
    edges: seq[ResolvedDependency],
): InstalledRecord =
  ## [SPEC PM §5] The record of manifest `m` installed with `variant` selected, from the
  ## verification that accepted it: its signer and commitment.
  InstalledRecord(
    signer: signer,
    identity: m.identity,
    source: source,
    variant: variant.id,
    commitment: commitment,
    modules: selectedModules(m, variant),
    artifacts: installedArtifacts(variant),
    resolvedDependencies: edges,
  )

func installedRecord*(
    p: LgxPackage, source: PackageSource, edges: seq[ResolvedDependency]
): InstalledRecord =
  ## The record of an opened archive: the signer `openLgx`'s verification authenticated.
  installedRecord(
    p.verified.manifest, p.verified.commitment, p.variant, p.verified.packageSigner,
    source, edges,
  )

func matchesManifest*(
    r: InstalledRecord, m: Manifest, commitment: ManifestCommitment
): Result[void, string] =
  ## [SPEC PM §5, §10, §11 l.1337-1341] `r` is the record `m` gives with its variant
  ## selected: the same identity and commitment, the variant's artifacts as signed, its
  ## selected module declarations unchanged, and one edge per direct dependency, in order.
  if r.identity != m.identity:
    return err("the record's identity is not its manifest's")
  if r.commitment != commitment:
    return err("the record's manifest commitment is not its manifest's")
  let at = m.variantIndex(r.variant)
  if at < 0:
    return err("the record's variant is not one of its manifest's")
  let v = m.variants[at]
  if r.artifacts != installedArtifacts(v):
    return err("the record's artifacts are not its variant's as signed")
  let modules = selectedModules(m, v)
  if r.modules.len != modules.len:
    return err("the record's modules are not its variant's selected modules")
  for i in 0 ..< modules.len:
    if r.modules[i].value != modules[i].value:
      return err("module " & modules[i].module & " is not the signed declaration")
  if r.resolvedDependencies.len != m.dependencies.len:
    return err("the record has not one edge for each direct dependency")
  for i, d in m.dependencies:
    if r.resolvedDependencies[i].identity.package != d.package:
      return err("edge " & $i & " is not for dependency " & d.package)
  ok()

# Encoding --------------------------------------------------------------------------

func toCbor*(s: PackageSigner): CborValue =
  cborMap((cbor("profile"), cbor(s.profile)), (cbor("public_key"), cbor(s.key)))

func localPath*(base: string, a: InstalledArtifact): string =
  ## [SPEC PM §10; G444] One artifact file's installed location.
  base & a.path

func artifactValue(a: InstalledArtifact, base: string): CborValue =
  cborMap(
    (cbor("id"), cbor(a.id)),
    (cbor("kind"), cbor($a.kind)),
    (cbor("local_path"), cbor(localPath(base, a))),
    (cbor("hash"), cbor(a.hash)),
  )

func recordValue*(r: InstalledRecord, base: string): CborValue =
  ## [SPEC PM §5] The `installed_package_record`, its `local_path`s under `base`.
  var modules = newSeqOfCap[CborValue](r.modules.len)
  for d in r.modules:
    modules.add(d.value)
  var artifacts = newSeqOfCap[CborValue](r.artifacts.len)
  for a in r.artifacts:
    artifacts.add(artifactValue(a, base))
  var edges = newSeqOfCap[CborValue](r.resolvedDependencies.len)
  for e in r.resolvedDependencies:
    edges.add(e.toCbor)
  cborMap(
    (cbor("signer"), r.signer.toCbor),
    (cbor("identity"), r.identity.toCbor),
    (cbor("source"), r.source.toCbor),
    (cbor("variant"), cbor(r.variant)),
    (cbor("manifest_commitment"), r.commitment.toCbor),
    (cbor("modules"), CborValue(kind: ckArray, items: modules)),
    (cbor("artifacts"), CborValue(kind: ckArray, items: artifacts)),
    (cbor("resolved_dependencies"), CborValue(kind: ckArray, items: edges)),
  )

proc encodeRecordFile*(f: RecordFile): Result[seq[byte], string] =
  ## [G445] The record file, checked against `installed.cddl` before it is written.
  if f.generation == 0:
    return err("a record file's generation starts at 1")
  let rv = recordValue(f.record, "")
  ?checkType(InstalledRecordType, rv)
  let v = cborMap(
    (cbor("format"), cbor(FileFormat)),
    (cbor("record"), cbor(encodeCbor(rv))),
    (cbor("generation"), cbor(f.generation)),
    (cbor("archive_digest"), cbor(f.archiveDigest)),
  )
  ?checkType(RecordFileType, v)
  ok(encodeCbor(v))

func identityOrder*(a, b: PackageIdentity): int =
  ## [G445] The index's order: package name UTF-8 bytes, then version text bytes.
  let n = cmp(a.package, b.package)
  if n != 0:
    n
  else:
    cmp(a.version, b.version)

func checkEntries(entries: openArray[IndexEntry]): Result[void, string] =
  var rids: seq[string]
  for i, e in entries:
    if not e.rid.isRid:
      return
        err("index entry " & $e.identity & ": its rid is not 32 lowercase hex digits")
    if e.generation == 0:
      return err("index entry " & $e.identity & ": its generation is 0")
    if i > 0 and identityOrder(entries[i - 1].identity, e.identity) >= 0:
      return err("index entry " & $e.identity & " is out of order or repeated")
    rids.add(e.rid)
  rids.sort()
  for i in 1 ..< rids.len:
    if rids[i - 1] == rids[i]:
      return err("a rid repeats in the index")
  ok()

proc encodeIndex*(i: InstalledIndex): Result[seq[byte], string] =
  ## [G445] The index, its entries in identity order; each identity and each rid once, and
  ## the whole within `MaxIndexBytes`.
  var entries = i.records
  entries.sort(
    proc(a, b: IndexEntry): int =
      identityOrder(a.identity, b.identity)
  )
  ?checkEntries(entries)
  var items = newSeqOfCap[CborValue](entries.len)
  for e in entries:
    items.add(
      cborMap(
        (cbor("rid"), cbor(e.rid)),
        (cbor("generation"), cbor(e.generation)),
        (cbor("package"), cbor(e.identity.package)),
        (cbor("version"), cbor(e.identity.version)),
      )
    )
  let v = cborMap(
    (cbor("format"), cbor(FileFormat)),
    (cbor("sequence"), cbor(i.sequence)),
    (cbor("records"), CborValue(kind: ckArray, items: items)),
  )
  ?checkType(IndexType, v)
  let bytes = encodeCbor(v)
  if bytes.len > MaxIndexBytes:
    return err("the index would exceed " & $MaxIndexBytes & " bytes")
  ok(bytes)

# Decoding --------------------------------------------------------------------------

# Each value has been validated against the schema before these run, so the fields they
# read exist with the declared types.

func text(v: CborValue, key: string): string =
  v.lookup(key).get.getText.get

func items(v: CborValue, key: string): seq[CborValue] =
  v.lookup(key).get.items

func artifactKind(s: string): ArtifactKind =
  for k in ArtifactKind:
    if $k == s:
      return k

func signerOf(v: CborValue): PackageSigner =
  var key: PublicKey
  let raw = v.lookup("public_key").get.getBytes.get
  for i in 0 ..< PublicKeyBytes:
    key[i] = raw[i]
  PackageSigner(profile: v.text("profile"), key: key)

func digestOf(v: CborValue): Digest =
  let raw = v.getBytes.get
  for i in 0 ..< result.len:
    result[i] = raw[i]

proc decodeRecordFile*(
    bytes: openArray[byte], m: Manifest, commitment: ManifestCommitment
): Result[RecordFile, string] =
  ## [G445] A record file, checked against `installed.cddl`, its embedded record against App
  ## A, then against its signed manifest `m` with `commitment` (`matchesManifest`). Its module
  ## declarations are the manifest's.
  let v = decodeCbor(bytes).valueOr:
    return err("the record file is not one Logos deterministic-CBOR value")
  ?checkType(RecordFileType, v)
  let generation = v.lookup("generation").get.getUint64.get
  if generation == 0:
    return err("the record file's generation is 0")
  let rv = decodeCbor(v.lookup("record").get.getBytes.get).valueOr:
    return err("the record file's record is not one Logos deterministic-CBOR value")
  ?checkType(InstalledRecordType, rv)
  let identity = ?decodeIdentity(rv.lookup("identity").get)
  let source = ?decodeSource(rv.lookup("source").get)
  var r = InstalledRecord(
    signer: signerOf(rv.lookup("signer").get),
    identity: identity,
    source: source,
    variant: rv.text("variant"),
    commitment: ManifestCommitment.fromCbor(rv.lookup("manifest_commitment").get).get,
  )
  for a in rv.items("artifacts"):
    let path = a.text("local_path")
    checkArtifactPath(path).isOkOr:
      return err("artifact " & a.text("id") & ": its path is not a relative path")
    r.artifacts.add(
      InstalledArtifact(
        id: a.text("id"),
        kind: artifactKind(a.text("kind")),
        path: path,
        hash: digestOf(a.lookup("hash").get),
      )
    )
  for e in rv.items("resolved_dependencies"):
    r.resolvedDependencies.add(?decodeResolvedDependency(e))
  # The declarations are compared as values, in the record's order, then the manifest's
  # typed ones are kept.
  for x in rv.items("modules"):
    let name = x.text("module")
    var found = false
    for d in m.modules:
      if d.module == name:
        var copy = d
        copy.value = x
        r.modules.add(copy)
        found = true
    if not found:
      return err("the record names a module its manifest does not declare")
  ?matchesManifest(r, m, commitment)
  r.modules = selectedModules(m, m.variants[m.variantIndex(r.variant)])
  var digest: Blake3Digest
  let raw = v.lookup("archive_digest").get.getBytes.get
  for i in 0 ..< digest.len:
    digest[i] = raw[i]
  ok(RecordFile(record: r, generation: generation, archiveDigest: digest))

proc decodeIndex*(bytes: openArray[byte]): Result[InstalledIndex, string] =
  ## [G445] The index, checked against `installed.cddl`, then for order, uniqueness and
  ## the rid form.
  if bytes.len > MaxIndexBytes:
    return err("the index exceeds " & $MaxIndexBytes & " bytes")
  let v = decodeCbor(bytes).valueOr:
    return err("the index is not one Logos deterministic-CBOR value")
  ?checkType(IndexType, v)
  var i = InstalledIndex(sequence: v.lookup("sequence").get.getUint64.get)
  for e in v.items("records"):
    let identity =
      PackageIdentity(package: e.text("package"), version: e.text("version"))
    ?checkType(PackageIdentityType, identity.toCbor)
    discard ?decodeIdentity(identity.toCbor)
    i.records.add(
      IndexEntry(
        rid: e.text("rid"),
        generation: e.lookup("generation").get.getUint64.get,
        identity: identity,
      )
    )
  ?checkEntries(i.records)
  ok(i)

func due*(retired: openArray[Retired], oldestHeld: Opt[uint64]): seq[RetiredItem] =
  ## [R1] What a collect may delete: retired at or before `oldestHeld`, the oldest snapshot
  ## sequence still held (none: every retired item).
  for r in retired:
    if oldestHeld.isNone or r.sequence <= oldestHeld.get:
      result.add(r.item)

{.pop.}
