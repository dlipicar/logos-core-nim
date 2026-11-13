## CONFIG §2 and §5: accepting a configuration declaration, and checking one
## configuration value against an accepted binding (DECISIONS I87).
##
## Both run off the Runtime thread: acceptance on the thread that builds the
## module record (the host's, in `host_config.nim`, or a test harness), value
## checks on the caller's thread of `update_configuration` (I76: validation
## that needs only a schema runs where the request arrives). Each thread keeps
## at most `MaxValidators` validators, built from the document text alone and
## released when the thread ends.
##
## Acceptance (RUNTIME l.1386-1387, RUN-0259) keeps no schema graph: only plain
## values leave it, so an `AcceptedConfiguration` crosses threads as data.

{.push raises: [], gcsafe.}

import std/tables
import results
import ../base/perthread
import ../cbor
import ../codegen/nimrt
import ../commitment
import ../iface/[accept, payload]
import ./[config, rc_types]

export config

const MaxValidators* = 16 ## [IMPL] validators each thread keeps

type
  AcceptedValue* = object
    ## A complete value validated under its binding, with its value root.
    bytes*: seq[byte]
    valueRoot*: Digest

  AcceptedConfiguration* = object
    ## [SPEC CONFIG §2; RUNTIME l.1386-1387] A declaration's binding and its
    ## protected values, accepted. Only `acceptConfiguration` makes one; the
    ## fields are read through the accessors below.
    binding: LogosNSModuleConfigurationSchemaBinding
    roots: SchemaRoots
    digest: Digest
    default: Opt[AcceptedValue]
    provisioned: Opt[AcceptedValue]

  ValueFault* = enum
    vfMalformed
      ## [SPEC CONFIG §5 l.197] malformed, trailing bytes or not deterministic:
      ## INVALID_PARAMS without detail
    vfTooDeep
      ## [SPEC INTERFACE §4.5.1] over the payload depth limit: INVALID_PARAMS
      ## without detail
    vfMismatch
      ## [SPEC CONFIG §5 l.198-200] not a value of the root:
      ## `configuration-schema-mismatch`, with the path from the value's root

  ValueRejection* = object
    fault*: ValueFault
    path*: seq[CborValue] ## vfMismatch: from the decoded value's root

func binding*(a: AcceptedConfiguration): LogosNSModuleConfigurationSchemaBinding =
  a.binding

func roots*(a: AcceptedConfiguration): SchemaRoots =
  a.roots

func digest*(a: AcceptedConfiguration): Digest =
  ## The binding's identity (`bindingDigest`).
  a.digest

func live*(a: AcceptedConfiguration): bool =
  a.binding.live_reconfiguration.get(false)

func defaultValue*(a: AcceptedConfiguration): Opt[AcceptedValue] =
  a.default

func provisioned*(a: AcceptedConfiguration): Opt[AcceptedValue] =
  a.provisioned

# Values -----------------------------------------------------------------------------

proc checkWith(
    g: GeneratedSchema,
    root: string,
    subtree: Digest,
    bytes: openArray[byte],
    depth: int,
): Result[Digest, ValueRejection] =
  if bytes.len < 1 or bytes.len > MaxValueBytes:
    return err(ValueRejection(fault: vfMalformed))
  # [IF-02, I88] counted from the value's root, under the engine's setting
  let v = decodePayload(bytes, maxDepth = depth).valueOr:
    if error.reason.isNone:
      return err(ValueRejection(fault: vfTooDeep))
    if error.reason.get == iprSchemaMismatch:
      return err(ValueRejection(fault: vfMismatch, path: error.path))
    return err(ValueRejection(fault: vfMalformed))
  g.checkPath(root, v).isOkOr:
    return err(ValueRejection(fault: vfMismatch, path: error))
  let (sub, valueRoot) = g.commitment(root, v).valueOr:
    return err(ValueRejection(fault: vfMismatch))
  # [SPEC CONFIG l.118; CFG-0150] the value commitment's subtree root is the
  # binding's.
  if sub != subtree:
    return err(ValueRejection(fault: vfMismatch))
  ok(valueRoot)

proc schemaOf(document: string): Result[(ContractSet, GeneratedSchema), string] =
  ## [SPEC CONFIG §2 l.62-66] A supporting schema resolved against itself and
  ## the pinned common schema only: nothing is fetched or read.
  let set = acceptContractSet(document, [], [], AcceptOptions()).valueOr:
    return err("the configuration schema is not accepted: " & error)
  if set.primary.model.role != srSupporting:
    return err("the configuration schema is not a supporting schema")
  ok((set, loadSchemaSet(set)))

# This thread's validators ---------------------------------------------------------

var
  validators {.threadvar.}: Table[Digest, GeneratedSchema]
  validatorsHooked {.threadvar.}: bool

proc dropValidators() {.nimcall, gcsafe, raises: [].} =
  validators = default(Table[Digest, GeneratedSchema])
  validatorsHooked = false

proc checkValue*(
    digest: Digest,
    document: Blob,
    root: string,
    subtree: Digest,
    bytes: openArray[byte],
    depth = DefaultMaxDepth,
): Result[Digest, ValueRejection] =
  ## [SPEC CONFIG §5 l.197-200, l.204] The value root of `bytes`, a complete
  ## value under the binding `digest` (document, root, subtree root); or why
  ## it is not one. Rows 4 and 5 of the CONFIG §5 table.
  if not validatorsHooked:
    validatorsHooked = true
    onThreadRelease(dropValidators)
  if digest notin validators:
    let (_, g) = schemaOf(document.toText).valueOr:
      # [IMPL] An accepted binding's document is accepted again; anything
      # else is a value no schema admits.
      return err(ValueRejection(fault: vfMismatch))
    if validators.len >= MaxValidators:
      var first: Digest
      for k in validators.keys:
        first = k
        break
      validators.del(first)
    validators[digest] = g
  try:
    checkWith(validators[digest], root, subtree, bytes, depth)
  except KeyError:
    err(ValueRejection(fault: vfMismatch))

proc cachedValidators*(): int =
  ## This thread's validators (tests).
  validators.len

# Acceptance -------------------------------------------------------------------------

proc acceptConfiguration*(
    decl: LogosNSModuleConfigurationConfigurationDeclaration,
    provisioned = Opt.none(seq[byte]),
    depth = DefaultMaxDepth,
): Result[AcceptedConfiguration, string] =
  ## [SPEC CONFIG §2; RUNTIME l.1386-1387 (RUN-0259)] Accepts a declaration
  ## and the protected value provisioned for one instance (G141), if any:
  ## the document as a supporting schema alone (INTERFACE §5.3 limits; no
  ## I/O), the root a type it declares, both roots recomputed and equal to the
  ## declared ones, and the default and provisioned values complete values of
  ## the root. [IMPL] An invalid default or provisioned value rejects the
  ## declaration: CONFIG l.148-149 forbids partial state from an invalid
  ## source, and this is the earliest point.
  let b = decl.schema
  if b.live_reconfiguration.isSome and not b.live_reconfiguration.get:
    return err("live_reconfiguration is true when present")
  if b.root.len < 1 or b.root.len > MaxRootChars:
    return err("the configuration root must have 1 to 255 characters")
  if b.document.len < 1 or b.document.len > MaxDocumentChars:
    return err("the configuration schema must have 1 to 1048576 bytes")
  let (set, g) = ?schemaOf(b.document)
  let model = set.primary.model
  let d = model.find(b.root)
  if d.isNone or d.get.kind != dkType:
    # [SPEC CONFIG §2 l.77; CFG-0019]
    return err("the configuration root " & b.root & " is not a type of its schema")
  let declared = ?fromRc(b.schema_commitment)
  let roots = SchemaRoots(
    schemaRoot: schemaRoot(model), subtreeRoot: declarationRoot(model, d.get)
  )
  if roots.schemaRoot != declared.schemaRoot:
    # [SPEC CONFIG §2 l.74-76; CFG-0017]
    return err("the configuration schema root is not the declared one")
  if roots.subtreeRoot != declared.subtreeRoot:
    # [CFG-0018]
    return err("the configuration root's subtree root is not the declared one")
  var a = AcceptedConfiguration(binding: b, roots: roots, digest: bindingDigest(b))
  template checked(data: seq[byte], what: string): AcceptedValue =
    let root = checkWith(g, b.root, roots.subtreeRoot, data, depth).valueOr:
      return err("the " & what & " is not a complete value of " & b.root)
    AcceptedValue(bytes: data, valueRoot: root)

  if decl.default_value.isSome:
    a.default = Opt.some(checked(decl.default_value.get, "default value"))
  if provisioned.isSome:
    a.provisioned = Opt.some(checked(provisioned.get, "provisioned configuration"))
  ok(a)

proc acceptConfiguration*(
    declaration: openArray[byte],
    provisioned = Opt.none(seq[byte]),
    depth = DefaultMaxDepth,
): Result[AcceptedConfiguration, string] =
  ## The same, from one deterministic-CBOR
  ## `logos.module_configuration.configuration_declaration` (host config).
  let decl = LogosNSModuleConfigurationConfigurationDeclaration.decode(declaration).valueOr:
    return err("the configuration declaration is not one: " & error)
  acceptConfiguration(decl, provisioned, depth)

proc runtimeBinding*(a: AcceptedConfiguration): Binding =
  ## The binding a new configuration state is created with; the document
  ## blob has one reference, which the caller owns.
  Binding(
    document: newBlob(a.binding.document),
    root: a.binding.root,
    commitment: a.roots,
    live: a.live,
    digest: a.digest,
  )

proc initialState*(a: AcceptedConfiguration): ConfigState =
  ## [SPEC CONFIG §4 l.139-142; G141] A new instance's state, owning its
  ## blobs: the provisioned value staged as `protected-provisioning`, its
  ## value root remembered; else the default staged as `package-default`
  ## (CFG-0046); else revision 0 without a record. [IMPL] A provisioned value
  ## replaces the default in the same step, so the default is not staged
  ## first.
  result = newState(runtimeBinding(a))
  if a.provisioned.isSome:
    let v = a.provisioned.get
    result = result.withStaged(newBlob(v.bytes), v.valueRoot, pvProtectedProvisioning)
    result.lastProvisioned = Opt.some(v.valueRoot)
  elif a.default.isSome:
    let v = a.default.get
    result = result.withStaged(newBlob(v.bytes), v.valueRoot, pvPackageDefault)
