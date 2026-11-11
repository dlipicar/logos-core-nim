## PM §3, §4, §5, §8, §9, §11: the package manifest (`manifest.cbor`): decoding,
## validation and the manifest value commitment that the package signature
## binds. The schema is the mirrored PM §4 CDDL, accepted as a supporting
## schema; its roots are checked against the pinned PM §4 values when the
## module loads.

{.push raises: [].}

import std/[sets, strutils, tables]
import results
import ../base/[hex, perthread]
import ../cbor
import ../commitment
import ../hash
import ../iface/accept
import ./[errors, semver]

export results, errors, semver, hashinput

const
  ManifestNamespace* = "logos.package_manifest" ## [SPEC PM §4]
  ManifestType* = "logos.package_manifest.manifest" ## [SPEC PM §4]
  MaxManifestBytes* = 4 * 1024 * 1024 ## [SPEC PM §3] 4 MiB

type
  ArtifactKind* = enum
    akModuleBinary = "module-binary"
    akResource = "resource"
    akSchema = "schema"
    akData = "data"

  PlatformConstraint* = object
    os*, architecture*, abi*: Opt[string] ## none: no constraint (§7.1)

  ManifestArtifact* = object
    id*: string
    kind*: ArtifactKind
    path*: string ## relative to the variant directory (LGX) or output (Nix)
    hash*: Digest ## the hash suite over the artifact's exact bytes (§10)

  PackageVariant* = object
    id*: string
    platform*: PlatformConstraint
    artifacts*: seq[ManifestArtifact]

  ConfigurationDeclaration* = object
    schemaArtifact*: string
    root*: string
    schemaCommitment*: CborValue ## a `logos.schema_commitment`
    defaultArtifact*: Opt[string]
    liveReconfiguration*: bool

  RequestedPermission* = object
    permission*: string
    constraints*: seq[byte] ## one Logos deterministic-CBOR value (§11)
    reason*: Opt[string]

  ModuleDeclaration* = object
    module*: string
    artifact*: string ## the implementation artifact
    primaryContract*: Opt[CborValue] ## a `logos.schema_commitment`
    implements*: seq[CborValue] ## `logos.schema_commitment`s
    requires*: seq[CborValue] ## `provider_requirement`s
    requestedPermissions*: seq[RequestedPermission]
    configuration*: Opt[ConfigurationDeclaration]
    value*: CborValue ## the decoded declaration

  RequirementKind* = enum
    rkExact = "exact"
    rkCompatible = "compatible"

  PackageDependency* = object
    package*: string
    kind*: RequirementKind
    version*: string

  Manifest* = object
    package*: string
    version*: string
    modules*: seq[ModuleDeclaration]
    variants*: seq[PackageVariant] ## in declared order: it decides selection
    dependencies*: seq[PackageDependency]
    value*: CborValue ## the decoded manifest
    encoded*: seq[byte] ## its Logos deterministic-CBOR bytes (`manifest.cbor`)

  ManifestCommitment* = object
    ## [SPEC PM §4, §5] `logos.package_manager.manifest_commitment`.
    commitmentModel*: string
    schemaRoot*: Digest
    schemaSubtreeRoot*: Digest
    valueRoot*: Digest
    hashProfile*: string
    hashSuite*: string

# The pinned schema -----------------------------------------------------------------

type ManifestSchema = ref object
  contracts: ContractSet
  set: SchemaSet
  body: SchemaNode

proc loadManifestSchema(): Result[ManifestSchema, string] =
  let c =
    ?acceptContractSet(PackageManifestDocument, opts = AcceptOptions(system: true))
  let m = c.primary.model
  if m.role != srSupporting or m.namespace != ManifestNamespace:
    return err("PM §4 is not a supporting schema in " & ManifestNamespace)
  if c.primary.root.toHex != PackageManifestSchemaRoot:
    return err("the PM §4 schema root is not the pinned " & PackageManifestSchemaRoot)
  let d = m.find(ManifestType).valueOr:
    return err("PM §4 does not declare " & ManifestType)
  if declarationRoot(m, d).toHex != PackageManifestSubtreeRoot:
    return
      err("the manifest subtree root is not the pinned " & PackageManifestSubtreeRoot)
  ok(ManifestSchema(contracts: c, set: c.schemaSet, body: d.body))

proc loadPinnedManifestSchema(): ManifestSchema =
  let s = loadManifestSchema()
  doAssert s.isOk,
    "the pinned PM §4 manifest schema does not reproduce its pinned roots: " & s.error
  s.get

perThread(manifestSchema, ManifestSchema, loadPinnedManifestSchema())
discard manifestSchema()

func schema(): ManifestSchema =
  {.cast(noSideEffect).}:
    manifestSchema()

func manifestContracts*(): ContractSet =
  ## The accepted PM §4 schema document.
  schema().contracts

# Decoding --------------------------------------------------------------------------

func invalid(msg: string): PackageError =
  packageError(pecInvalidPackage, msg)

func integrity(msg: string): PackageError =
  packageError(pecArtifactIntegrity, msg)

func pathText(path: seq[CborValue]): string =
  var s = ""
  for seg in path:
    s.add("/")
    let t = seg.getText
    if t.isSome:
      s.add(t.get)
    else:
      s.add(toDiag(seg))
  if s.len == 0: "/" else: s

# The value has been validated against the schema before these run, so the
# fields they read exist with the declared types.

func field(v: CborValue, key: string): CborValue =
  v.lookup(key).get

func text(v: CborValue, key: string): string =
  v.field(key).getText.get

func optText(v: CborValue, key: string): Opt[string] =
  let f = v.lookup(key)
  if f.isNone:
    Opt.none(string)
  else:
    f.get.getText

func list(v: CborValue, key: string): seq[CborValue] =
  let f = v.lookup(key)
  if f.isNone:
    @[]
  else:
    f.get.items

func digest(b: seq[byte]): Digest =
  var d: Digest
  for i in 0 ..< DigestLen:
    d[i] = b[i]
  d

func artifactKind(s: string): ArtifactKind =
  case s
  of "module-binary": akModuleBinary
  of "resource": akResource
  of "schema": akSchema
  else: akData

func toManifest(v: CborValue, encoded: seq[byte]): Manifest =
  var m = Manifest(
    package: v.text("package"), version: v.text("version"), value: v, encoded: encoded
  )
  for x in v.list("modules"):
    var d = ModuleDeclaration(
      module: x.text("module"),
      artifact: x.text("artifact"),
      primaryContract: x.lookup("primary_contract"),
      implements: x.list("implements"),
      requires: x.list("requires"),
      value: x,
    )
    for p in x.list("requested_permissions"):
      d.requestedPermissions.add(
        RequestedPermission(
          permission: p.text("permission"),
          constraints: p.field("constraints").getBytes.get,
          reason: p.optText("reason"),
        )
      )
    let c = x.lookup("configuration")
    if c.isSome:
      let c = c.get
      d.configuration = Opt.some(
        ConfigurationDeclaration(
          schemaArtifact: c.text("schema_artifact"),
          root: c.text("root"),
          schemaCommitment: c.field("schema_commitment"),
          defaultArtifact: c.optText("default_artifact"),
          liveReconfiguration: c.lookup("live_reconfiguration").isSome,
        )
      )
    m.modules.add(d)
  for x in v.list("variants"):
    let p = x.field("platform")
    var variant = PackageVariant(
      id: x.text("id"),
      platform: PlatformConstraint(
        os: p.optText("os"),
        architecture: p.optText("architecture"),
        abi: p.optText("abi"),
      ),
    )
    for a in x.list("artifacts"):
      variant.artifacts.add(
        ManifestArtifact(
          id: a.text("id"),
          kind: artifactKind(a.text("kind")),
          path: a.text("path"),
          hash: digest(a.field("hash").getBytes.get),
        )
      )
    m.variants.add(variant)
  for x in v.list("dependencies"):
    let r = x.field("requirement")
    m.dependencies.add(
      PackageDependency(
        package: x.text("package"),
        kind: (if r.text("kind") == "exact": rkExact else: rkCompatible),
        version: r.text("version"),
      )
    )
  m

# Validation ------------------------------------------------------------------------

func increasing(keys: openArray[string]): bool =
  ## Strictly increasing by UTF-8 bytes: canonical order and no duplicates.
  for i in 1 ..< keys.len:
    if not (keys[i - 1] < keys[i]):
      return false
  true

func increasing(keys: openArray[seq[byte]]): bool =
  for i in 1 ..< keys.len:
    if cmpBytes(keys[i - 1], keys[i]) >= 0:
      return false
  true

func checkArtifactPath*(path: string): Result[void, string] =
  ## [SPEC PM §8] A manifest artifact path is relative, has no parent-directory
  ## traversal and names no remote resource. [IMPL] A backslash or a `:` in the
  ## first segment (a URL scheme or a drive letter) counts as leaving the
  ## variant.
  if path.startsWith("/"):
    return err("an absolute artifact path: " & path)
  if '\\' in path:
    return err("a backslash in an artifact path: " & path)
  let segments = path.split('/')
  if ':' in segments[0]:
    return err("an artifact path naming a remote or drive location: " & path)
  if ".." in segments:
    return err("a parent-directory segment in an artifact path: " & path)
  ok()

func checkVersion(what, v: string): Result[SemVer, PackageError] =
  parseSemVer(v).mapErr(
    proc(e: string): PackageError =
      invalid(what & " " & v & " is not a permitted package version: " & e)
  )

func checkManifest*(m: Manifest): Result[void, PackageError] =
  ## [SPEC PM §4, §5, §8, §9, §11] The rules the CDDL does not express.
  if m.variants.len == 0:
    return err(invalid("the variants array is empty"))
  discard ?checkVersion("the package version", m.version)

  var variantIds = initHashSet[string]()
  # artifact id -> the kinds it has in the variants where it occurs
  var where = initTable[string, seq[(int, ArtifactKind)]]()
  for vi, v in m.variants:
    if v.artifacts.len == 0:
      return err(invalid("variant " & v.id & " has no artifacts"))
    if variantIds.containsOrIncl(v.id):
      return err(invalid("duplicate variant id " & v.id))
    var ids: seq[string]
    for a in v.artifacts:
      ids.add(a.id)
      checkArtifactPath(a.path).isOkOr:
        return err(integrity("variant " & v.id & ": " & error))
      where.mgetOrPut(a.id, @[]).add((vi, a.kind))
    if not ids.increasing:
      return err(
        invalid("variant " & v.id & ": artifacts are not in id order, or an id repeats")
      )

  var names: seq[string]
  var implementations = initHashSet[string]()
  for d in m.modules:
    names.add(d.module)
    if implementations.containsOrIncl(d.artifact):
      return err(invalid("artifact " & d.artifact & " implements two modules"))
    let occurs = where.getOrDefault(d.artifact)
    if occurs.len == 0:
      return err(
        invalid("module " & d.module & ": artifact " & d.artifact & " is in no variant")
      )
    for (_, kind) in occurs:
      if kind != akModuleBinary:
        return err(
          integrity(
            "module " & d.module & ": artifact " & d.artifact & " has kind " & $kind
          )
        )
    for field in ["implements", "requires", "requested_permissions"]:
      let present = d.value.lookup(field)
      if present.isSome and present.get.items.len == 0:
        return err(invalid("module " & d.module & ": " & field & " is empty"))
    var keys: seq[seq[byte]]
    for c in d.implements:
      keys.add(encodeCbor(c))
    if not keys.increasing:
      return err(
        invalid(
          "module " & d.module &
            ": implements is not in commitment-byte order, or a commitment repeats"
        )
      )
    keys.setLen(0)
    for r in d.requires:
      keys.add(encodeCbor(r.field("contract")))
    if not keys.increasing:
      return err(
        invalid(
          "module " & d.module &
            ": requires is not in commitment-byte order, or a contract repeats"
        )
      )
    var perms: seq[string]
    for p in d.requestedPermissions:
      perms.add(p.permission)
      decodeCbor(p.constraints).isOkOr:
        return err(
          invalid(
            "module " & d.module & ": the constraints of " & p.permission &
              " are not one Logos deterministic-CBOR value"
          )
        )
    if not perms.increasing:
      return err(
        invalid(
          "module " & d.module &
            ": requested_permissions are not in name order, or a name repeats"
        )
      )
    if d.configuration.isSome:
      let c = d.configuration.get
      var needed = @[(c.schemaArtifact, akSchema)]
      if c.defaultArtifact.isSome:
        needed.add((c.defaultArtifact.get, akData))
      for (vi, _) in occurs:
        let v = m.variants[vi]
        for (id, kind) in needed:
          var found = false
          for a in v.artifacts:
            if a.id == id:
              found = true
              if a.kind != kind:
                return err(
                  integrity(
                    "module " & d.module & ": artifact " & id & " has kind " & $a.kind &
                      ", not " & $kind
                  )
                )
          if not found:
            return err(
              invalid(
                "module " & d.module & ": configuration artifact " & id &
                  " is missing from variant " & v.id
              )
            )
  if not names.increasing:
    return err(invalid("modules are not in name order, or a module repeats"))

  if m.value.lookup("dependencies").isSome and m.dependencies.len == 0:
    return err(invalid("the dependencies array is empty"))
  var deps: seq[string]
  for d in m.dependencies:
    deps.add(d.package)
    let v = ?checkVersion("the requirement of " & d.package, d.version)
    if d.kind == rkCompatible and v.isPrerelease:
      return err(
        invalid("a compatible requirement on " & d.package & " names a pre-release")
      )
  if not deps.increasing:
    return err(invalid("dependencies are not in name order, or a name repeats"))
  ok()

proc decodeManifest*(data: openArray[byte]): Result[Manifest, PackageError] =
  ## [SPEC PM §3, §4, §8] `manifest.cbor`: at most 4 MiB of Logos deterministic
  ## CBOR, valid under `logos.package_manifest.manifest`, and satisfying the
  ## ordering, uniqueness and reference rules.
  if data.len > MaxManifestBytes:
    return err(invalid("the manifest is larger than 4 MiB"))
  let v = decodeCbor(data).valueOr:
    return err(invalid("the manifest is not Logos deterministic CBOR: " & $error))
  let s = schema()
  s.set.validatePath(0, s.body, v).isOkOr:
    return err(
      invalid("the manifest does not match " & ManifestType & " at " & pathText(error))
    )
  let m = toManifest(v, @data)
  ?checkManifest(m)
  ok(m)

func checkIdentity*(m: Manifest, package, version: string): Result[void, PackageError] =
  ## [SPEC PM §8] The manifest names the selected package reference.
  if m.package != package or m.version != version:
    return err(
      invalid(
        "the manifest declares " & m.package & " " & m.version & ", not " & package & " " &
          version
      )
    )
  ok()

# The manifest value commitment ------------------------------------------------------

func commitment*(m: Manifest): Result[ManifestCommitment, PackageError] =
  ## [SPEC PM §4] The value commitment of the decoded manifest: the commitment
  ## model, the PM §4 schema root, the manifest subtree root, and the value
  ## root of the normalized value under the hash profile and suite.
  let r = schema().set.normalize(0, ManifestType, m.value).valueOr:
      return err(invalid("the manifest does not normalize: " & error))
  let root = valueRoot(r).valueOr:
    return err(invalid("the manifest has no value root: " & error))
  ok(
    ManifestCommitment(
      commitmentModel: r.modelId,
      schemaRoot: r.schemaRoot,
      schemaSubtreeRoot: r.subtreeRoot,
      valueRoot: root,
      hashProfile: HashProfileId,
      hashSuite: HashSuiteId,
    )
  )

func toCbor*(c: ManifestCommitment): CborValue =
  cborMap(
    (cbor("commitment_model"), cbor(c.commitmentModel)),
    (cbor("schema_root"), cbor(c.schemaRoot)),
    (cbor("schema_subtree_root"), cbor(c.schemaSubtreeRoot)),
    (cbor("value_root"), cbor(c.valueRoot)),
    (cbor("hash_profile"), cbor(c.hashProfile)),
    (cbor("hash_suite"), cbor(c.hashSuite)),
  )

func fromCbor*(T: type ManifestCommitment, v: CborValue): Opt[ManifestCommitment] =
  ## The fields of a value already validated as a `manifest_commitment`.
  func root(v: CborValue, key: string): Opt[Digest] =
    let b = v.lookup(key).get(cbor("")).getBytes.get(@[])
    if b.len != DigestLen:
      Opt.none(Digest)
    else:
      Opt.some(digest(b))

  if v.isNil or v.kind != ckMap:
    return Opt.none(ManifestCommitment)
  Opt.some(
    ManifestCommitment(
      commitmentModel: ?v.optText("commitment_model"),
      schemaRoot: ?v.root("schema_root"),
      schemaSubtreeRoot: ?v.root("schema_subtree_root"),
      valueRoot: ?v.root("value_root"),
      hashProfile: ?v.optText("hash_profile"),
      hashSuite: ?v.optText("hash_suite"),
    )
  )
