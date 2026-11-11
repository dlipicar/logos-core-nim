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

type Wrapper = object
  ## An imported reference or a choice the value passes through: its node wraps
  ## the inner value's node once that is built.
  site: Site
  id: Digest
  arm: int ## the selected arm of a choice; -1 for an imported reference
  armId: Digest

type Frame = object ## A map, list or tuple whose members are being normalized.
  site: Site
  id: Digest
  v: CborValue
  depth: int ## the maps and arrays above `v`
  wrappers: seq[Wrapper] ## the imported references and choices around it
  next: int ## the next schema field or array element
  memberId: Digest ## map and tuple: the identity of the member being built
  members: seq[ValueNode] ## map: field nodes; list: element values
  positions: seq[(Digest, ValueNode)] ## tuple
  seen: int ## map: the fields present in `v`

func rewrap(node: ValueNode, wrappers: seq[Wrapper]): ValueNode =
  ## `node` inside its reference and choice nodes, innermost first.
  result = node
  for i in countdown(wrappers.high, 0):
    let w = wrappers[i]
    result =
      if w.arm < 0:
        referenceNode(
          w.id, w.site.node.imported.root, w.site.node.imported.subtree, result
        )
      else:
        choiceNode(w.id, uint64(w.arm), w.armId, result)

func enter(
    n: var Normalizer, stack: var seq[Frame], at: Site, v: CborValue, depth: int
): Result[ValueNode, string] =
  ## The node of `v` at `at` if it is a scalar; for a map, list or tuple, its frame
  ## is pushed and the result is nil. Imported references and choice arms are
  ## followed here and wrapped when the inner node is built.
  var
    site = ?n.set[].throughLocal(at)
    wrappers: seq[Wrapper]
  while site.node.kind in {snImportedRef, snChoice}:
    for w in wrappers:
      if w.site.doc == site.doc and
          cast[pointer](w.site.node) == cast[pointer](site.node):
        return err("references and choice arms form a cycle without structure")
    var w = Wrapper(site: site, id: n.id(site), arm: -1)
    if site.node.kind == snImportedRef:
      site = ?n.set[].throughLocal(?n.set[].importedSite(site))
    else:
      let p = n.plan(site)
      if p.isNone:
        return err("the choice has no selection plan")
      let arm = p.get.select(v)
      if arm.isNone:
        return err("no choice arm matches")
      let arms = site.child(
        PathSegment(kind: psChoiceArm, index: uint64(arm.get)), site.node.arms[arm.get]
      )
      w.arm = arm.get
      w.armId = n.id(arms)
      site = ?n.set[].throughLocal(arms)
    wrappers.add(w)

  let id = n.id(site)
  let s = site.node
  if s.kind in {snMap, snList, snTuple} and depth >= DefaultMaxDepth:
    return err("value nested deeper than " & $DefaultMaxDepth & " maps and arrays")
  case s.kind
  of snLocalRef, snImportedRef, snChoice:
    err("unreachable")
  of snPrimitive:
    if not s.primitiveAccepts(v):
      return err("not a valid " & $s.scalar & " value")
    ok(rewrap(scalarNode(id, scalarOf(s.scalar, v)), wrappers))
  of snLiteral:
    let lit = literalValue(s.literal)
    if v.kind != lit.kind or encodeCbor(v) != encodeCbor(lit):
      return err("not the literal " & $toDiag(lit))
    ok(rewrap(scalarNode(id, s.literal), wrappers))
  of snMap, snList, snTuple:
    if s.kind == snMap and v.kind != ckMap:
      return err("a map is expected")
    if s.kind == snList and v.kind != ckArray:
      return err("a list is expected")
    if s.kind == snTuple and (v.kind != ckArray or v.items.len != s.items.len):
      return err("a tuple of " & $s.items.len & " elements is expected")
    stack.add(Frame(site: site, id: id, v: v, depth: depth, wrappers: wrappers))
    ok(ValueNode(nil))

func finish(n: var Normalizer, f: Frame): ValueNode =
  ## The node of a frame whose members are all built.
  let s = f.site.node
  let node =
    case s.kind
    of snMap:
      mapNode(f.id, f.members)
    of snList:
      let es = f.site.child(PathSegment(kind: psListElement), s.element)
      listNode(f.id, n.id(es), f.members, packKindOf(s.element))
    of snTuple:
      tupleNode(f.id, f.positions)
    else:
      raiseAssert "frames hold maps, lists and tuples"
  rewrap(node, f.wrappers)

func value(
    n: var Normalizer, at: Site, v: CborValue, depth: int
): Result[ValueNode, string] =
  ## `depth` counts the maps and arrays above `v`; imported references and choice
  ## arms add no level. Members are normalized depth first in order, with the
  ## frames on the heap, so the native stack does not grow with the payload depth
  ## and every depth up to `DefaultMaxDepth` is supported on any thread
  ## [SPEC INTERFACE §4.5.1] (DECISIONS I51).
  var
    stack: seq[Frame]
    produced = ?n.enter(stack, at, v, depth)
  while true:
    if not produced.isNil:
      # Hand the finished member to the frame that started it.
      if stack.len == 0:
        return ok(produced)
      let t = stack.high
      case stack[t].site.node.kind
      of snMap:
        let name = stack[t].site.node.fields[stack[t].next - 1].name
        stack[t].members.add(fieldNode(stack[t].memberId, name, produced))
      of snList:
        stack[t].members.add(produced)
      of snTuple:
        stack[t].positions.add((stack[t].memberId, produced))
      else:
        raiseAssert "frames hold maps, lists and tuples"
      produced = nil
    # Start the top frame's next member, or finish the frame.
    let t = stack.high
    let (site, cv, below) = (stack[t].site, stack[t].v, stack[t].depth + 1)
    let s = site.node
    var started = false
    case s.kind
    of snMap:
      while not started and stack[t].next < s.fields.len:
        let f = s.fields[stack[t].next]
        inc stack[t].next
        let fs = site.child(PathSegment(kind: psField, field: f.name), f.node)
        let x = cv.fieldEntry(f.name)
        if x.isNil:
          if not f.optional:
            return err("required field " & f.name & " is missing")
          stack[t].members.add(absentField(n.id(fs), f.name))
        else:
          inc stack[t].seen
          stack[t].memberId = n.id(fs)
          started = true
          produced = ?n.enter(stack, fs, x, below)
      if not started and stack[t].seen != cv.entries.len:
        return err("the map has fields its schema does not define")
    of snList:
      let i = stack[t].next
      if i < cv.items.len:
        inc stack[t].next
        let es = site.child(PathSegment(kind: psListElement), s.element)
        started = true
        produced = ?n.enter(stack, es, cv.items[i], below)
    of snTuple:
      let i = stack[t].next
      if i < cv.items.len:
        inc stack[t].next
        let ps =
          site.child(PathSegment(kind: psTuplePosition, index: uint64(i)), s.items[i])
        stack[t].memberId = n.id(ps)
        started = true
        produced = ?n.enter(stack, ps, cv.items[i], below)
    else:
      raiseAssert "frames hold maps, lists and tuples"
    if not started:
      produced = n.finish(stack.pop())

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
