## COMMITMENT §3.1, §5: Logos schema-model construction.
##
## From one schema document's source text, through cdCDDLe, to its Logos canonical
## schema model: role, namespace, declaration kinds, synthesized methods, node
## translation, imported references and implemented-interface roots.
##
## Every choice must have a structural selection plan (`choice.nim`). The
## INTERFACE §1 acceptance rules beyond those §3.1 states are in
## `iface/accept.nim`, which builds through this module.

{.push raises: [].}

import std/[algorithm, sequtils, sets, strutils, tables]
import ../cbor
import ../cddl
import ../cddl/syntax
import ../hash/hashinput
import ../pins
import ../base/hex
import ./[schema, choice]

export schema, choice

type
  ImportTarget = object
    root, subtree: Digest
    kind: DeclKind

  SchemaContext* = object ## What a document may depend on [SPEC COMMITMENT §3.1, §5].
    commonRoot*: Digest
    common*: seq[(string, DeclKind, Digest)] ## the pinned registry
    commonModel*: SchemaModel
      ## the pinned common schema document, for following references to it when
      ## building selection plans; its roots never replace the registry's
    supporting*: seq[SchemaModel] ## explicitly supplied supporting schemas
    interfaces*: seq[SchemaModel] ## interface documents named by `_implements`

const
  MetadataNames* = ["_module", "_interface", "_implements"]
  PreludeAliases* = {skUint8 .. skInt64}
    ## [SPEC INTERFACE §1.3] the fixed-width integer aliases, named as their kinds.

func parseDeclKind*(s: string): Opt[DeclKind] =
  ## The COMMITMENT §5 registry spells kinds with spaces ("method request").
  for k in DeclKind:
    if $k == s or ($k).replace('-', ' ') == s:
      return Opt.some(k)
  Opt.none(DeclKind)

func toDigestHex(s: string): Digest =
  let bytes = hex.fromHex(s).get
  doAssert bytes.len == DigestLen
  var d: Digest
  for i in 0 ..< DigestLen:
    d[i] = bytes[i]
  d

func preludeAlias*(name: string): Opt[ScalarKind] =
  let k = parseScalarKind(name)
  if k.isSome and k.get in PreludeAliases:
    k
  else:
    Opt.none(ScalarKind)

func isPreludeBody(kind: ScalarKind, t: CddlType): bool =
  ## [SPEC INTERFACE §1.3] `uintN = uint .size (N/8)`, `intN = -2^(N-1)..2^(N-1)-1`.
  case kind
  of skUint8 .. skUint64:
    let bytes =
      case kind
      of skUint8: 1'u64
      of skUint16: 2'u64
      of skUint32: 4'u64
      else: 8'u64
    t.kind == tkSize and t.target == pUint and t.controller.kind == tkLiteral and
      t.controller.literal == uintLiteral(bytes)
  of skInt8 .. skInt64:
    let bits =
      case kind
      of skInt8: 8
      of skInt16: 16
      of skInt32: 32
      else: 64
    t.kind == tkRange and t.low == nintLiteral((1'u64 shl (bits - 1)) - 1) and
      t.high == uintLiteral((1'u64 shl (bits - 1)) - 1)
  else:
    false

# Namespace and classification ----------------------------------------------------

func namespaceOf*(names: openArray[string]): Result[string, string] =
  ## [SPEC COMMITMENT §3.1 step 2] The longest common dot-segment prefix; at
  ## least one segment, and a proper prefix of every name. [IMPL-DECISION G4]
  ## Every name is that namespace plus exactly one segment.
  if names.len == 0:
    return err("the document declares nothing")
  var prefix = names[0].split('.')
  prefix.setLen(prefix.len - 1)
  for n in names:
    let segs = n.split('.')
    var i = 0
    while i < prefix.len and i < segs.len - 1 and prefix[i] == segs[i]:
      inc i
    prefix.setLen(i)
  if prefix.len == 0:
    return err("declarations share no namespace")
  let ns = prefix.join(".")
  for n in names:
    if n.split('.').len != prefix.len + 1:
      return err(n & " is not one segment below the namespace " & ns & " (G4)")
  ok(ns)

func classify(role: SchemaRole, name: string): DeclKind =
  ## [SPEC COMMITMENT §3.1 step 3]
  if role == srSupporting:
    dkType
  elif name.endsWith("_request"):
    dkRequest
  elif name.endsWith("_response"):
    dkResponse
  elif name.endsWith("_event"):
    dkEvent
  else:
    dkType

# Node translation ----------------------------------------------------------------

type Builder = object
  role: SchemaRole
  local: Table[string, DeclKind]
  imports: Table[string, ImportTarget]

func translate(b: Builder, t: CddlType): Result[SchemaNode, string] =
  ## [SPEC COMMITMENT §3.1] cdCDDLe node to Logos `schema-node`; anything
  ## without a mapping is invalid.
  case t.kind
  of tkReference:
    let alias = preludeAlias(t.name)
    if alias.isSome and t.name notin b.local:
      return ok(SchemaNode(kind: snPrimitive, scalar: alias.get))
    if t.name in b.local:
      if b.local.getOrDefault(t.name) != dkType:
        return err("a schema node references the callable declaration " & t.name)
      return ok(SchemaNode(kind: snLocalRef, target: t.name))
    if t.name in b.imports:
      let target = b.imports.getOrDefault(t.name)
      if target.kind != dkType:
        return err(t.name & " is not a named type (G6)")
      return ok(
        SchemaNode(
          kind: snImportedRef,
          imported: SchemaImport(root: target.root, subtree: target.subtree),
        )
      )
    err("unresolved reference " & t.name)
  of tkPrimitive:
    case t.primitive
    of pBool:
      ok(SchemaNode(kind: snPrimitive, scalar: skBool))
    of pTstr:
      ok(SchemaNode(kind: snPrimitive, scalar: skTstr))
    of pBstr:
      ok(SchemaNode(kind: snPrimitive, scalar: skBstr))
    of pUint:
      err("bare uint has no Logos mapping; use a prelude integer alias")
  of tkLiteral:
    let l = t.literal
    case l.kind
    of lkBool:
      ok(SchemaNode(kind: snLiteral, literal: boolScalar(l.boolean)))
    of lkTstr:
      ok(SchemaNode(kind: snLiteral, literal: textScalar(l.text)))
    of lkUint:
      ok(SchemaNode(kind: snLiteral, literal: uintScalar(skUint64, l.uint)))
    of lkNint:
      if l.nint > uint64(high(int64)):
        return err("negative literal below the int64 range")
      ok(SchemaNode(kind: snLiteral, literal: intScalar(skInt64, -int64(l.nint) - 1)))
    of lkBstr:
      err("a byte-string literal is invalid in a schema declaration")
  of tkArray:
    if t.members.len == 1 and t.members[0].occurrence == occUnbounded:
      return ok(SchemaNode(kind: snList, element: ?b.translate(t.members[0].typ)))
    var node = SchemaNode(kind: snTuple)
    for m in t.members:
      if m.occurrence != occOne:
        return err("an array is either [* T] or a fixed tuple")
      node.items.add(?b.translate(m.typ))
    ok(node)
  of tkMap:
    var node = SchemaNode(kind: snMap)
    for m in t.members:
      if m.occurrence == occUnbounded:
        return err("a map member cannot repeat")
      node.fields.add(
        SchemaField(
          name: m.key.get,
          optional: m.occurrence == occOptional,
          node: ?b.translate(m.typ),
        )
      )
    # cdCDDLe already sorts members by key; §9.1 asks for UTF-8 byte order.
    node.fields.sort(
      proc(a, c: SchemaField): int =
        cmp(a.name, c.name)
    )
    ok(node)
  of tkChoice:
    var node = SchemaNode(kind: snChoice)
    for a in t.alternatives:
      node.arms.add(?b.translate(a))
    if not sortArms(node.arms):
      return err("two choice arms have the same canonical schema node")
    ok(node)
  of tkRange:
    err("an integer range has no Logos mapping outside the prelude")
  of tkSize:
    if t.target notin {pTstr, pBstr}:
      return err(".size applies only to tstr and bstr")
    let scalar = if t.target == pTstr: skTstr else: skBstr
    let c = t.controller
    let bounds =
      if c.kind == tkLiteral and c.literal.kind == lkUint:
        (c.literal.uint, c.literal.uint)
      elif c.kind == tkRange and c.low.kind == lkUint and c.high.kind == lkUint:
        (c.low.uint, c.high.uint)
      else:
        return err("a .size bound is not a non-negative integer")
    if bounds[0] > bounds[1]:
      return err("a .size minimum exceeds its maximum")
    ok(SchemaNode(kind: snPrimitive, scalar: scalar, size: Opt.some(bounds)))

func isMapLike(n: SchemaNode): bool =
  ## [SPEC COMMITMENT §3.1 step 5] a map, or a choice whose every arm is a map.
  n.kind == snMap or
    (n.kind == snChoice and n.arms.len > 0 and n.arms.allIt(it.kind == snMap))

# Construction --------------------------------------------------------------------

func implementedRoots(t: CddlType, ctx: SchemaContext): Result[seq[Digest], string] =
  ## [SPEC COMMITMENT §3.1 step 7] One root per byte-string literal element of a
  ## nonempty fixed array; each names exactly one supplied interface document.
  ## [SPEC INTERFACE §1.2] The roots are in strictly ascending raw-byte order.
  if t.kind != tkArray or t.members.len == 0:
    return err("_implements is not a nonempty fixed array")
  var
    roots: seq[Digest]
    namespaces: HashSet[string]
  for m in t.members:
    let x = m.typ
    if m.occurrence != occOne or x.kind != tkLiteral or x.literal.kind != lkBstr or
        x.literal.bytes.len != DigestLen:
      return err("_implements holds something other than 32-byte byte-string literals")
    var d: Digest
    for i in 0 ..< DigestLen:
      d[i] = x.literal.bytes[i]
    if d in roots:
      return err("_implements names a root twice")
    if roots.len > 0 and cmpBytes(roots[^1], d) >= 0:
      return err("_implements roots are not in strictly ascending order")
    var found = 0
    for doc in ctx.interfaces:
      if doc.role == srInterface and schemaRoot(doc) == d:
        inc found
        if namespaces.containsOrIncl(doc.namespace):
          return err("two implemented interfaces declare namespace " & doc.namespace)
    if found != 1:
      return
        err("_implements root " & toHex(d) & " names no supplied interface document")
    roots.add(d)
  ok(roots)

func schemaSetFor*(m: SchemaModel, ctx: SchemaContext): SchemaSet =
  ## `m` and the dependency documents its references may reach (§3.1 step 6).
  var set = schemaSet(m)
  if m.role != srCommon:
    set.addDocument(ctx.commonModel, ctx.commonRoot, ctx.common.mapIt((it[0], it[2])))
  if m.role == srModule:
    for doc in ctx.supporting:
      set.addDocument(
        doc,
        schemaRoot(doc),
        doc.declarations.mapIt((it.name, declarationRoot(doc, it))),
      )
  set

proc buildSchema*(
    source: string, ctx: SchemaContext, role = Opt.none(SchemaRole)
): Result[SchemaModel, string] =
  ## [SPEC COMMITMENT §3.1] One document's Logos canonical schema model. `role`
  ## is given only for the pinned common schema document (`srCommon`); other
  ## roles come from the document's metadata.
  let rules = parseSource(source).valueOr:
    return err("cdCDDLe: " & $error)
  var defined: HashSet[string]
  for r in rules:
    defined.incl(r.name)
  # Step 1: role.
  let theRole =
    if role.isSome:
      role.get
    elif "_module" in defined and "_interface" in defined:
      return err("a document cannot be both a module and an interface")
    elif "_module" in defined:
      srModule
    elif "_interface" in defined:
      srInterface
    else:
      srSupporting
  if "_implements" in defined and theRole != srModule:
    return err("only a concrete module schema has _implements")
  for doc in ctx.supporting & ctx.interfaces:
    # [SPEC COMMITMENT §6] No compatibility profile is defined: a dependency built
    # under another commitment-model revision is not in this document's domain.
    if doc.modelId != CommitmentModelId:
      return err("a dependency uses commitment model " & doc.modelId)
  # Names a reference may resolve to outside the document (cdCDDLe G14 scope).
  var b = Builder(role: theRole)
  for (name, kind, root) in ctx.common:
    if name notin defined and theRole != srCommon:
      b.imports[name] = ImportTarget(root: ctx.commonRoot, subtree: root, kind: kind)
  if theRole == srModule:
    for doc in ctx.supporting:
      if doc.role != srSupporting:
        return err("a supplied supporting schema has role " & $doc.role)
      let root = schemaRoot(doc)
      for d in doc.declarations:
        if d.name in b.imports:
          return err(d.name & " is defined by two dependencies")
        b.imports[d.name] =
          ImportTarget(root: root, subtree: declarationRoot(doc, d), kind: d.kind)
  var scope: seq[string]
  for k in PreludeAliases:
    if $k notin defined:
      scope.add($k)
  for name in b.imports.keys:
    scope.add(name)
  let doc = canonicalize(source, rules, scope).valueOr:
    return err("cdCDDLe: " & $error)
  # Steps 2-3: local declarations, namespace, kinds.
  var
    locals: seq[Rule]
    metadata: Table[string, CddlType]
  for r in doc.rules:
    if r.name in MetadataNames:
      metadata[r.name] = r.typ
    elif theRole == srCommon and preludeAlias(r.name).isSome:
      if not isPreludeBody(preludeAlias(r.name).get, r.typ):
        return err("prelude alias " & r.name & " has a different definition")
    else:
      locals.add(r)
  var names: seq[string]
  for r in locals:
    names.add(r.name)
  let ns = ?namespaceOf(names)
  if "_interface" in metadata:
    let t = metadata.getOrDefault("_interface")
    if t.kind != tkLiteral or t.literal.kind != lkTstr or t.literal.text != ns:
      return err("_interface does not name the namespace " & ns)
  for r in locals:
    b.local[r.name] = classify(theRole, r.name)
  # Steps 4-6: methods and bodies.
  var model = SchemaModel(modelId: CommitmentModelId, role: theRole, namespace: ns)
  if "_module" in metadata:
    let t = metadata.getOrDefault("_module")
    if t.kind == tkLiteral and t.literal.kind == lkTstr:
      model.moduleName = Opt.some(t.literal.text)
  var taken: HashSet[string]
  for r in locals:
    let kind = b.local.getOrDefault(r.name)
    let body = ?b.translate(r.typ)
    if kind != dkType and not body.isMapLike:
      return err(r.name & " must be a map or a choice of maps")
    case kind
    of dkRequest:
      model.declarations.add(Declaration(kind: dkRequest, name: r.name, body: body))
    of dkResponse:
      model.declarations.add(Declaration(kind: dkResponse, name: r.name, body: body))
    of dkEvent:
      model.declarations.add(Declaration(kind: dkEvent, name: r.name, body: body))
    else:
      model.declarations.add(Declaration(kind: dkType, name: r.name, body: body))
    taken.incl(r.name)
  for r in locals:
    let kind = b.local.getOrDefault(r.name)
    if kind in {dkRequest, dkResponse}:
      let
        base = r.name[0 ..< r.name.rfind('_')]
        other = base & (if kind == dkRequest: "_response" else: "_request")
      if other notin b.local or b.local.getOrDefault(other) == kind:
        return err(r.name & " has no matching " & other)
      if kind == dkRequest:
        if taken.containsOrIncl(base):
          return err("method " & base & " collides with another declaration")
        model.declarations.add(
          Declaration(kind: dkMethod, name: base, request: r.name, response: other)
        )
  # Step 7: implemented interfaces.
  if "_implements" in metadata:
    model.implemented = ?implementedRoots(metadata.getOrDefault("_implements"), ctx)
  if theRole == srModule:
    # [SPEC INTERFACE §1.2] An unused interface document makes the module invalid.
    for doc in ctx.interfaces:
      if schemaRoot(doc) notin model.implemented:
        return err("the supplied interface " & doc.namespace & " is not in _implements")
  # Step 8: canonical order.
  model.declarations.sort(
    proc(a, c: Declaration): int =
      cmp(a.name, c.name)
  )
  # Every choice is separable by a structural selection plan, following
  # references into the documents this one imports from.
  ?checkChoices(schemaSetFor(model, ctx))
  ok(model)

proc buildCommonSchema*(source: string): Result[SchemaModel, string] =
  ## The pinned common schema document (INTERFACE §5.1) as a model.
  buildSchema(source, SchemaContext(), Opt.some(srCommon))

let pinned = block:
  var ctx = SchemaContext(commonRoot: toDigestHex(CommonSchemaRoot))
  for (name, kind, root) in CommonRegistry:
    ctx.common.add((name, parseDeclKind(kind).get, toDigestHex(root)))
  let common = buildCommonSchema(CommonSchemaDocument)
  doAssert common.isOk,
    "the pinned common schema document does not build: " & common.error
  # The registry's roots are the ones imports carry [SPEC COMMITMENT §5]; the
  # document they were computed from must reproduce them.
  doAssert schemaRoot(common.get) == ctx.commonRoot,
    "the pinned common schema document has root " & toHex(schemaRoot(common.get)) &
      ", not the pinned common root " & CommonSchemaRoot &
      ": re-derive spec/pins.toml from the spec revision"
  ctx.commonModel = common.get
  ctx

proc pinnedContext*(): SchemaContext =
  ## The pinned common schema of COMMITMENT §5 (`pins.nim`): its registry roots
  ## and its document. No other dependencies.
  pinned
