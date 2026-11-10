## INTERFACE §1 and §5.3: accepting schema documents and construction input sets.
##
## `buildSchema` (COMMITMENT §3.1) constructs one document's canonical model. This
## module adds what INTERFACE requires of a valid Logos schema on top of it: the
## metadata block, prelude and reserved names, the naming rules, the method and
## event limits, the supporting-schema suffix rule, the §5.3 size limits, and the
## rules over a whole construction input set (§1.1, §1.4).

{.push raises: [].}

import std/[algorithm, sequtils, sets, strutils]
import ../cbor
import ../cddl/syntax
import ../hash/hashinput
import ../commitment
import ./[cmap, names]

export commitment, cmap, names

const
  MaxDocumentBytes* = 1_048_576 ## [SPEC INTERFACE §5.3] one schema document
  MaxInputSetBytes* = 8_388_608 ## [SPEC INTERFACE §5.3] one construction input set
  MaxSchemaNodes* = 65_536 ## [SPEC INTERFACE §5.3] across one input set's models
  MaxSchemaNesting* = 128 ## [SPEC INTERFACE §5.3] structural nesting levels

type
  AcceptOptions* = object
    system*: bool
      ## [SPEC INTERFACE §1.3] a Logos-defined system, runtime or common-schema
      ## contract, which may use the reserved `logos` names

  Contract* = object ## One accepted schema document.
    source*: string
    model*: SchemaModel
    root*: Digest

  ContractSet* = object
    ## [SPEC INTERFACE §1.1] An accepted construction input set: one primary
    ## document and exactly the dependencies it uses.
    primary*: Contract
    interfaces*: seq[Contract] ## in `_implements` order (ascending root bytes)
    supporting*: seq[Contract] ## by namespace UTF-8 bytes, then root bytes
    context*: SchemaContext ## what the primary document was built against

# Model measurements ----------------------------------------------------------------

func walkNodes(n: SchemaNode, visit: var seq[SchemaNode]) =
  visit.add(n)
  case n.kind
  of snMap:
    for f in n.fields:
      walkNodes(f.node, visit)
  of snList:
    walkNodes(n.element, visit)
  of snTuple:
    for x in n.items:
      walkNodes(x, visit)
  of snChoice:
    for a in n.arms:
      walkNodes(a, visit)
  else:
    discard

func nodesOf*(m: SchemaModel): seq[SchemaNode] =
  ## Every schema node of every declaration body, in declaration order.
  var all: seq[SchemaNode]
  for d in m.declarations:
    if d.kind != dkMethod:
      walkNodes(d.body, all)
  all

func nestingOf(n: SchemaNode): int =
  ## Structural nesting levels: each map, list, tuple or choice is one level;
  ## leaves and references add none [IMPL].
  case n.kind
  of snMap:
    var deepest = 0
    for f in n.fields:
      deepest = max(deepest, nestingOf(f.node))
    1 + deepest
  of snList:
    1 + nestingOf(n.element)
  of snTuple:
    var deepest = 0
    for x in n.items:
      deepest = max(deepest, nestingOf(x))
    1 + deepest
  of snChoice:
    var deepest = 0
    for a in n.arms:
      deepest = max(deepest, nestingOf(a))
    1 + deepest
  else:
    0

func nestingOf*(m: SchemaModel): int =
  var deepest = 0
  for d in m.declarations:
    if d.kind != dkMethod:
      deepest = max(deepest, nestingOf(d.body))
  deepest

func importedRoots*(m: SchemaModel): HashSet[Digest] =
  ## The schema roots of every document `m` references.
  var roots: HashSet[Digest]
  for n in m.nodesOf:
    if n.kind == snImportedRef:
      roots.incl(n.imported.root)
  roots

func wellKnownMethods*(ctx: SchemaContext): seq[string] =
  ## [SPEC INTERFACE §1.4] The bare names of the pinned common schema's
  ## well-known methods (`schema` from `logos.schema` in this revision).
  var names: seq[string]
  for (name, kind, _) in ctx.common:
    if kind == dkMethod:
      names.add(name.split('.')[^1])
  names

func methods*(m: SchemaModel): seq[Declaration] =
  var all: seq[Declaration]
  for d in m.declarations:
    if d.kind == dkMethod:
      all.add(d)
  all

func events*(m: SchemaModel): seq[Declaration] =
  var all: seq[Declaration]
  for d in m.declarations:
    if d.kind == dkEvent:
      all.add(d)
  all

# One document ----------------------------------------------------------------------

func checkFields(n: SchemaNode, owner: string): Result[void, string] =
  ## [SPEC INTERFACE §1.3] Field-name rules for every named and inline map.
  case n.kind
  of snMap:
    for f in n.fields:
      checkFieldName(f.name).isOkOr:
        return err(owner & ": " & error)
      ?checkFields(f.node, owner)
  of snList:
    ?checkFields(n.element, owner)
  of snTuple:
    for x in n.items:
      ?checkFields(x, owner)
  of snChoice:
    for a in n.arms:
      ?checkFields(a, owner)
  else:
    discard
  ok()

proc checkSource(source: string, opts: AcceptOptions): Result[void, string] =
  ## Rules on the source rules themselves, before construction.
  if source.len > MaxDocumentBytes:
    return err("the document is larger than 1 MiB (INTERFACE §5.3)")
  let rules = parseSource(source).valueOr:
    return err("cdCDDLe: " & $error)
  var declarationSeen = false
  for r in rules:
    if r.name in MetadataNames:
      # [SPEC INTERFACE §1.2] The file begins with its metadata block.
      if declarationSeen:
        return err(r.name & " follows a declaration; metadata comes first")
    else:
      declarationSeen = true
      if preludeAlias(r.name).isSome:
        return err("the document redefines the prelude name " & r.name)
      if r.name.isReservedName and not opts.system:
        return err(r.name & " uses a reserved Logos name (INTERFACE §1.3)")
  ok()

func checkAliasCycles(m: SchemaModel): Result[void, string] =
  ## [IMPL-DECISION G153] A chain of local aliases must reach a structure, a
  ## scalar or an import: `a = b`, `b = a` has no C representation (INTERFACE §2
  ## requires every accepted set to have one) and no value.
  for d in m.declarations:
    if d.kind == dkMethod or d.body.kind != snLocalRef:
      continue
    var
      seen = @[d.name]
      cur = d.body
    while cur.kind == snLocalRef:
      if cur.target in seen:
        return err("the aliases " & seen.join(", ") & " form a cycle (G153)")
      seen.add(cur.target)
      let next = m.find(cur.target)
      if next.isNone or next.get.kind == dkMethod:
        break
      cur = next.get.body
  ok()

proc checkModel(
    m: SchemaModel, ctx: SchemaContext, opts: AcceptOptions
): Result[void, string] =
  ## The INTERFACE §1.2-§1.5 and §5.3 rules on a constructed model.
  case m.role
  of srModule:
    if m.moduleName.isNone:
      return err("_module is not a text literal")
    ?checkModuleName(m.moduleName.get, opts.system)
  of srInterface, srSupporting:
    discard
  of srCommon:
    return err("the common schema document is pinned, not accepted")
  ?checkNamespace(m.namespace)
  let reserved = ctx.wellKnownMethods
  for d in m.declarations:
    ?checkQualifiedName(d.name)
    case d.kind
    of dkMethod:
      let bare = bareMethodName(d.name, m.namespace)
      if bare.len > MaxMethodNameBytes:
        return err("method " & d.name & " has a bare name longer than 128 bytes")
      if bare in reserved:
        return err("method " & d.name & " uses the well-known method name " & bare)
    of dkEvent:
      if d.name.len > MaxEventIdBytes:
        return err("event " & d.name & " is longer than 128 bytes")
      ?checkFields(d.body, d.name)
    of dkType:
      if m.role == srSupporting and d.name.hasCallableSuffix:
        return err(
          "supporting schema declaration " & d.name &
            " ends in a callable suffix (INTERFACE §1.3)"
        )
      ?checkFields(d.body, d.name)
    of dkRequest, dkResponse:
      ?checkFields(d.body, d.name)
  ?checkAliasCycles(m)
  if m.nestingOf > MaxSchemaNesting:
    return err("the schema nests deeper than 128 levels (INTERFACE §5.3)")
  if m.nodesOf.len > MaxSchemaNodes:
    return err("the schema has more than 65,536 nodes (INTERFACE §5.3)")
  ok()

proc acceptDocument*(
    source: string, ctx: SchemaContext, opts = AcceptOptions()
): Result[Contract, string] =
  ## [SPEC INTERFACE §1, §5.3] One schema document, built against `ctx` (the
  ## dependencies it may use).
  ?checkSource(source, opts)
  let m = ?buildSchema(source, ctx)
  ?checkModel(m, ctx, opts)
  ok(Contract(source: source, model: m, root: schemaRoot(m)))

# A construction input set ----------------------------------------------------------

func cSchemaSet*(s: ContractSet): CSchemaSet =
  ## The set's documents for the C mapping (`cmap.nim`).
  func doc(c: Contract): CDocument =
    CDocument(model: c.model, root: c.root)

  CSchemaSet(
    primary: doc(s.primary),
    interfaces: s.interfaces.mapIt(doc(it)),
    supporting: s.supporting.mapIt(doc(it)),
  )

func cmpContract(a, b: Contract): int =
  ## Namespace UTF-8 bytes, then schema-root bytes.
  let byName = cmp(a.model.namespace, b.model.namespace)
  if byName != 0:
    byName
  else:
    cmpBytes(a.root, b.root)

proc acceptContractSet*(
    primary: string,
    interfaces: openArray[string] = [],
    supporting: openArray[string] = [],
    opts = AcceptOptions(),
): Result[ContractSet, string] =
  ## [SPEC INTERFACE §1.1, §1.4, §5.3] An explicitly supplied construction input
  ## set: the primary document (a concrete module, interface or supporting
  ## schema), the interface documents its `_implements` selects, and the
  ## supporting schemas whose named types it references. Nothing outside the set
  ## and the pinned common schema participates in resolution.
  var total = primary.len
  for s in interfaces:
    total += s.len
  for s in supporting:
    total += s.len
  if total > MaxInputSetBytes:
    return err("the input set is larger than 8 MiB (INTERFACE §5.3)")
  let base = pinnedContext()
  var set = ContractSet()
  for s in supporting:
    let c = ?acceptDocument(s, base, opts)
    if c.model.role != srSupporting:
      return err("a supplied supporting schema has role " & $c.model.role)
    set.supporting.add(c)
  set.supporting.sort(cmpContract)
  for i in 1 ..< set.supporting.len:
    if set.supporting[i].model.namespace == set.supporting[i - 1].model.namespace:
      return err(
        "two supporting schemas declare namespace " & set.supporting[i].model.namespace
      )
  var ifaces: seq[Contract]
  for s in interfaces:
    let c = ?acceptDocument(s, base, opts)
    if c.model.role != srInterface:
      return err("a supplied interface document has role " & $c.model.role)
    ifaces.add(c)
  var ctx = base
  for c in set.supporting:
    ctx.supporting.add(c.model)
  for c in ifaces:
    ctx.interfaces.add(c.model)
  set.primary = ?acceptDocument(primary, ctx, opts)
  set.context = ctx
  let p = set.primary.model
  if p.role != srModule and (ifaces.len > 0 or set.supporting.len > 0):
    # Interface and supporting schemas see only the common schema (§1.1).
    return err("a " & $p.role & " schema uses no interface or supporting schema")
  # [SPEC INTERFACE §1.1] Every supplied document has a distinct root.
  var roots: HashSet[Digest]
  for c in @[set.primary] & ifaces & set.supporting:
    if roots.containsOrIncl(c.root):
      return err("two supplied documents have the same schema root")
  # The interfaces in `_implements` order; buildSchema rejected unused ones.
  for r in p.implemented:
    for c in ifaces:
      if c.root == r:
        set.interfaces.add(c)
  # [SPEC INTERFACE §1.1] No unused supporting schema.
  let used = p.importedRoots
  for c in set.supporting:
    if c.root notin used:
      return err("the supplied supporting schema " & c.model.namespace & " is unused")
  # [SPEC INTERFACE §1.4] Exposed bare method names are unique across the
  # primary contract and every implemented interface.
  var bare: HashSet[string]
  for c in @[set.primary] & set.interfaces:
    for d in c.model.methods:
      let name = bareMethodName(d.name, c.model.namespace)
      if bare.containsOrIncl(name):
        return err("two exposed methods have the bare name " & name)
  # [SPEC INTERFACE §5.3] Nodes across every model of the set.
  var nodes = 0
  for c in @[set.primary] & set.interfaces & set.supporting:
    nodes += c.model.nodesOf.len
  if nodes > MaxSchemaNodes:
    return err("the input set has more than 65,536 schema nodes (INTERFACE §5.3)")
  # [SPEC INTERFACE §2, §2.1] Every accepted set is representable in C: no two
  # identical C identifiers and no namespace-projection collision.
  discard ?cDeclarations(set.cSchemaSet)
  ok(set)

func documents*(s: ContractSet): seq[Contract] =
  ## The primary document, then its interfaces, then its supporting schemas.
  @[s.primary] & s.interfaces & s.supporting

func schemaSet*(s: ContractSet): SchemaSet =
  ## The primary document's schema set (document 0) for value work.
  schemaSetFor(s.primary.model, s.context)
