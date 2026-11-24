## The Runtime handoff's construction and the package's configuration declarations (Tier 5 step
## 5-5-1; DECISIONS G451; docs/PACKAGE-MANAGER.md §13; PACKAGE MANAGER §4 l.362-364, §12
## l.1381-1449, §4.3 l.539).
##
## - **`resolveConfiguration`** builds the configuration-owned declaration from a signed module
##   declaration's `configuration` and its verified schema and default bytes (PM l.1415-1423): the
##   schema document from the schema artifact's text; the root and live support copied; the
##   commitment's document fields copied, with the subtree root derived for that root; the default
##   value only when a default artifact is declared. The result must pass
##   `runtime/configcheck.acceptConfiguration`, which recomputes both roots and checks the default
##   as one complete value of the root (PKG-0344).
## - **PKG-0060** is the same construction at inspection (`checkConfigurations`): an archive whose
##   selected module's declaration does not resolve is `invalid-package`. It runs after `openLgx`
##   or `inspectLgx`, so last in G29/P7a order, on the selected variant's selected modules only,
##   from the documents the reader kept (G446).
## - **`buildHandoff`** builds `runtime_handoff` for one selected module of an installed record:
##   the retained signer (PKG-0438), the flat module name (PKG-0348), the record's identity and the
##   implementation artifact's id and `local_path` (PKG-0340), its hash from the signed manifest
##   (PKG-0341), the exact manifest commitment (PKG-0339), the declaration's `primary_contract`,
##   `implements`, `extends`, `requires` and `requested_permissions` copied as signed (PKG-0347,
##   G391), and the configuration declaration (PKG-0342 to 0344). It is refused while the retained
##   signer is not accepted by active trust (PKG-0341, PKG-0080).
## - **`admissionHandoffs`** is every selected module's handoff without the trust check, for the
##   admission bound (G452), whose sizes do not depend on trust.
## - **Messages** (PKG-0360) name only the identity, the module and artifact ids and the cause.
##   What a read reported, which may hold a path, goes to `detail`, for the operator's log only.

{.push raises: [].}

import std/tables
import results
import logos_sdk/cbor
import logos_sdk/commitment
import logos_sdk/crypto/blake3
import logos_sdk/iface/accept
import logos_sdk/kit/rc_types
import ../package/[errors, lgx, manifest, records, signing, trust]
import ../runtime/configcheck
import ./installed

export results, installed

type
  HandoffRefusal* = enum
    hrNotInstalled = "not installed"
    hrNotSelected = "not a selected module"
    hrSignerNotAccepted = "signer not accepted"
    hrArtifactIntegrity = "artifact bytes absent or changed"
    hrConfiguration = "configuration not accepted"
    hrStateDamaged = "installed state damaged"

  HandoffError* = object
    refusal*: HandoffRefusal
    msg*: string ## public: the identity, module and artifact ids, and the cause
    detail*: string ## for the operator's log only: what a read reported

  ArtifactReader* =
    proc(a: InstalledArtifact): Result[seq[byte], string] {.gcsafe, raises: [].}
    ## One installed artifact's bytes, as they are now: the worker's read of its `local_path`
    ## in the engine, an archive's verified entry at admission. The error says why there are
    ## none, and may name a path.

func code*(r: HandoffRefusal): Opt[PackageErrorCode] =
  ## [G451; SPEC PM §14] The package error each refusal is, for `get_runtime_handoff` and the
  ## test probe. A damaged installed state is no package error: it is `MODULE_ERROR`
  ## (PKG-0362).
  case r
  of hrNotInstalled:
    Opt.some(pecPackageNotInstalled)
  of hrNotSelected:
    Opt.some(pecInvalidRequest)
  of hrSignerNotAccepted:
    Opt.some(pecSignature)
  of hrArtifactIntegrity:
    Opt.some(pecArtifactIntegrity)
  of hrConfiguration:
    Opt.some(pecInvalidPackage)
  of hrStateDamaged:
    Opt.none(PackageErrorCode)

func refusal(r: HandoffRefusal, msg: string, detail = ""): HandoffError =
  HandoffError(refusal: r, msg: msg, detail: detail)

# The configuration declaration ---------------------------------------------------------

func text(v: CborValue, key: string): string =
  v.lookup(key).get.getText.get

proc resolveConfiguration*(
    c: ConfigurationDeclaration, schema: openArray[byte], default: Opt[seq[byte]]
): Result[LogosNSModuleConfigurationConfigurationDeclaration, string] =
  ## [SPEC PM §12 l.1415-1423, §4 l.362-364] The configuration-owned declaration of the signed
  ## `c`, from the verified bytes of its schema artifact and of its default artifact when one is
  ## declared, accepted under LOGOS-MODULE-CONFIGURATION.
  if schema.len < 1 or schema.len > MaxDocumentChars:
    return err("the configuration schema must have 1 to 1048576 bytes")
  if not isValidUtf8(schema):
    return err("the configuration schema is not UTF-8 text")
  var document = newString(schema.len)
  for i, b in schema:
    document[i] = char(b)
  # The subtree root derived for the root: acceptance below recomputes it, and the schema root,
  # from the same text.
  let set = acceptContractSet(document, [], [], AcceptOptions()).valueOr:
    return err("the configuration schema is not accepted: " & error)
  let model = set.primary.model
  let d = model.find(c.root)
  if d.isNone or d.get.kind != dkType:
    return err("the configuration root " & c.root & " is not a type of its schema")
  let declared = c.schemaCommitment
  let decl = LogosNSModuleConfigurationConfigurationDeclaration(
    schema: LogosNSModuleConfigurationSchemaBinding(
      document: document,
      root: c.root,
      schema_commitment: LogosNSModuleConfigurationSchemaCommitment(
        commitment_model: declared.text("commitment_model"),
        schema_root: declared.lookup("schema_root").get.getBytes.get,
        schema_subtree_root: @(declarationRoot(model, d.get)),
        hash_profile: declared.text("hash_profile"),
        hash_suite: declared.text("hash_suite"),
      ),
      live_reconfiguration:
        if c.liveReconfiguration:
          Opt.some(true)
        else:
          Opt.none(bool),
    ),
    default_value: default,
  )
  discard ?acceptConfiguration(decl)
  ok(decl)

func document(p: LgxPackage, id: string): Opt[seq[byte]] =
  ## A configuration artifact the reader kept: one of the selected variant's, whose hash it
  ## checked (G446).
  if id in p.documents:
    Opt.some(p.documents.getOrDefault(id))
  else:
    Opt.none(seq[byte])

proc checkConfigurations*(p: LgxPackage): Result[void, PackageError] =
  ## [SPEC PM §4 l.362-364 (PKG-0060); G451] Each selected module's configuration declaration
  ## resolves from the selected variant's verified artifacts; otherwise `invalid-package`.
  for d in p.modules:
    if d.configuration.isNone:
      continue
    let c = d.configuration.get
    # The manifest places both artifacts, with their kinds, wherever the module's artifact
    # occurs; the reader verified their hashes and kept them as documents (G446).
    let schema = p.document(c.schemaArtifact).valueOr:
      return err(
        packageError(
          pecArtifactIntegrity,
          "module " & d.module & ": artifact " & c.schemaArtifact & " is absent",
        )
      )
    var default = Opt.none(seq[byte])
    if c.defaultArtifact.isSome:
      default = p.document(c.defaultArtifact.get)
      if default.isNone:
        return err(
          packageError(
            pecArtifactIntegrity,
            "module " & d.module & ": artifact " & c.defaultArtifact.get & " is absent",
          )
        )
    discard resolveConfiguration(c, schema, default).valueOr:
      return err(packageError(pecInvalidPackage, "module " & d.module & ": " & error))
  ok()

# The handoff -----------------------------------------------------------------------------

proc verifiedBytes(
    r: InstalledRecord, id: string, read: ArtifactReader
): Result[seq[byte], HandoffError] =
  ## [SPEC PM §4 l.362-363, §12 l.1420-1421] An artifact's bytes, checked against its signed
  ## digest before anything parses them.
  for a in r.artifacts:
    if a.id == id:
      let bytes = read(a).valueOr:
        return err(
          refusal(
            hrArtifactIntegrity,
            "artifact " & id & " of " & $r.identity & " is absent",
            error,
          )
        )
      if blake3(bytes) != a.hash:
        return err(
          refusal(
            hrArtifactIntegrity,
            "artifact " & id & " of " & $r.identity & " does not match its signed digest",
          )
        )
      return ok(bytes)
  err(
    refusal(
      hrStateDamaged, "artifact " & id & " is not in the record of " & $r.identity
    )
  )

const CopiedFields =
  ["primary_contract", "implements", "extends", "requires", "requested_permissions"]
  ## [SPEC PM §12 l.1434-1435] carried exactly as signed, when the declaration has them

proc construct(
    r: InstalledRecord, base: string, d: ModuleDeclaration, read: ArtifactReader
): Result[CborValue, HandoffError] =
  ## The `runtime_handoff` of the selected declaration `d` of `r`, whose artifacts are under
  ## `base`. `r` matches its signed manifest.
  var impl = -1
  for i, a in r.artifacts:
    if a.id == d.artifact:
      impl = i
  if impl < 0:
    return err(
      refusal(
        hrStateDamaged, "module " & d.module & " has no artifact in " & $r.identity
      )
    )
  let a = r.artifacts[impl]
  var entries = @[
    (cbor("signer"), r.signer.toCbor),
    (cbor("module"), cbor(d.module)),
    (cbor("package"), r.identity.toCbor),
    (
      cbor("artifact"),
      cborMap(
        (cbor("id"), cbor(a.id)),
        (cbor("local_path"), cbor(localPath(base, a))),
        # [PKG-0341] the signed digest (matchesManifest: the record's are the manifest's)
        (cbor("hash"), cbor(a.hash)),
        # [SPEC PM §10 l.1165] the suite the manifest commitment names
        (cbor("hash_suite"), cbor(r.commitment.hashSuite)),
      ),
    ),
    (cbor("manifest_commitment"), r.commitment.toCbor),
  ]
  for key in CopiedFields:
    let f = d.value.lookup(key)
    if f.isSome:
      entries.add((cbor(key), f.get))
  if d.configuration.isSome:
    let c = d.configuration.get
    let schema = ?r.verifiedBytes(c.schemaArtifact, read)
    var default = Opt.none(seq[byte])
    if c.defaultArtifact.isSome:
      default = Opt.some(?r.verifiedBytes(c.defaultArtifact.get, read))
    let decl = resolveConfiguration(c, schema, default).valueOr:
      return err(
        refusal(
          hrConfiguration, "module " & d.module & " of " & $r.identity & ": " & error
        )
      )
    entries.add((cbor("configuration"), decl.toCbor))
  ok(CborValue(kind: ckMap, entries: entries))

proc matched(
    r: InstalledRecord, m: Manifest, commitment: ManifestCommitment
): Result[void, HandoffError] =
  r.matchesManifest(m, commitment).isOkOr:
    return err(
      refusal(
        hrStateDamaged,
        "the record of " & $r.identity & " is not its signed manifest's",
        error,
      )
    )
  ok()

proc buildHandoff*(
    r: InstalledRecord,
    base: string,
    m: Manifest,
    commitment: ManifestCommitment,
    module: string,
    trust: TrustInput,
    read: ArtifactReader,
): Result[CborValue, HandoffError] =
  ## [SPEC PM §12] The `runtime_handoff` of `module` in record `r`, whose artifacts are under
  ## `base`, from its signed manifest `m` with `commitment`, under the active `trust`.
  ?r.matched(m, commitment)
  var at = -1
  for i, d in r.modules:
    if d.module == module:
      at = i
  if at < 0:
    return err(
      refusal(
        hrNotSelected,
        "module " & module & " is not a selected module of " & $r.identity,
      )
    )
  # [PKG-0341, PKG-0080] Never emitted while the retained signer is not accepted.
  if not trust.accepts(r.signer, r.identity.package):
    return err(
      refusal(
        hrSignerNotAccepted,
        "the retained signer of " & $r.identity &
          " is not accepted by active signing trust",
      )
    )
  r.construct(base, r.modules[at], read)

proc admissionHandoffs*(
    r: InstalledRecord,
    base: string,
    m: Manifest,
    commitment: ManifestCommitment,
    read: ArtifactReader,
): Result[seq[(string, Result[CborValue, HandoffError])], HandoffError] =
  ## [SPEC PM §5 l.824-830; G452] Each selected module's handoff as `buildHandoff` gives it
  ## under a trust input that accepts the retained signer, or why it cannot be built, for the
  ## admission bound: its size does not depend on trust.
  ?r.matched(m, commitment)
  var handoffs: seq[(string, Result[CborValue, HandoffError])]
  for d in r.modules:
    handoffs.add((d.module, r.construct(base, d, read)))
  ok(handoffs)

{.pop.}
