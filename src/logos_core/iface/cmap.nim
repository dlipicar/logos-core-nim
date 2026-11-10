## INTERFACE §2, §2.1-§2.3, §2.5, §5.2: the canonical C type mapping of an
## accepted schema set.
##
## Derived here: document-role and implemented-interface constants, literal
## macros, constrained string typedefs, named and inline aggregates (maps, byte
## strings, lists, tuples, choices, events), recursive-edge pointers with their
## forward typedefs, and `logos_types.h` (the fixed §5.2 and §2.3 blocks plus the
## common schema's named types). Not derived yet: method signatures (§2.4),
## lifecycle symbols (§2.6), concurrency (§2.8).
##
## Acceptance runs this mapping (`accept.nim`): an accepted set must be
## representable in C without two identical identifiers or a namespace-projection
## collision [SPEC INTERFACE §2, §2.1].
##
## Every header is stamped PROVISIONAL ABI: open items (IF-03, IF-04, IF-06,
## NX-04, G153, G154, G155) can still change the mapping.

{.push raises: [].}

import std/[algorithm, sequtils, sets, strutils, tables]
import ../hash/hashinput
import ../base/hex
import ../pins
import ../commitment
import ./names

const ProvisionalStamp* = "PROVISIONAL ABI (spec " & SpecRevision[0 .. 7] & ")"

type
  CDocument* = object
    model*: SchemaModel
    root*: Digest

  CSchemaSet* = object
    ## The documents of one accepted construction input set (`accept.nim`).
    primary*: CDocument
    interfaces*: seq[CDocument] ## in `_implements` order: ascending raw root
    supporting*: seq[CDocument] ## by namespace, then root

  CMember = object
    name: string
    ctype: string ## the type spelled before the name
    arrayLen: uint64 ## > 0: `ctype name[N]`
    arrayPtr: uint64 ## > 0: `ctype (*name)[N]`
    target: string ## the aggregate embedded by value, if any
    listTarget: string ## the aggregate a list member points into, if any
    recursive: bool ## a recursive by-value edge: `const ctype* name`

  DefKind = enum
    dAlias
    dStruct
    dChoice

  CDef = object
    key: string ## the qualified name; `<owner>#<path>` for an inline type
    typeName: string
    needs: seq[string] ## defs whose typedef names an alias spells
    forward: bool
    case kind: DefKind
    of dAlias:
      aliased: string
    of dStruct, dChoice:
      tag: string
      members: seq[CMember] ## struct members, or the union's arms
      enumName: string
      enumerators: seq[string]

  DocView = object
    model: SchemaModel
    common: bool ## the pinned common document: one `logos_` prefix
    external: bool ## declared by `logos_types.h`, not by this header
    cns: string ## the C namespace component

  Owner = object
    doc: int
    name: string ## the owning declaration's qualified name
    stem: string ## its C stem

  Gen = object
    docs: seq[DocView]
    byImport: Table[string, (int, string)]
    defs: Table[string, CDef]
    constraints: Table[string, string] ## typedef name -> declaration
    macros: Table[string, string]
    errors: seq[string]

func at[K, V](t: Table[K, V], k: K): V =
  ## A read of a key the caller knows is present.
  t.getOrDefault(k)

func documents*(s: CSchemaSet): seq[CDocument] =
  @[s.primary] & s.interfaces & s.supporting

# Spelling ------------------------------------------------------------------------

func scalarC(k: ScalarKind): string =
  ## [SPEC INTERFACE §2.2]
  case k
  of skBool: "bool"
  of skUint8: "uint8_t"
  of skUint16: "uint16_t"
  of skUint32: "uint32_t"
  of skUint64: "uint64_t"
  of skInt8: "int8_t"
  of skInt16: "int16_t"
  of skInt32: "int32_t"
  of skInt64: "int64_t"
  of skTstr: "const char*"
  of skBstr: "const uint8_t*"

func cString*(s: string): string =
  ## [IMPL-DECISION G65] A C string literal: printable ASCII as is, with `"`
  ## and `\` escaped and a second `?` of a pair escaped (no trigraphs); every
  ## other byte as `\xNN`. A hex digit right after an escape starts a new
  ## adjacent literal so it is not read into the escape.
  var o = "\""
  var afterHex = false
  var prev = '\0'
  for c in s:
    if afterHex and c in HexDigits:
      o.add("\"\"")
    afterHex = false
    if c == '"' or c == '\\' or (c == '?' and prev == '?'):
      o.add('\\')
      o.add(c)
    elif c >= ' ' and c <= '~':
      o.add(c)
    else:
      o.add("\\x" & toHex(ord(c), 2).toLowerAscii)
      afterHex = true
    prev = c
  o & "\""

func literalC(d: ScalarData): (string, string) =
  ## The C type and [IMPL-DECISION G65] the exact C scalar literal.
  case d.kind
  of skBool:
    ("bool", if d.boolean: "true" else: "false")
  of UnsignedKinds:
    ("uint64_t", "UINT64_C(" & $d.unsigned & ")")
  of SignedKinds:
    if d.signed == low(int64):
      ("int64_t", "(-INT64_C(9223372036854775807) - 1)")
    else:
      ("int64_t", "INT64_C(" & $d.signed & ")")
  of skTstr:
    ("const char*", cString(d.text))
  of skBstr:
    ("const uint8_t*", "") # construction admits no byte-string literal

func upper(s: string): string =
  s.toUpperAscii

func joinPath(stem: string, path: openArray[string]): string =
  var s = stem
  for p in path:
    s.add("_" & p)
  s

func inlineKey(o: Owner, path: openArray[string]): string =
  o.name & "#" & path.join("/")

func baseName(ctype: string): string =
  ## The type name a member spells, without `const` and pointers.
  ctype.replace("const ", "").replace("*", "").strip

# Resolution ----------------------------------------------------------------------

func stemOf(g: Gen, doc: int, name: string): string =
  ## [SPEC INTERFACE §2.1] The complete namespace projection, or one `logos_`
  ## prefix for the pinned common document.
  let v = g.docs[doc]
  if v.common:
    localName(name, v.model.namespace)
  else:
    v.cns & "_" & localName(name, v.model.namespace)

func typeNameOf(g: Gen, doc: int, name: string): string =
  "logos_" & g.stemOf(doc, name) & "_t"

func importKey(root, subtree: Digest): string =
  toHex(root) & toHex(subtree)

func resolve(g: Gen, doc: int, n: SchemaNode): (int, Declaration) =
  ## The declaration a reference node names (construction resolved it).
  if n.kind == snLocalRef:
    (doc, g.docs[doc].model.find(n.target).get)
  else:
    let (d, name) =
      g.byImport.getOrDefault(importKey(n.imported.root, n.imported.subtree), (0, ""))
    (d, g.docs[d].model.find(name).get)

func isAggregate(n: SchemaNode): bool =
  n.kind in {snMap, snList, snTuple, snChoice} or
    (n.kind == snPrimitive and n.scalar == skBstr)

func aggregateOf(g: Gen, doc: int, d: Declaration): string =
  ## The aggregate def a use of `d` embeds, through aliases; none for scalars
  ## and for types `logos_types.h` declares.
  var (cd, cur) = (doc, d)
  while true: # alias chains end: acceptance rejects alias cycles (G153)
    if g.docs[cd].external:
      return ""
    if cur.body.kind in {snLocalRef, snImportedRef}:
      (cd, cur) = g.resolve(cd, cur.body)
    elif cur.body.isAggregate:
      return cur.name
    else:
      return ""

# Constraint typedefs and macros --------------------------------------------------

proc tstrType(g: var Gen, n: SchemaNode): string =
  ## [SPEC INTERFACE §2.2] `logos_tstr_size_<n>_t` / `logos_tstr_size_<min>_<max>_t`.
  if n.size.isNone:
    return "const char*"
  let (lo, hi) = n.size.get
  let name =
    if lo == hi:
      "logos_tstr_size_" & $lo & "_t"
    else:
      "logos_tstr_size_" & $lo & "_" & $hi & "_t"
  g.constraints[name] = "typedef const char* " & name & ";"
  name

proc bstrPtrType(g: var Gen, n: SchemaNode): string =
  ## [SPEC INTERFACE §2.2] The pointer of an unbounded or ranged byte string.
  if n.size.isNone:
    return "const uint8_t*"
  let (lo, hi) = n.size.get
  let name = "logos_bstr_size_" & $lo & "_" & $hi & "_t"
  g.constraints[name] = "typedef const uint8_t* " & name & ";"
  name

func exactBstr(n: SchemaNode): Opt[uint64] =
  if n.kind == snPrimitive and n.scalar == skBstr and n.size.isSome and
      n.size.get[0] == n.size.get[1]:
    Opt.some(n.size.get[0])
  else:
    Opt.none(uint64)

proc literalMacro(g: var Gen, o: Owner, path: openArray[string], d: ScalarData) =
  ## [SPEC INTERFACE §2.3] `LOGOS_<owner and path>_LITERAL`; inside a choice the
  ## path holds `arm_<index>`, giving `<choice prefix>_ARM_<i>[_<FIELD>]_LITERAL`.
  let name = "LOGOS_" & upper(joinPath(o.stem, path)) & "_LITERAL"
  if name in g.macros:
    g.errors.add("C identifier collision: " & name & " is derived twice")
  g.macros[name] = literalC(d)[1]

# Definitions ---------------------------------------------------------------------

proc single(
  g: var Gen, o: Owner, path: seq[string], n: SchemaNode, name: string
): CMember

proc addDef(g: var Gen, d: CDef) =
  g.defs[d.key] = d

proc listMembers(
    g: var Gen, o: Owner, path: seq[string], n: SchemaNode, items, count: string
): seq[CMember] =
  ## [SPEC INTERFACE §2.3] `const T* items` + `size_t count`. A list element
  ## adds no by-value edge.
  let e = g.single(o, path & "list_item", n.element, items)
  var m = CMember(name: items, listTarget: e.target)
  if e.arrayLen > 0:
    m.ctype = "const uint8_t"
    m.arrayPtr = e.arrayLen
  elif e.ctype.endsWith("*"):
    m.ctype = e.ctype & " const*" # `[* tstr]`: `const char* const*`
  else:
    m.ctype = "const " & e.ctype & "*"
  @[m, CMember(name: count, ctype: "size_t")]

proc bstrMembers(g: var Gen, n: SchemaNode, data, len: string): seq[CMember] =
  ## [SPEC INTERFACE §2.2, §2.3] Pointer and length, `data[N]`, or the empty value.
  let exact = exactBstr(n)
  if exact.isSome:
    if exact.get == 0:
      @[CMember(name: data, ctype: "logos_bstr_size_0_t")]
    else:
      @[CMember(name: data, ctype: "uint8_t", arrayLen: exact.get)]
  else:
    @[CMember(name: data, ctype: g.bstrPtrType(n)), CMember(name: len, ctype: "size_t")]

proc fieldMembers(
    g: var Gen, o: Owner, path: seq[string], name: string, n: SchemaNode
): seq[CMember] =
  ## The members of one schema field named `name` (a map field or tuple
  ## position): pairs and inline tuples expand in place.
  case n.kind
  of snPrimitive:
    if n.scalar == skBstr and exactBstr(n).isNone:
      return g.bstrMembers(n, name, name & "_len")
  of snList:
    return g.listMembers(o, path, n, name, name & "_count")
  of snTuple:
    if n.items.len > 0:
      # [SPEC INTERFACE §2.3] Inline tuple field `x`: members `x_0`, `x_1`, ...
      var ms: seq[CMember]
      for i, item in n.items:
        ms.add(g.fieldMembers(o, path & ("tuple_" & $i), name & "_" & $i, item))
      return ms
  else:
    discard
  @[g.single(o, path, n, name)]

proc mapMembers(g: var Gen, o: Owner, path: seq[string], n: SchemaNode): seq[CMember] =
  ## [SPEC INTERFACE §2.3] Canonical field order; `bool has_<f>` right before the
  ## first member of an optional field [IMPL-DECISION G66].
  var ms: seq[CMember]
  for f in n.fields:
    if f.optional:
      ms.add(CMember(name: "has_" & f.name, ctype: "bool"))
    ms.add(g.fieldMembers(o, path & f.name, f.name, f.node))
  ms

func emptied(ms: seq[CMember]): seq[CMember] =
  ## [SPEC INTERFACE §2.3] An empty value's struct has one `uint8_t _empty`.
  if ms.len == 0:
    @[CMember(name: "_empty", ctype: "uint8_t")]
  else:
    ms

proc structDef(
    g: var Gen,
    key, tagKind, stem, typeName: string,
    o: Owner,
    path: seq[string],
    n: SchemaNode,
) =
  ## A struct for a map, byte string, list or tuple node at (`o`, `path`).
  var ms: seq[CMember]
  case n.kind
  of snMap:
    ms = g.mapMembers(o, path, n)
  of snList:
    ms = g.listMembers(o, path, n, "items", "count")
  of snTuple:
    for i, item in n.items:
      ms.add(g.fieldMembers(o, path & ("tuple_" & $i), "item_" & $i, item))
  of snPrimitive: # bstr
    # [SPEC INTERFACE §2.3] A named `bstr .size 0` is an empty value.
    if exactBstr(n) != Opt.some(0'u64):
      ms = g.bstrMembers(n, "data", "len")
  else:
    discard
  g.addDef(
    CDef(
      kind: dStruct,
      key: key,
      typeName: typeName,
      tag: "logos_" & tagKind & "_" & stem,
      members: emptied(ms),
    )
  )

proc choiceDef(
    g: var Gen,
    key, tagKind, stem, typeName, enumName: string,
    o: Owner,
    path: seq[string],
    n: SchemaNode,
) =
  ## [SPEC INTERFACE §2.3] Enum `LOGOS_<STEM>_ARM_<i>` and a struct with the
  ## `kind` tag [IMPL-DECISION G64] and a `value` union of `arm_<i>`, in
  ## canonical arm order.
  var arms: seq[CMember]
  var enumerators: seq[string]
  for i, a in n.arms:
    arms.add(g.single(o, path & ("arm_" & $i), a, "arm_" & $i))
    enumerators.add("LOGOS_" & upper(stem) & "_ARM_" & $i)
  g.addDef(
    CDef(
      kind: dChoice,
      key: key,
      typeName: typeName,
      tag: "logos_" & tagKind & "_" & stem,
      members: arms,
      enumName: enumName,
      enumerators: enumerators,
    )
  )

proc single(
    g: var Gen, o: Owner, path: seq[string], n: SchemaNode, name: string
): CMember =
  ## A one-member representation: struct members that are not pairs, list
  ## elements and union arms. [IMPL-DECISION G62] A list, nonempty tuple or
  ## unbounded or ranged byte string in such a position is a path-named struct
  ## (`logos_<stem>_list_t`, `_tuple_t`, `_bstr_t`).
  let stem = joinPath(o.stem, path)
  case n.kind
  of snPrimitive:
    case n.scalar
    of skTstr:
      CMember(name: name, ctype: g.tstrType(n))
    of skBstr:
      let exact = exactBstr(n)
      if exact.isSome:
        if exact.get == 0:
          CMember(name: name, ctype: "logos_bstr_size_0_t")
        else:
          CMember(name: name, ctype: "uint8_t", arrayLen: exact.get)
      else:
        let key = inlineKey(o, path)
        g.structDef(key, "bstr", stem, "logos_" & stem & "_bstr_t", o, path, n)
        CMember(name: name, ctype: "logos_" & stem & "_bstr_t", target: key)
    else:
      CMember(name: name, ctype: scalarC(n.scalar))
  of snLiteral:
    g.literalMacro(o, path, n.literal)
    CMember(name: name, ctype: literalC(n.literal)[0])
  of snMap:
    let key = inlineKey(o, path)
    g.structDef(key, "map", stem, "logos_" & stem & "_map_t", o, path, n)
    CMember(name: name, ctype: "logos_" & stem & "_map_t", target: key)
  of snChoice:
    let key = inlineKey(o, path)
    g.choiceDef(
      key,
      "choice",
      stem,
      "logos_" & stem & "_choice_t",
      "logos_" & stem & "_choice_kind_t",
      o,
      path,
      n,
    )
    CMember(name: name, ctype: "logos_" & stem & "_choice_t", target: key)
  of snList:
    let key = inlineKey(o, path)
    g.structDef(key, "list", stem, "logos_" & stem & "_list_t", o, path, n)
    CMember(name: name, ctype: "logos_" & stem & "_list_t", target: key)
  of snTuple:
    if n.items.len == 0:
      CMember(name: name, ctype: "logos_tuple_size_0_t")
    else:
      let key = inlineKey(o, path)
      g.structDef(key, "tuple", stem, "logos_" & stem & "_tuple_t", o, path, n)
      CMember(name: name, ctype: "logos_" & stem & "_tuple_t", target: key)
  of snLocalRef, snImportedRef:
    let (d, decl) = g.resolve(o.doc, n)
    CMember(
      name: name, ctype: g.typeNameOf(d, decl.name), target: g.aggregateOf(d, decl)
    )

proc declaration(g: var Gen, doc: int, d: Declaration) =
  ## The C declarations of one named schema declaration [SPEC INTERFACE §2.3,
  ## §2.4 rules 4-5, §2.5]. A map-valued method half has none (§2.4 flattens it
  ## into parameters), but its inline composites and literals do.
  let o = Owner(doc: doc, name: d.name, stem: g.stemOf(doc, d.name))
  let typeName = g.typeNameOf(doc, d.name)
  let kindName = "logos_" & o.stem & "_kind_t"
  case d.kind
  of dkMethod:
    discard
  of dkRequest, dkResponse:
    let n = d.body
    if n.kind == snChoice:
      g.choiceDef(d.name, "choice", o.stem, typeName, kindName, o, @[], n)
    else:
      discard g.mapMembers(o, @[], n)
  of dkEvent:
    let n = d.body
    if n.kind == snChoice: # [IMPL-DECISION G63]
      g.choiceDef(d.name, "event", o.stem, typeName, kindName, o, @[], n)
    else:
      g.structDef(d.name, "event", o.stem, typeName, o, @[], n)
  of dkType:
    let n = d.body
    case n.kind
    of snMap:
      g.structDef(d.name, "map", o.stem, typeName, o, @[], n)
    of snList:
      g.structDef(d.name, "list", o.stem, typeName, o, @[], n)
    of snTuple:
      g.structDef(d.name, "tuple", o.stem, typeName, o, @[], n)
    of snChoice:
      g.choiceDef(d.name, "choice", o.stem, typeName, kindName, o, @[], n)
    of snPrimitive:
      if n.scalar == skBstr:
        g.structDef(d.name, "bstr", o.stem, typeName, o, @[], n)
      else:
        # [SPEC INTERFACE §2.3] A named scalar or constrained string: a typedef.
        let m = g.single(o, @[], n, "")
        g.addDef(CDef(kind: dAlias, key: d.name, typeName: typeName, aliased: m.ctype))
    of snLiteral:
      g.literalMacro(o, @[], n.literal)
      g.addDef(
        CDef(
          kind: dAlias, key: d.name, typeName: typeName, aliased: literalC(n.literal)[0]
        )
      )
    of snLocalRef, snImportedRef:
      let (rd, rdecl) = g.resolve(doc, n)
      var a = CDef(
        kind: dAlias,
        key: d.name,
        typeName: typeName,
        aliased: g.typeNameOf(rd, rdecl.name),
      )
      if not g.docs[rd].external:
        a.needs.add(rdecl.name)
      g.addDef(a)

# Recursion and order -------------------------------------------------------------

func sccs*(nodes: seq[string], edges: Table[string, seq[string]]): Table[string, int] =
  ## Tarjan's strongly connected components, iteratively; node -> component.
  var
    index, low: Table[string, int]
    onStack: HashSet[string]
    stack: seq[string]
    comp: Table[string, int]
    counter = 0
    nextComp = 0
  for root in nodes:
    if root in index:
      continue
    var work: seq[(string, int)] = @[(root, 0)]
    while work.len > 0:
      let (v, i) = work[^1]
      if i == 0:
        index[v] = counter
        low[v] = counter
        inc counter
        stack.add(v)
        onStack.incl(v)
      let succ = edges.getOrDefault(v)
      if i < succ.len:
        work[^1] = (v, i + 1)
        let w = succ[i]
        if w notin index:
          work.add((w, 0))
        elif w in onStack:
          low[v] = min(low.at(v), index.at(w))
      else:
        discard work.pop()
        if work.len > 0:
          let parent = work[^1][0]
          low[parent] = min(low.at(parent), low.at(v))
        if low.at(v) == index.at(v):
          while true:
            let w = stack.pop()
            onStack.excl(w)
            comp[w] = nextComp
            if w == v:
              break
          inc nextComp
  comp

proc resolveGraph(g: var Gen) =
  ## [SPEC INTERFACE §2.3] Recursive by-value edges become `const T*` and their
  ## targets get forward typedefs. [IMPL-DECISION G154] So does every aggregate
  ## a list member points into from within its own reference cycle, whose
  ## typedef name is needed before its definition is complete.
  var
    nodes = toSeq(g.defs.keys)
    byValue, all: Table[string, seq[string]]
  nodes.sort()
  for k in nodes:
    let d = g.defs.at(k)
    if d.kind == dAlias:
      continue
    for m in d.members:
      if m.target in g.defs:
        byValue.mgetOrPut(k, @[]).add(m.target)
        all.mgetOrPut(k, @[]).add(m.target)
      if m.listTarget in g.defs:
        all.mgetOrPut(k, @[]).add(m.listTarget)
  let bv = sccs(nodes, byValue)
  let al = sccs(nodes, all)
  var bvSize, alSize: Table[int, int]
  for k in nodes:
    bvSize.mgetOrPut(bv.at(k), 0).inc
    alSize.mgetOrPut(al.at(k), 0).inc
  func onCycle(c: Table[string, int], size: Table[int, int], a, b: string): bool =
    c.at(a) == c.at(b) and (size.at(c.at(a)) > 1 or a == b)
  var forward: HashSet[string]
  for k in nodes:
    var d = g.defs.at(k)
    if d.kind == dAlias:
      continue
    for m in d.members.mitems:
      if m.target in g.defs and onCycle(bv, bvSize, k, m.target):
        m.recursive = true
        forward.incl(m.target)
      if m.listTarget in g.defs and onCycle(al, alSize, k, m.listTarget):
        forward.incl(m.listTarget)
    g.defs[k] = d
  for k in forward:
    g.defs.withValue(k, d):
      d.forward = true

proc ordered(g: Gen): seq[CDef] =
  ## [SPEC INTERFACE §2.1, §3.9.3; IMPL-DECISION G155] Non-recursive
  ## dependencies before dependents: each definition sorts by its dependency
  ## depth (the longest chain of definitions it waits for), then by qualified
  ## schema name. A definition waits for every aggregate it embeds by value
  ## (complete types) and for every typedef name it spells that no forward
  ## typedef supplies.
  var byType: Table[string, string]
  for k, d in g.defs:
    byType[d.typeName] = k
  var
    indegree: Table[string, int]
    dependents: Table[string, seq[string]]
  for k, d in g.defs:
    var deps: HashSet[string]
    template need(name: string) =
      let n = name
      if n.len > 0 and n != k and n in g.defs and not g.defs.at(n).forward:
        deps.incl(n)

    for n in d.needs:
      need(n)
    if d.kind != dAlias:
      for m in d.members:
        if m.target in g.defs and m.target != k and not m.recursive:
          deps.incl(m.target)
        need(m.listTarget)
        need(byType.getOrDefault(baseName(m.ctype)))
    indegree[k] = deps.len
    for n in deps:
      dependents.mgetOrPut(n, @[]).add(k)
  # Kahn's algorithm in rounds: one round per depth, each sorted by name.
  var level = toSeq(g.defs.keys).filterIt(indegree.at(it) == 0)
  var order: seq[CDef]
  while level.len > 0:
    level.sort()
    var next: seq[string]
    for k in level:
      order.add(g.defs.at(k))
      for n in dependents.getOrDefault(k):
        let left = indegree.at(n) - 1
        indegree[n] = left
        if left == 0:
          next.add(n)
    level = next
  order

# Rendering -----------------------------------------------------------------------

func render(m: CMember): string =
  if m.recursive:
    "const " & m.ctype & "* " & m.name & ";"
  elif m.arrayLen > 0:
    m.ctype & " " & m.name & "[" & $m.arrayLen & "];"
  elif m.arrayPtr > 0:
    m.ctype & " (*" & m.name & ")[" & $m.arrayPtr & "];"
  else:
    m.ctype & " " & m.name & ";"

func render(d: CDef): string =
  case d.kind
  of dAlias:
    "typedef " & d.aliased & " " & d.typeName & ";"
  of dStruct:
    let body = d.members.mapIt("    " & render(it)).join("\n")
    if d.forward:
      "struct " & d.tag & " {\n" & body & "\n};"
    else:
      "typedef struct " & d.tag & " {\n" & body & "\n} " & d.typeName & ";"
  of dChoice:
    var e = "typedef enum {\n"
    for i, x in d.enumerators:
      e.add("    " & x & " = " & $i & ",\n")
    e.add("} " & d.enumName & ";\n\n")
    let arms = d.members.mapIt("        " & render(it)).join("\n")
    let body = "    " & d.enumName & " kind;\n    union {\n" & arms & "\n    } value;"
    if d.forward:
      e & "struct " & d.tag & " {\n" & body & "\n};"
    else:
      e & "typedef struct " & d.tag & " {\n" & body & "\n} " & d.typeName & ";"

func forwardTypedef(d: CDef): string =
  "typedef struct " & d.tag & " " & d.typeName & ";"

func identifiers(d: CDef): seq[string] =
  var ids = @[d.typeName]
  if d.kind != dAlias:
    ids.add(d.tag)
  if d.kind == dChoice:
    ids.add(d.enumName)
    ids.add(d.enumerators)
  ids

proc emit(
    g: Gen, consts: openArray[(string, string)], skip: HashSet[string]
): seq[string] =
  ## [IMPL-DECISION G72] Metadata constants, then literal macros by name (as
  ## §3.9.2 places them), constraint typedefs by name, forward typedefs by
  ## qualified name, and type definitions in dependency order.
  let order = g.ordered
  var res: seq[string]
  for (name, value) in consts:
    res.add("#define " & name & " " & value)
  for name in toSeq(g.macros.keys).sorted:
    res.add("#define " & name & " " & g.macros.at(name))
  for name in toSeq(g.constraints.keys).sorted:
    if name notin skip:
      res.add(g.constraints.at(name))
  var forwards = order.filterIt(it.forward)
  forwards.sort(
    proc(a, b: CDef): int =
      cmp(a.key, b.key)
  )
  res.add(forwards.mapIt(forwardTypedef(it)))
  res.add(order.mapIt(render(it)))
  res

# logos_types.h -------------------------------------------------------------------

proc newGen(views: seq[DocView], roots: seq[Digest]): Gen =
  var g = Gen(docs: views)
  for i, v in views:
    for d in v.model.declarations:
      if d.kind != dkMethod:
        g.byImport[importKey(roots[i], declarationRoot(v.model, d))] = (i, d.name)
  g

func identifiersIn(text: string): HashSet[string] =
  ## Every `logos_…` / `LOGOS_…` identifier a C text mentions.
  var ids: HashSet[string]
  var i = 0
  while i < text.len:
    if (text.continuesWith("logos_", i) or text.continuesWith("LOGOS_", i)) and
        (i == 0 or text[i - 1] notin IdentChars):
      var j = i
      while j < text.len and text[j] in IdentChars:
        inc j
      ids.incl(text[i ..< j])
      i = j
    else:
      inc i
  ids

proc commonGen(): Gen =
  ## The pinned common schema's named types, which `logos_types.h` declares.
  let ctx = pinnedContext()
  var g = newGen(
    @[DocView(model: ctx.commonModel, common: true, external: false, cns: "")],
    @[ctx.commonRoot],
  )
  for d in ctx.commonModel.declarations:
    # [SPEC INTERFACE §2.1] logos.error_code reuses the fixed status enum.
    if d.kind == dkType and d.name != "logos.error_code":
      g.declaration(0, d)
  g.resolveGraph()
  g

func fixedBlock(): string =
  ## [SPEC INTERFACE §5.2] The fixed C block without its `logos_<module>_free`
  ## template (each module header declares its own), then the §2.3 empty types.
  var lines: seq[string]
  for l in LogosTypesFixed.splitLines:
    if "<module>" in l or l.strip == "/* -- Memory management -- */":
      continue
    lines.add(l)
  while lines.len > 0 and lines[^1].strip.len == 0:
    discard lines.pop()
  lines.join("\n") & "\n\n/* -- Empty values (INTERFACE §2.3) -- */\n\n" &
    LogosTypesEmpty.strip & "\n"

proc commonDeclarations*(): seq[string] =
  ## [SPEC INTERFACE §5.2] The canonical declarations of every named type in the
  ## pinned common schema except `logos.error_code`, with their constraint and
  ## inline support declarations.
  commonGen().emit([], initHashSet[string]())

proc logosTypesHeader*(): string =
  ## [SPEC INTERFACE §5.2] `logos_types.h`.
  "/* logos_types.h: generated by lcn-gen from INTERFACE §2.3, §5.1 and §5.2.\n" &
    " * " & ProvisionalStamp & ". Do not edit. */\n" & "#ifndef LOGOS_TYPES_H\n" &
    "#define LOGOS_TYPES_H\n\n" & fixedBlock() &
    "\n/* -- Common schema types (INTERFACE §5.1) -- */\n\n" &
    commonDeclarations().join("\n\n") & "\n\n#endif /* LOGOS_TYPES_H */\n"

let logosTypesIds = identifiersIn(logosTypesHeader())

# Contract headers ----------------------------------------------------------------

func methodCount(m: SchemaModel): int =
  m.declarations.countIt(it.kind == dkMethod)

func eventCount(m: SchemaModel): int =
  m.declarations.countIt(it.kind == dkEvent)

func roleConstants(s: CSchemaSet): seq[(string, string)] =
  ## [SPEC INTERFACE §2.1, §3.2] Document-role namespace constants where the
  ## declaration-only form cannot recover a document's namespace and role, and
  ## one constant per implemented interface; in the order of the §2.1 example:
  ## primary, implemented interfaces, interface roles, supporting roles.
  let many = s.documents.len > 1
  func needed(m: SchemaModel): bool =
    let recoverable =
      case m.role
      of srInterface:
        m.methodCount > 0 or m.eventCount > 0
      else:
        true # a module by its lifecycle symbols; supporting: no callables
    many or not isSimpleNamespace(m.namespace) or not recoverable

  func constant(m: SchemaModel): (string, string) =
    let name =
      case m.role
      of srModule:
        "LOGOS_" & upper(m.moduleName.get("")) & "_PRIMARY_NAMESPACE"
      of srInterface:
        "LOGOS_" & upper(projectNamespace(m.namespace)) & "_INTERFACE_NAMESPACE"
      else:
        "LOGOS_" & upper(projectNamespace(m.namespace)) & "_SUPPORTING_NAMESPACE"
    (name, cString(m.namespace))

  var cs: seq[(string, string)]
  let p = s.primary.model
  if p.needed:
    cs.add(constant(p))
  if p.role == srModule:
    for i, c in s.interfaces:
      cs.add(
        (
          "LOGOS_" & upper(p.moduleName.get("")) & "_IMPLEMENTS_" & $i,
          cString(c.model.namespace),
        )
      )
  for c in s.interfaces & s.supporting:
    if c.model.needed:
      cs.add(constant(c.model))
  cs

proc cDeclarations*(s: CSchemaSet): Result[seq[string], string] =
  ## [SPEC INTERFACE §2, §2.1-§2.3, §2.5] The canonical C type declarations of
  ## an accepted schema set, or why the set has none: a namespace-projection
  ## collision, or two identical C identifiers. [NX-04 interim] An identifier
  ## that `logos_types.h` already declares is a collision too.
  var views: seq[DocView]
  var roots: seq[Digest]
  var projections: Table[string, string]
  for c in s.documents:
    let cns = projectNamespace(c.model.namespace)
    if cns in projections:
      return err(
        "namespace-projection collision: " & c.model.namespace & " and " &
          projections.at(cns) & " both project to " & cns & " (INTERFACE §2.1)"
      )
    projections[cns] = c.model.namespace
    views.add(DocView(model: c.model, cns: cns))
    roots.add(c.root)
  let ctx = pinnedContext()
  views.add(DocView(model: ctx.commonModel, common: true, external: true))
  roots.add(ctx.commonRoot)
  var g = newGen(views, roots)
  for i in 0 ..< views.len - 1:
    for d in views[i].model.declarations:
      g.declaration(i, d)
  if g.errors.len > 0:
    return err(g.errors[0] & " (INTERFACE §2.1)")
  g.resolveGraph()
  let consts = roleConstants(s)
  var ids: seq[(string, string)]
  for k in toSeq(g.defs.keys).sorted:
    for id in g.defs.at(k).identifiers:
      ids.add((id, k))
  for (name, _) in consts:
    ids.add((name, "a schema-metadata constant"))
  for name in g.macros.keys:
    ids.add((name, "a literal macro"))
  for name in g.constraints.keys:
    if name notin logosTypesIds:
      ids.add((name, "a constraint typedef"))
  var seen: Table[string, string]
  for (id, origin) in ids:
    if id in seen:
      return err(
        "C identifier collision: " & id & " derives from " & origin & " and " &
          seen.at(id) & " (INTERFACE §2.1)"
      )
    if id in logosTypesIds:
      return err(
        "C identifier collision: " & id & " (from " & origin &
          ") is declared by logos_types.h (NX-04)"
      )
    seen[id] = origin
  ok(g.emit(consts, logosTypesIds))

func headerName*(s: CSchemaSet): string =
  ## The runtime module name, or the primary document's C namespace component.
  let p = s.primary.model
  if p.role == srModule:
    p.moduleName.get("")
  else:
    projectNamespace(p.namespace)

proc contractHeader*(s: CSchemaSet): Result[string, string] =
  ## The types header of one accepted set; it includes `logos_types.h`.
  let decls = ?cDeclarations(s)
  let name = s.headerName
  let guard = "LOGOS_" & upper(name) & "_TYPES_H"
  ok(
    "/* " & name & "_types.h: generated by lcn-gen. " & ProvisionalStamp & ".\n" &
      " * C types only (INTERFACE §2.1-§2.3, §2.5): method signatures and\n" &
      " * lifecycle symbols are not generated yet. Do not edit. */\n" & "#ifndef " &
      guard & "\n#define " & guard & "\n\n#include \"logos_types.h\"\n\n" &
      decls.join("\n\n") & "\n\n#endif /* " & guard & " */\n"
  )
