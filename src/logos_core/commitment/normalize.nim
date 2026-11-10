## COMMITMENT §7, §8: decoding a value under a schema into its semantic value tree.
##
## The value is Logos deterministic CBOR decoded under one declaration of one
## schema document. Every node carries the schema identity of its position (§4):
## the declaration's subtree root at a declaration body, a structural subtree root
## or leaf hash below it. A local reference adds no node: the container keeps the
## referring location's identity and the value carries the referenced declaration's
## [SPEC COMMITMENT §8]; through an alias chain that is the innermost declaration
## [IMPL-DECISION G1]. An imported reference adds a reference-value node.

{.push raises: [].}

import std/tables
import ../cbor
import ../hash/hashinput
import ./[schema, choice]

export choice

type
  Site* = object ## Where a schema node sits: document, nearest named declaration, path.
    doc*: int
    decl*: Declaration
    path*: seq[PathSegment]
    node*: SchemaNode

  Normalizer = object
    set: ptr SchemaSet
    ids: Table[string, Digest]
    plans: Table[string, Opt[SelectionPlan]]

func siteKey(s: Site): string =
  let b = encodeCbor(toCbor(s.path))
  var k = $s.doc & "|" & s.decl.name & "|"
  for x in b:
    k.add(char(x))
  k

func declSite*(doc: int, d: Declaration): Site =
  Site(doc: doc, decl: d, path: @[], node: d.body)

func child*(s: Site, seg: PathSegment, node: SchemaNode): Site =
  Site(doc: s.doc, decl: s.decl, path: s.path & seg, node: node)

func identityOf*(s: SchemaSet, site: Site): Digest =
  ## [SPEC COMMITMENT §4] The one schema identity of the node at `site`.
  let m = s.docs[site.doc]
  if site.path.len == 0:
    declarationRoot(m, site.decl) # [IMPL-DECISION G152] also for leaf bodies
  elif site.node.isLeaf:
    digestOf(dSchemaLeaf, leafPayload(m.modelId, site.decl, site.path, site.node))
  else:
    digestOf(dSchemaNode, structuralPayload(m.modelId, site.decl, site.path, site.node))

func throughLocal*(s: SchemaSet, site: Site): Result[Site, string] =
  ## [IMPL-DECISION G1] The site a value at `site` is normalized under: through
  ## every local reference to the innermost declaration.
  var cur = site
  for _ in 0 .. s.docs[site.doc].declarations.len:
    if cur.node.kind != snLocalRef:
      return ok(cur)
    let d = s.docs[cur.doc].find(cur.node.target)
    if d.isNone or d.get.kind == dkMethod:
      return err("local reference to " & cur.node.target & " names no type")
    cur = declSite(cur.doc, d.get)
  err("local references form a cycle without structure")

func importedSite*(s: SchemaSet, site: Site): Result[Site, string] =
  ## The declaration an imported reference at `site` names.
  let t = s.resolveImport(site.node.imported)
  if t.isNone:
    return err("an imported reference names no supplied named type")
  ok(declSite(t.get[0], t.get[1]))

func packKindOf*(element: SchemaNode): Opt[ScalarKind] =
  ## [SPEC HASH §4] A list packs when its element schema is a packable primitive;
  ## [IMPL-DECISION G119] or a literal of a packable kind. References never pack
  ## (I15), even to a packable scalar.
  case element.kind
  of snPrimitive:
    if element.scalar in PackableKinds:
      return Opt.some(element.scalar)
  of snLiteral:
    if element.literal.kind in PackableKinds:
      return Opt.some(element.literal.kind)
  else:
    discard
  Opt.none(ScalarKind)

func scalarOf(kind: ScalarKind, v: CborValue): ScalarData =
  ## `v` already passed `primitiveAccepts` for `kind`.
  case kind
  of skBool:
    boolScalar(v.simple == SimpleTrue)
  of UnsignedKinds:
    uintScalar(kind, v.uint)
  of SignedKinds:
    intScalar(kind, (if v.kind == ckUint: int64(v.uint)
      else: -int64(v.nint) - 1))
  of skTstr:
    textScalar(v.text)
  of skBstr:
    bytesScalar(v.bytes)

func id(n: var Normalizer, site: Site): Digest =
  let k = siteKey(site)
  if k notin n.ids:
    n.ids[k] = n.set[].identityOf(site)
  n.ids.getOrDefault(k)

func plan(n: var Normalizer, site: Site): Opt[SelectionPlan] =
  let k = siteKey(site)
  if k notin n.plans:
    n.plans[k] = n.set[].selectionPlan(site.doc, site.node)
  n.plans.getOrDefault(k)

func fieldEntry(v: CborValue, name: string): CborValue =
  for (k, x) in v.entries:
    if k.kind == ckText and k.text == name:
      return x
  nil

func value(
    n: var Normalizer, at: Site, v: CborValue, depth: int
): Result[ValueNode, string] =
  if depth > DefaultMaxDepth:
    return err("value nested deeper than " & $DefaultMaxDepth)
  let site = ?n.set[].throughLocal(at)
  let id = n.id(site)
  let s = site.node
  case s.kind
  of snLocalRef:
    err("unreachable")
  of snImportedRef:
    let target = ?n.set[].importedSite(site)
    ok(
      referenceNode(
        id, s.imported.root, s.imported.subtree, ?n.value(target, v, depth + 1)
      )
    )
  of snPrimitive:
    if not s.primitiveAccepts(v):
      return err("not a valid " & $s.scalar & " value")
    ok(scalarNode(id, scalarOf(s.scalar, v)))
  of snLiteral:
    let lit = literalValue(s.literal)
    if v.kind != lit.kind or encodeCbor(v) != encodeCbor(lit):
      return err("not the literal " & $toDiag(lit))
    ok(scalarNode(id, s.literal))
  of snMap:
    if v.kind != ckMap:
      return err("a map is expected")
    var
      fields: seq[ValueNode]
      seen = 0
    for f in s.fields:
      let fs = site.child(PathSegment(kind: psField, field: f.name), f.node)
      let x = v.fieldEntry(f.name)
      if x.isNil:
        if not f.optional:
          return err("required field " & f.name & " is missing")
        fields.add(absentField(n.id(fs), f.name))
      else:
        inc seen
        fields.add(fieldNode(n.id(fs), f.name, ?n.value(fs, x, depth + 1)))
    if seen != v.entries.len:
      return err("the map has fields its schema does not define")
    ok(mapNode(id, fields))
  of snList:
    if v.kind != ckArray:
      return err("a list is expected")
    let es = site.child(PathSegment(kind: psListElement), s.element)
    var values = newSeqOfCap[ValueNode](v.items.len)
    for x in v.items:
      values.add(?n.value(es, x, depth + 1))
    ok(listNode(id, n.id(es), values, packKindOf(s.element)))
  of snTuple:
    if v.kind != ckArray or v.items.len != s.items.len:
      return err("a tuple of " & $s.items.len & " elements is expected")
    var positions: seq[(Digest, ValueNode)]
    for i, x in v.items:
      let ps =
        site.child(PathSegment(kind: psTuplePosition, index: uint64(i)), s.items[i])
      positions.add((n.id(ps), ?n.value(ps, x, depth + 1)))
    ok(tupleNode(id, positions))
  of snChoice:
    let p = n.plan(site)
    if p.isNone:
      return err("the choice has no selection plan")
    let arm = p.get.select(v)
    if arm.isNone:
      return err("no choice arm matches")
    let a = arm.get
    let arms = site.child(PathSegment(kind: psChoiceArm, index: uint64(a)), s.arms[a])
    ok(choiceNode(id, uint64(a), n.id(arms), ?n.value(arms, v, depth + 1)))

func normalizeAt*(s: SchemaSet, site: Site, v: CborValue): Result[ValueNode, string] =
  ## The value node of `v` at `site` (a declaration body or any node below one).
  var n = Normalizer(set: addr s)
  n.value(site, v, 0)

func normalize*(
    s: SchemaSet, doc: int, declaration: string, v: CborValue
): Result[ValueRoot, string] =
  ## [SPEC COMMITMENT §7, §8] The normalized value root of the decoded value `v`
  ## under the named declaration of `s.docs[doc]`.
  let d = s.docs[doc].find(declaration)
  if d.isNone or d.get.kind == dkMethod:
    return err(declaration & " is not a type, request, response or event declaration")
  let m = s.docs[doc]
  ok(
    ValueRoot(
      modelId: m.modelId,
      schemaRoot: schemaRoot(m),
      subtreeRoot: declarationRoot(m, d.get),
      node: ?s.normalizeAt(declSite(doc, d.get), v),
    )
  )

func normalizeBytes*(
    s: SchemaSet, doc: int, declaration: string, data: openArray[byte]
): Result[ValueRoot, string] =
  ## As `normalize`, from Logos deterministic CBOR bytes (INTERFACE §4.4).
  let v = decodeCbor(data).valueOr:
    return err("not Logos deterministic CBOR: " & $error)
  s.normalize(doc, declaration, v)
