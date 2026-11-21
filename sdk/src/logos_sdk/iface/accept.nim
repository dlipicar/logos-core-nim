## INTERFACE §1 and §5.3: accepting schema documents and construction input sets.
##
## `buildSchema` (COMMITMENT §3.1) constructs one document's canonical model. This
## module adds what INTERFACE requires of a valid Logos schema on top of it: the
## metadata block, prelude and reserved names, the naming rules, the method and
## event limits, the supporting-schema suffix rule, the §5.3 size limits, and the
## rules over a whole construction input set (§1.1, §1.4). It also accepts an
## explicit module binding (§2): a runtime module name with its optional primary
## document and its implemented interfaces.

{.push raises: [].}

import std/[algorithm, sequtils, sets, strutils]
import ../cbor
import ../base/hex
import ../cddl/[model, syntax]
import ../hash/hashinput
import ../commitment
import ./[cmap, names]

export commitment, cmap, names

const
  MaxDocumentBytes* = 1_048_576 ## [SPEC INTERFACE §5.3] one schema document
  MaxInputSetBytes* = 8_388_608 ## [SPEC INTERFACE §5.3] one construction input set
  MaxSchemaNodes* = 65_536 ## [SPEC INTERFACE §5.3] across one input set's models
  MaxSchemaNesting* = 128 ## [SPEC INTERFACE §5.3] levels of `schema-node` nesting

type
  AcceptOptions* = object
    system*: bool
      ## [SPEC INTERFACE §1.3] a Logos-defined system, runtime or common-schema
      ## contract, which may use the reserved `logos` names
    byOwnName*: bool
      ## [SPEC PACKAGE MANAGER §4 l.359] [IMPL-DECISION G392] Decide `system`
      ## for each document from its own contract name instead: Logos-defined
      ## exactly when its `_module` begins `logos_` or its `_interface` begins
      ## `logos.`, `logos-` or `logos_` (INTERFACE §1.3 l.251-252). A supporting
      ## schema defines no contract and is ordinary.

  Contract* = object ## One accepted schema document.
    source*: string
    model*: SchemaModel
    root*: Digest

  ContractSet* = object
    ## [SPEC INTERFACE §1.1] An accepted construction input set: one primary
    ## document and exactly the dependencies it uses.
    primary*: Contract
    interfaces*: seq[Contract] ## in `_implements` order (ascending root bytes)
    supporting*: seq[Contract]
      ## by namespace UTF-8 bytes, then root bytes: every supporting schema the
      ## primary document or an interface uses, once
    context*: SchemaContext ## what the primary document was built against

  ModuleBinding* = object
    ## [SPEC INTERFACE §2] One runtime module name, its optional primary
    ## document, and its implemented interfaces with the supporting schemas they
    ## and the primary document use.
    module*: string
    primary*: Opt[Contract] ## a concrete module document whose `_module` is `module`
    interfaces*: seq[Contract] ## ascending raw root
    supporting*: seq[Contract] ## by namespace UTF-8 bytes, then root bytes
    extends*: seq[Contract]
      ## [SPEC INTERFACE §2.6] earlier contracts that the primary contract or an
      ## interface extends, by namespace UTF-8 bytes, then root bytes. They add
      ## no method or event and take no part in the set rules of the binding.

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
  ## [SPEC INTERFACE §5.3] Levels of `schema-node` nesting below and including
  ## `n`: every node is one level, leaves and references included; the field and
  ## array wrappers of the representation add none.
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
    1

func nestingOf*(m: SchemaModel): int =
  ## [SPEC INTERFACE §5.3] A declaration body is level one.
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

func sensitiveDeclarations*(m: SchemaModel): seq[string] =
  ## [SPEC INTERFACE §1.2.1] The request and response declarations `_sensitive`
  ## marks, in ascending ASCII order (as `_sensitive` lists them). Construction
  ## carries them on the methods (COMMITMENT §9.1 fields 3 and 4).
  var names: seq[string]
  for d in m.methods:
    if d.sensitiveRequest:
      names.add(d.request)
    if d.sensitiveResponse:
      names.add(d.response)
  names.sort()
  names

func marksPayloads*(c: Contract): bool =
  ## [SPEC INTERFACE §1.2.1] Whether a method of `c` has a payload `_sensitive`
  ## marks.
  for m in c.model.methods:
    if m.sensitiveRequest or m.sensitiveResponse:
      return true
  false

func marksPayloads*(s: ContractSet): bool =
  ## Whether the selected contract `s` reconstructs, its primary document or
  ## an interface it implements, marks a payload.
  s.primary.marksPayloads or s.interfaces.anyIt(it.marksPayloads)

func marksPayloads*(b: ModuleBinding): bool =
  ## Whether a contract the provider exposes marks a payload.
  (b.primary.isSome and b.primary.get.marksPayloads) or
    b.interfaces.anyIt(it.marksPayloads)

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

func ownNameReserved(rules: seq[SrcRule]): bool =
  ## [SPEC INTERFACE §1.3 l.251-252] The document's own contract name is
  ## reserved: a `_module` text beginning `logos_`, or an `_interface` text
  ## beginning `logos.`, `logos-` or `logos_`.
  for r in rules:
    let t = r.typ.unwrap
    if t.kind != skLiteral or t.literal.kind != lkTstr:
      continue
    if r.name == "_module" and t.literal.text.startsWith("logos_"):
      return true
    if r.name == "_interface" and t.literal.text.isReservedName:
      return true
  false

proc checkSource(source: string, opts: AcceptOptions): Result[AcceptOptions, string] =
  ## Rules on the source rules themselves, before construction. Returns the
  ## options that apply to this document.
  if source.len > MaxDocumentBytes:
    return err("the document is larger than 1 MiB (INTERFACE §5.3)")
  let rules = parseSource(source).valueOr:
    return err("cdCDDLe: " & $error)
  var own = opts
  if opts.byOwnName:
    own.system = rules.ownNameReserved
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
      if r.name.isReservedName and not own.system:
        return err(r.name & " uses a reserved Logos name (INTERFACE §1.3)")
  ok(own)

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
  let own = ?checkSource(source, opts)
  let m = ?buildSchema(source, ctx)
  ?checkModel(m, ctx, own)
  ok(Contract(source: source, model: m, root: schemaRoot(m)))

# A construction input set ----------------------------------------------------------

func cSchemaSet*(s: ContractSet): CSchemaSet =
  ## The set's documents for the C mapping (`cmap.nim`).
  func doc(c: Contract): CDocument =
    CDocument(model: c.model, root: c.root)

  let p = s.primary.model
  CSchemaSet(
    primary: Opt.some(doc(s.primary)),
    interfaces: s.interfaces.mapIt(doc(it)),
    supporting: s.supporting.mapIt(doc(it)),
    module:
      if p.role == srModule:
        p.moduleName
      else:
        Opt.none(string),
  )

func cmpContract*(a, b: Contract): int =
  ## Namespace UTF-8 bytes, then schema-root bytes.
  let byName = cmp(a.model.namespace, b.model.namespace)
  if byName != 0:
    byName
  else:
    cmpBytes(a.root, b.root)

proc checkInputBytes(sources: openArray[string]): Result[void, string] =
  var total = 0
  for s in sources:
    total += s.len
  if total > MaxInputSetBytes:
    return err("the input set is larger than 8 MiB (INTERFACE §5.3)")
  ok()

proc dependencyContext*(
    supporting: openArray[Contract], interfaces: openArray[Contract] = []
): SchemaContext =
  ## The pinned common schema with these accepted dependencies: what a document
  ## that uses them is built against.
  result = pinnedContext()
  for c in supporting:
    result.supporting.add(c.model)
  for c in interfaces:
    result.interfaces.add(c.model)

proc implementsOf*(source: string): seq[Digest] =
  ## [SPEC COMMITMENT §3.1 step 7] The roots a document's `_implements` lists,
  ## read from its source before construction so that the interfaces it selects
  ## can be supplied. Empty when the document has no `_implements` or it is not
  ## a fixed array of 32-byte literals; construction then reports the error.
  let rules = parseSource(source).valueOr:
    return @[]
  var roots: seq[Digest]
  for r in rules:
    if r.name != "_implements":
      continue
    let list = r.typ.unwrap
    if list.kind != skArray:
      return @[]
    for m in list.members:
      let x = m.typ.unwrap
      if x.kind != skLiteral or x.literal.kind != lkBstr or
          x.literal.bytes.len != DigestLen:
        return @[]
      var d: Digest
      for i in 0 ..< DigestLen:
        d[i] = x.literal.bytes[i]
      roots.add(d)
  roots

proc declaredRole*(source: string): SchemaRole =
  ## [SPEC COMMITMENT §3.1 step 1] The role a document's metadata declares, read
  ## from its source before construction: `_module` a concrete module,
  ## `_interface` an interface, neither a supporting schema (also when the
  ## source does not parse; construction then reports the error).
  let rules = parseSource(source).valueOr:
    return srSupporting
  for r in rules:
    if r.name == "_module":
      return srModule
  for r in rules:
    if r.name == "_interface":
      return srInterface
  srSupporting

proc acceptDependencies(
    interfaces, supporting: openArray[string], opts: AcceptOptions
): Result[(seq[Contract], seq[Contract], SchemaContext), string] =
  ## [SPEC INTERFACE §1.1] The supplied supporting schemas, each built against
  ## the common schema alone, and the supplied interfaces, each built against
  ## the common schema and the supporting schemas (never another interface).
  ## Returns (interfaces as supplied, supporting sorted, the context with both).
  let base = pinnedContext()
  var supp: seq[Contract]
  for s in supporting:
    let c = ?acceptDocument(s, base, opts)
    if c.model.role != srSupporting:
      return err("a supplied supporting schema has role " & $c.model.role)
    supp.add(c)
  supp.sort(cmpContract)
  for i in 1 ..< supp.len:
    if supp[i].model.namespace == supp[i - 1].model.namespace:
      return err("two supporting schemas declare namespace " & supp[i].model.namespace)
  var ctx = base
  for c in supp:
    ctx.supporting.add(c.model)
  var ifaces: seq[Contract]
  for s in interfaces:
    let c = ?acceptDocument(s, ctx, opts)
    if c.model.role != srInterface:
      return err("a supplied interface document has role " & $c.model.role)
    ifaces.add(c)
  for c in ifaces:
    ctx.interfaces.add(c.model)
  ok((ifaces, supp, ctx))

proc checkSetRules(
    primary: Opt[Contract], interfaces, supporting: seq[Contract]
): Result[void, string] =
  ## The rules over a whole accepted set: distinct roots, no unused supporting
  ## schema, unique exposed bare method names, the node limit.
  var docs = interfaces & supporting
  if primary.isSome:
    docs = @[primary.get] & docs
  # [SPEC INTERFACE §1.1] Every supplied document has a distinct root.
  var roots: HashSet[Digest]
  for c in docs:
    if roots.containsOrIncl(c.root):
      return err("two supplied documents have the same schema root")
  # [SPEC INTERFACE §1.1] No unused supporting schema: each supplies a named
  # type to the primary document or to an interface.
  var used: HashSet[Digest]
  for c in docs:
    if c.model.role in {srModule, srInterface}:
      used.incl(c.model.importedRoots)
  for c in supporting:
    if c.root notin used:
      return err("the supplied supporting schema " & c.model.namespace & " is unused")
  # [SPEC INTERFACE §1.4] Exposed bare method names are unique across the
  # primary contract and every implemented interface.
  var bare: HashSet[string]
  for c in docs:
    if c.model.role notin {srModule, srInterface}:
      continue
    for d in c.model.methods:
      let name = bareMethodName(d.name, c.model.namespace)
      if bare.containsOrIncl(name):
        return err("two exposed methods have the bare name " & name)
  # [SPEC INTERFACE §5.3] Nodes across every supplied document's model.
  var nodes = 0
  for c in docs:
    nodes += c.model.nodesOf.len
  if nodes > MaxSchemaNodes:
    return err("the input set has more than 65,536 schema nodes (INTERFACE §5.3)")
  ok()

proc completeSet(
    primary: Contract, ifaces, supp: openArray[Contract], ctx: SchemaContext
): Result[ContractSet, string] =
  ## The rules on an accepted primary document and its supplied dependencies as
  ## one construction input set.
  var set = ContractSet(primary: primary, supporting: @supp, context: ctx)
  let p = primary.model
  case p.role
  of srModule:
    discard
  of srInterface:
    # [SPEC INTERFACE §1.1] An interface's set is its document and the
    # supporting schemas it uses; it implements nothing.
    if ifaces.len > 0:
      return err("an interface schema implements no interface")
  else:
    # [SPEC INTERFACE §1.1] A supporting schema references no other document.
    if ifaces.len > 0 or supp.len > 0:
      return err("a supporting schema uses no interface or supporting schema")
  # The interfaces in `_implements` order; buildSchema rejected unused ones.
  for r in p.implemented:
    for c in ifaces:
      if c.root == r:
        set.interfaces.add(c)
  ?checkSetRules(Opt.some(set.primary), set.interfaces, set.supporting)
  # [SPEC INTERFACE §2, §2.1] Every accepted set is representable in C: no two
  # identical C identifiers and no namespace-projection collision.
  discard ?cDeclarations(set.cSchemaSet)
  ok(set)

proc acceptContractSet*(
    primary: string,
    interfaces: openArray[string] = [],
    supporting: openArray[string] = [],
    opts = AcceptOptions(),
): Result[ContractSet, string] =
  ## [SPEC INTERFACE §1.1, §1.4, §5.3] An explicitly supplied construction input
  ## set: the primary document (a concrete module, interface or supporting
  ## schema), the interface documents its `_implements` selects, and the
  ## supporting schemas whose named types it or those interfaces reference,
  ## each once. Nothing outside the set and the pinned common schema
  ## participates in resolution.
  ?checkInputBytes(@[primary] & @interfaces & @supporting)
  let (ifaces, supp, ctx) = ?acceptDependencies(interfaces, supporting, opts)
  completeSet(?acceptDocument(primary, ctx, opts), ifaces, supp, ctx)

proc acceptContractSetUsing*(
    primary: string, interfaces, supporting: openArray[Contract], opts = AcceptOptions()
): Result[ContractSet, string] =
  ## [SPEC INTERFACE §1.1, §1.4, §5.3] `acceptContractSet` over dependencies
  ## already accepted: each supporting schema against the pinned common schema
  ## alone, and each interface against the pinned common schema and supporting
  ## schemas among `supporting`. A caller that builds several sets from shared
  ## documents accepts each of them once.
  var sources = @[primary]
  for c in interfaces:
    sources.add(c.source)
  for c in supporting:
    sources.add(c.source)
  ?checkInputBytes(sources)
  var supp = @supporting
  for c in supp:
    if c.model.role != srSupporting:
      return err("a supplied supporting schema has role " & $c.model.role)
  supp.sort(cmpContract)
  for i in 1 ..< supp.len:
    if supp[i].model.namespace == supp[i - 1].model.namespace:
      return err("two supporting schemas declare namespace " & supp[i].model.namespace)
  let roots = supp.mapIt(it.root).toHashSet
  for c in interfaces:
    if c.model.role != srInterface:
      return err("a supplied interface document has role " & $c.model.role)
    for r in c.model.importedRoots:
      if r notin roots:
        return err(
          "the interface " & c.model.namespace &
            " uses a supporting schema that is not supplied"
        )
  let ctx = dependencyContext(supp, interfaces)
  completeSet(?acceptDocument(primary, ctx, opts), interfaces, supp, ctx)

func supportingOf*(s: ContractSet, c: Contract): seq[Contract] =
  ## [SPEC INTERFACE §1.1, §5.1] The supporting schemas of the set that `c`
  ## references, in the set's order.
  let used = c.model.importedRoots
  s.supporting.filterIt(it.root in used)

func documents*(s: ContractSet): seq[Contract] =
  ## The primary document, then its interfaces, then its supporting schemas.
  @[s.primary] & s.interfaces & s.supporting

func schemaSet*(s: ContractSet): SchemaSet =
  ## The primary document's schema set (document 0) for value work.
  schemaSetFor(s.primary.model, s.context)

# Module bindings -------------------------------------------------------------------

func cSchemaSet*(b: ModuleBinding): CSchemaSet =
  ## The binding's documents for the C mapping, with its module name.
  func doc(c: Contract): CDocument =
    CDocument(model: c.model, root: c.root)

  CSchemaSet(
    primary:
      if b.primary.isSome:
        Opt.some(doc(b.primary.get))
      else:
        Opt.none(CDocument),
    interfaces: b.interfaces.mapIt(doc(it)),
    supporting: b.supporting.mapIt(doc(it)),
    module: Opt.some(b.module),
  )

func binding*(s: ContractSet): Result[ModuleBinding, string] =
  ## [SPEC INTERFACE §2] The binding a concrete module subject derives from its
  ## `_module` and `_implements`; a standalone interface or supporting document
  ## establishes none.
  let p = s.primary.model
  if p.role != srModule or p.moduleName.isNone:
    return err("a " & $p.role & " document establishes no module binding")
  ok(
    ModuleBinding(
      module: p.moduleName.get,
      primary: Opt.some(s.primary),
      interfaces: s.interfaces,
      supporting: s.supporting,
    )
  )

func documents*(b: ModuleBinding): seq[Contract] =
  ## The binding's primary document when it has one, then its interfaces, then
  ## its supporting schemas: `ContractSet.documents`' order.
  if b.primary.isSome:
    result.add(b.primary.get)
  result.add(b.interfaces)
  result.add(b.supporting)

func exposedCount*(b: ModuleBinding): int =
  ## How many of `documents` are exposed contracts (the primary and the
  ## interfaces); the supporting schemas follow them.
  (if b.primary.isSome: 1 else: 0) + b.interfaces.len

proc context*(b: ModuleBinding): SchemaContext =
  ## What the binding's documents were built against: the pinned common schema
  ## with its supporting schemas and interfaces (`dependencyContext`).
  dependencyContext(b.supporting, b.interfaces)

func interfacesOf*(b: ModuleBinding, c: Contract): seq[Contract] =
  ## [SPEC INTERFACE §1.1] The binding's interfaces that `c`'s `_implements`
  ## selects, in that order: all of them for the primary contract, none for an
  ## interface, and its own selection for an earlier concrete contract.
  b.interfaces.filterIt(it.root in c.model.implemented)

func supportingOf*(b: ModuleBinding, c: Contract): seq[Contract] =
  ## [SPEC INTERFACE §2.6 l.1698-1699] The binding's supporting schemas that `c`
  ## or an interface it implements references, in namespace order: every one
  ## for the primary contract, and exactly its own for an interface.
  var used = c.model.importedRoots
  for i in b.interfacesOf(c):
    used.incl(i.model.importedRoots)
  b.supporting.filterIt(it.root in used)

proc acceptEarlier(
    b: ModuleBinding, source: string, opts: AcceptOptions
): Result[Contract, string] =
  ## [SPEC INTERFACE §2.6 l.1694] One `extends` document, accepted as its own
  ## construction input set. An earlier concrete contract follows the rules for
  ## the primary contract; an earlier interface those for interfaces.
  ## [IMPL-DECISION G392] r3: a concrete entry is built against only the
  ## binding's accepted interfaces its own `_implements` selects, with the
  ## supporting schemas it and they use (no unused input, IF l.110, l.113).
  var selected: seq[Contract]
  for r in implementsOf(source):
    let found = b.interfaces.filterIt(it.root == r)
    if found.len == 0:
      # [SPEC COMMITMENT §9.1 l.972] A contract of the binding implements at
      # most the binding's interfaces.
      return err(
        "no described contract extends an extends entry that implements " & toHex(r) &
          ", an interface the binding does not implement"
      )
    selected.add(found[0])
  let c = ?acceptDocument(source, dependencyContext(b.supporting, selected), opts)
  case c.model.role
  of srModule:
    if c.model.moduleName != Opt.some(b.module):
      return err(
        "an extends entry's _module is " & c.model.moduleName.get("") &
          ", the binding's module is " & b.module
      )
  of srInterface:
    discard
  of srSupporting, srCommon:
    return err("an extends entry is a " & $c.model.role & " schema, not a contract")
  var used = c.model.importedRoots
  for i in selected:
    used.incl(i.model.importedRoots)
  let supp = b.supporting.filterIt(it.root in used)
  discard ?completeSet(c, selected, supp, dependencyContext(supp, selected))
  ok(c)

proc acceptExtends(
    b: ModuleBinding, sources: openArray[string], opts: AcceptOptions
): Result[seq[Contract], string] =
  ## [SPEC INTERFACE §2.6 l.1693-1696, l.1710-1712] The binding's earlier
  ## contracts, in namespace, then root order. Each is accepted on its own,
  ## paired with the described contract (the primary or an interface) of its
  ## namespace, and extended by it under COMMITMENT §9.1. They stay out of the
  ## binding's set rules: the duplicate-namespace check (I62) and the bare-name
  ## collision check name the primary and interface contracts only
  ## [IMPL-DECISION G392] r4.
  var described = b.interfaces
  if b.primary.isSome:
    described.insert(b.primary.get, 0)
  # [IMPL-DECISION G392] r6: one contract identity across all three arrays.
  var ids = described.mapIt(it.root).toHashSet
  var all: seq[Contract]
  for s in sources:
    let a = ?acceptEarlier(b, s, opts)
    if ids.containsOrIncl(a.root):
      return err(
        "the extends entry " & a.model.namespace &
          " repeats the identity of a described contract or another entry"
      )
    # [SPEC INTERFACE §2.6 l.1711] [IMPL-DECISION G392] r2: at most one
    # described contract has the namespace (I62); the relation checks the role.
    let pair = described.filterIt(it.model.namespace == a.model.namespace)
    if pair.len == 0:
      return err(
        "no described contract has the namespace of the extends entry " &
          a.model.namespace
      )
    extendsContract(pair[0].model, a.model).isOkOr:
      return err("the described contract " & a.model.namespace & " " & error)
    all.add(a)
  all.sort(cmpContract)
  ok(all)

proc acceptBinding*(
    module: string,
    primary: Opt[string],
    interfaces: openArray[string] = [],
    supporting: openArray[string] = [],
    opts = AcceptOptions(),
    extends: openArray[string] = [],
): Result[ModuleBinding, string] =
  ## [SPEC INTERFACE §2, §3.9.2] An explicit module binding: the runtime module
  ## name `module`, an optional concrete module document, and the implemented
  ## interface documents with the supporting schemas they use. A supplied
  ## primary document must be a concrete module whose `_module` is `module` and
  ## whose `_implements` selects exactly `interfaces`; without one, `interfaces`
  ## is the implemented set. `extends` holds the documents of earlier contracts
  ## that the primary contract or an interface extends (§2.6); their supporting
  ## schemas are among `supporting`. The binding changes no document or
  ## identity.
  ?checkModuleName(module, opts.system)
  var b: ModuleBinding
  if primary.isSome:
    let set = ?acceptContractSet(primary.get, interfaces, supporting, opts)
    b = ?set.binding
    if b.module != module:
      return err(
        "the binding names module " & module & ", the primary document's _module is " &
          b.module
      )
  else:
    ?checkInputBytes(@interfaces & @supporting)
    var (ifaces, supp, _) = ?acceptDependencies(interfaces, supporting, opts)
    # [SPEC INTERFACE §2.1] Implemented interfaces in ascending raw root order.
    ifaces.sort(
      proc(a, b: Contract): int =
        cmpBytes(a.root, b.root)
    )
    ?checkSetRules(Opt.none(Contract), ifaces, supp)
    b = ModuleBinding(module: module, interfaces: ifaces, supporting: supp)
    discard ?cDeclarations(b.cSchemaSet)
  b.extends = ?acceptExtends(b, extends, opts)
  ok(b)
