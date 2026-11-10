## COMMITMENT §3, §4, §9.1, §9.2: the Logos canonical schema model and its identities.
##
## A `SchemaModel` is one document's canonical schema (built by `construct`). Its
## schema root, the subtree roots of its declarations and structural nodes, and the
## leaf hashes of its leaf nodes are hashes of the §9.1/§9.2 objects under the HASH
## profile's schema domains. References are terminal: no identity inlines another
## declaration [SPEC COMMITMENT §3].

{.push raises: [].}

import std/algorithm
import ../cbor
import ../hash/hashinput
import ./value

export value

type
  SchemaNodeKind* = enum
    snPrimitive = "primitive"
    snLiteral = "literal"
    snMap = "map"
    snList = "list"
    snTuple = "tuple"
    snChoice = "choice"
    snLocalRef = "local-reference"
    snImportedRef = "imported-reference"

  SchemaImport* = object ## [SPEC COMMITMENT §9.1] `schema-import`.
    root*: Digest
    subtree*: Digest

  SchemaField* = object
    name*: string
    optional*: bool
    node*: SchemaNode

  SchemaNode* = ref object
    case kind*: SchemaNodeKind
    of snPrimitive:
      scalar*: ScalarKind
      size*: Opt[(uint64, uint64)] ## tstr and bstr only: minimum, maximum
    of snLiteral:
      literal*: ScalarData ## bool, uint64, int64 or tstr
    of snMap:
      fields*: seq[SchemaField] ## canonical field-name order
    of snList:
      element*: SchemaNode
    of snTuple:
      items*: seq[SchemaNode]
    of snChoice:
      arms*: seq[SchemaNode] ## canonical arm order (§9.1)
    of snLocalRef:
      target*: string
    of snImportedRef:
      imported*: SchemaImport

  DeclKind* = enum
    ## [SPEC COMMITMENT §9.1] `schema-declaration-kind`.
    dkType = "type"
    dkMethod = "method"
    dkRequest = "method-request"
    dkResponse = "method-response"
    dkEvent = "event"

  Declaration* = object
    name*: string
    case kind*: DeclKind
    of dkMethod:
      request*, response*: string
    else:
      body*: SchemaNode

  SchemaRole* = enum
    srModule = "module"
    srInterface = "interface"
    srSupporting = "supporting"
    srCommon = "common"

  SchemaModel* = object
    ## [SPEC COMMITMENT §9.1] `normalized-schema-root`, plus the role it was built as.
    modelId*: string
    role*: SchemaRole
    namespace*: string
    declarations*: seq[Declaration] ## sorted by qualified name
    implemented*: seq[Digest] ## implemented interface roots, sorted
    moduleName*: Opt[string]
      ## the `_module` text literal of a concrete module schema: metadata, not part
      ## of the canonical model or its root

  PathSegmentKind* = enum
    psField = "field"
    psListElement = "list-element"
    psTuplePosition = "tuple-position"
    psChoiceArm = "choice-arm"

  PathSegment* = object ## [SPEC COMMITMENT §9.2] `schema-node-path-segment`.
    case kind*: PathSegmentKind
    of psField:
      field*: string
    of psListElement:
      discard
    of psTuplePosition, psChoiceArm:
      index*: uint64

# Canonical data shapes (§9.1, §9.2) --------------------------------------------------

func entry(k: uint64, v: CborValue): CborEntry =
  (cbor(k), v)

func toCbor*(i: SchemaImport): CborValue =
  cborMap(entry(0, cbor(i.root)), entry(1, cbor(i.subtree)))

func toCbor*(n: SchemaNode): CborValue =
  ## [SPEC COMMITMENT §9.1] `schema-node`.
  let kind = entry(0, cbor($n.kind))
  case n.kind
  of snPrimitive:
    if n.size.isSome:
      let (lo, hi) = n.size.get
      cborMap(
        kind,
        entry(1, cbor($n.scalar)),
        entry(
          2, cborMap(entry(0, cbor("size")), entry(1, cbor(lo)), entry(2, cbor(hi)))
        ),
      )
    else:
      cborMap(kind, entry(1, cbor($n.scalar)))
  of snLiteral:
    cborMap(kind, entry(1, cbor($n.literal.kind)), entry(2, toCbor(n.literal)))
  of snMap:
    var fields: seq[CborValue]
    for f in n.fields:
      fields.add(
        cborMap(
          entry(0, cbor(f.name)), entry(1, cbor(f.optional)), entry(2, toCbor(f.node))
        )
      )
    cborMap(kind, entry(1, cborArray(fields)))
  of snList:
    cborMap(kind, entry(1, toCbor(n.element)))
  of snTuple:
    var items: seq[CborValue]
    for x in n.items:
      items.add(toCbor(x))
    cborMap(kind, entry(1, cborArray(items)))
  of snChoice:
    var arms: seq[CborValue]
    for x in n.arms:
      arms.add(toCbor(x))
    cborMap(kind, entry(1, cborArray(arms)))
  of snLocalRef:
    cborMap(kind, entry(1, cbor(n.target)))
  of snImportedRef:
    cborMap(kind, entry(1, toCbor(n.imported)))

func bodyCbor*(d: Declaration): CborValue =
  ## [SPEC COMMITMENT §9.1] `schema-declaration-body`.
  if d.kind == dkMethod:
    cborMap(
      entry(0, cbor("method")), entry(1, cbor(d.request)), entry(2, cbor(d.response))
    )
  else:
    toCbor(d.body)

func toCbor*(d: Declaration): CborValue =
  cborMap(entry(0, cbor($d.kind)), entry(1, cbor(d.name)), entry(2, bodyCbor(d)))

func toCbor*(m: SchemaModel): CborValue =
  ## [SPEC COMMITMENT §9.1] `normalized-schema-root`, the `schema-root-payload`.
  var decls, roots: seq[CborValue]
  for d in m.declarations:
    decls.add(toCbor(d))
  for r in m.implemented:
    roots.add(cbor(r))
  cborMap(
    entry(0, cbor("schema-root")),
    entry(1, cbor(m.modelId)),
    entry(2, cbor(m.namespace)),
    entry(3, cborArray(decls)),
    entry(4, cborArray(roots)),
  )

func toCbor*(s: PathSegment): CborValue =
  case s.kind
  of psField:
    cborMap(entry(0, cbor("field")), entry(1, cbor(s.field)))
  of psListElement:
    cborMap(entry(0, cbor("list-element")))
  of psTuplePosition, psChoiceArm:
    cborMap(entry(0, cbor($s.kind)), entry(1, cbor(s.index)))

func toCbor*(path: openArray[PathSegment]): CborValue =
  var items: seq[CborValue]
  for s in path:
    items.add(toCbor(s))
  cborArray(items)

# Canonical order ---------------------------------------------------------------------

func sortArms*(arms: var seq[SchemaNode]): bool =
  ## [SPEC COMMITMENT §9.1] Ascending order of the arms' deterministic-CBOR
  ## encodings. False when two arms encode identically (the choice is invalid).
  var keyed: seq[(seq[byte], SchemaNode)]
  for a in arms:
    keyed.add((encodeCbor(toCbor(a)), a))
  keyed.sort(
    proc(a, b: (seq[byte], SchemaNode)): int =
      cmpBytes(a[0], b[0])
  )
  arms.setLen(0)
  for i, (k, a) in keyed:
    if i > 0 and k == keyed[i - 1][0]:
      return false
    arms.add(a)
  true

# Identities (§4, §9.2) ---------------------------------------------------------------

func isCommitmentModelRevision*(s: string): bool =
  ## [SPEC COMMITMENT §6] `"logos.commitment-model." date-label ["." revision-label]`,
  ## `date-label = 4DIGIT "-" 2DIGIT`, `revision-label = 1*(a-z / DIGIT / "-")`.
  const prefix = "logos.commitment-model."
  if s.len < prefix.len + 7 or s[0 ..< prefix.len] != prefix:
    return false
  let d = s[prefix.len ..< prefix.len + 7]
  for i, c in d:
    if (i == 4 and c != '-') or (i != 4 and c notin {'0' .. '9'}):
      return false
  let rest = s[prefix.len + 7 .. ^1]
  if rest.len == 0:
    return true
  if rest.len < 2 or rest[0] != '.':
    return false
  for c in rest[1 .. ^1]:
    if c notin {'a' .. 'z', '0' .. '9', '-'}:
      return false
  true

func schemaNodePayload*(modelId: string, d: Declaration): CborValue =
  ## [SPEC COMMITMENT §9.2] `schema-node-payload`.
  cborMap(
    entry(0, cbor("schema-node")),
    entry(1, cbor(modelId)),
    entry(2, cbor(d.name)),
    entry(3, cbor($d.kind)),
    entry(4, bodyCbor(d)),
  )

func pathPayload(
    tag, modelId: string, d: Declaration, path: openArray[PathSegment], node: SchemaNode
): CborValue =
  cborMap(
    entry(0, cbor(tag)),
    entry(1, cbor(modelId)),
    entry(2, cbor($d.kind)),
    entry(3, cbor(d.name)),
    entry(4, toCbor(path)),
    entry(5, toCbor(node)),
  )

func structuralPayload*(
    modelId: string, d: Declaration, path: openArray[PathSegment], node: SchemaNode
): CborValue =
  ## [SPEC COMMITMENT §4, §9.2] `schema-structural-node-payload`.
  pathPayload("schema-structural-node", modelId, d, path, node)

func leafPayload*(
    modelId: string, d: Declaration, path: openArray[PathSegment], node: SchemaNode
): CborValue =
  ## [SPEC COMMITMENT §9.2] `schema-leaf-payload`.
  pathPayload("schema-leaf", modelId, d, path, node)

func schemaRoot*(m: SchemaModel): Digest =
  ## The whole-schema root: `logos.schema.root` over `schema-root-payload`.
  digestOf(dSchemaRoot, toCbor(m))

func declarationRoot*(modelId: string, d: Declaration): Digest =
  ## A named schema subtree root: `logos.schema.node` over `schema-node-payload`.
  digestOf(dSchemaNode, schemaNodePayload(modelId, d))

func declarationRoot*(m: SchemaModel, d: Declaration): Digest =
  declarationRoot(m.modelId, d)

func isLeaf*(n: SchemaNode): bool =
  ## [SPEC COMMITMENT §9.2] primitive, literal and reference nodes.
  n.kind in {snPrimitive, snLiteral, snLocalRef, snImportedRef}

func nodeAt*(d: Declaration, path: openArray[PathSegment]): Result[SchemaNode, string] =
  ## [SPEC COMMITMENT §9.2] The node `path` reaches from the declaration body;
  ## paths stop at references, which are never followed.
  if d.kind == dkMethod:
    return err("a method declaration has no schema-node body")
  var n = d.body
  for s in path:
    case s.kind
    of psField:
      if n.kind != snMap:
        return err("a field segment below a " & $n.kind & " node")
      var found = false
      for f in n.fields:
        if f.name == s.field:
          n = f.node
          found = true
          break
      if not found:
        return err("no field " & s.field)
    of psListElement:
      if n.kind != snList:
        return err("a list-element segment below a " & $n.kind & " node")
      n = n.element
    of psTuplePosition:
      if n.kind != snTuple or s.index >= uint64(n.items.len):
        return err("no tuple position " & $s.index)
      n = n.items[int(s.index)]
    of psChoiceArm:
      if n.kind != snChoice or s.index >= uint64(n.arms.len):
        return err("no choice arm " & $s.index)
      n = n.arms[int(s.index)]
  ok(n)

func structuralRoot*(
    m: SchemaModel, d: Declaration, path: openArray[PathSegment]
): Result[Digest, string] =
  ## An anonymous structural node's subtree root: `logos.schema.node` over
  ## `schema-structural-node-payload`, for a map, list, tuple or choice node at
  ## a non-empty path.
  let node = ?nodeAt(d, path)
  if path.len == 0 or node.isLeaf:
    return
      err("structural roots are for map, list, tuple and choice nodes below the body")
  ok(digestOf(dSchemaNode, structuralPayload(m.modelId, d, path, node)))

func leafHash*(
    m: SchemaModel, d: Declaration, path: openArray[PathSegment]
): Result[Digest, string] =
  ## A schema leaf hash: `logos.schema.leaf` over `schema-leaf-payload`. The path
  ## must reach a leaf node; `[]` when the body itself is one.
  let node = ?nodeAt(d, path)
  if not node.isLeaf:
    return err("a " & $node.kind & " node is not a leaf schema node")
  ok(digestOf(dSchemaLeaf, leafPayload(m.modelId, d, path, node)))

func referenceHash*(i: SchemaImport, profile = SpecProfile): Digest =
  ## [IMPL-DECISION G122] `logos.schema.reference` over `schema-reference-payload`.
  digestOf(dSchemaReference, toCbor(i), profile)

func nodeIdentity*(
    m: SchemaModel, d: Declaration, path: openArray[PathSegment]
): Result[Digest, string] =
  ## [SPEC COMMITMENT §4 l.560-562] The one schema identity of the node at `path`:
  ## the declaration's subtree root at the empty path, a leaf hash for a
  ## primitive, literal or reference node, a structural subtree root otherwise.
  ## [IMPL-DECISION G152] A leaf node at the empty path (a leaf-bodied
  ## declaration) takes the declaration's subtree root.
  let node = ?nodeAt(d, path)
  if path.len == 0:
    ok(declarationRoot(m, d))
  elif node.isLeaf:
    leafHash(m, d, path)
  else:
    structuralRoot(m, d, path)

func declarationBySubtree*(m: SchemaModel, subtree: Digest): Opt[Declaration] =
  ## [SPEC COMMITMENT §4] The named declaration whose subtree root is `subtree`.
  ## Only named subtree roots resolve: a structural root or leaf hash names none.
  for d in m.declarations:
    if declarationRoot(m, d) == subtree:
      return Opt.some(d)
  Opt.none(Declaration)

func find*(m: SchemaModel, name: string): Opt[Declaration] =
  ## The declaration named `name`.
  var lo = 0
  var hi = m.declarations.high
  while lo <= hi:
    let mid = (lo + hi) div 2
    let c = cmp(m.declarations[mid].name, name)
    if c == 0:
      return Opt.some(m.declarations[mid])
    if c < 0:
      lo = mid + 1
    else:
      hi = mid - 1
  Opt.none(Declaration)
