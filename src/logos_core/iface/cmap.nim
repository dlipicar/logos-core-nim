## INTERFACE §2, §2.1-§2.6, §3.2, §5.2: the canonical C mapping of an accepted
## schema set or module binding, C mapping revision 3.
##
## Derived here: semantic stems and their families (`_MAP`, `_BSTR`, `_LIST`,
## `_TUPLE`, `_CHOICE`, `_EVENT`, `_KIND_t`), choice arm labels in symbolic or
## indexed form with `uint32_t` discriminants, literal macros, constrained
## string typedefs, recursive-edge pointers and forward typedefs, the document
## role, implementation and sensitivity constants, the keyword escape, the
## contract-header frame (mapping-revision and commitment-context checks,
## document guards with their root macros, the C++ linkage wrapper), and
## `logos_types.h` (the fixed §5.2 and §2.3 blocks plus the common schema's
## named types), each method's `_FN_t` typedef (§2.4), and for a module
## binding its `_CALL_` provider functions and `_MODULE_` symbols (§2.4, §2.6).
## The fixed block carries the response owner (§2.7.1) and the asynchronous
## and invocation-context ABI (§2.9); optional helpers (App A) are not derived.
##
## Acceptance runs this mapping (`accept.nim`): an accepted set must be
## representable in C without two identical identifiers or a namespace-projection
## collision [SPEC INTERFACE §2, §2.1].
##
## Limits [SPEC INTERFACE §2.1; IMPL]: this mapping truncates no identifier and
## has no identifier-length limit of its own. Its input is bounded by the §5.3
## schema limits that acceptance enforces (documents, nodes, nesting), and the
## work and memory it uses grow linearly with that input; a choice whose
## largest discriminant would not fit `uint32_t` fails explicitly. Running out
## of memory aborts the process; no partial header is ever returned.
##
## Every header is stamped PROVISIONAL ABI: the common-name projection (G158) and
## G153 are open.

{.push raises: [].}

import std/[algorithm, sequtils, sets, strutils, tables]
import ../hash/hashinput
import ../base/hex
import ../pins
import ../commitment
import ./names

const
  ProvisionalStamp* = "PROVISIONAL ABI (spec " & SpecRevision[0 .. 7] & ")"
  CMappingRevision* = 3
    ## [SPEC INTERFACE §2] `LOGOS_C_MAPPING_REVISION` of this mapping (tests
    ## compare it with the §2 and §5.2 mirrors)

type
  CDocument* = object
    model*: SchemaModel
    root*: Digest

  CSchemaSet* = object
    ## The documents of one accepted construction input set or module binding
    ## (`accept.nim`).
    primary*: Opt[CDocument]
      ## the subject document, or the binding's concrete module document
    interfaces*: seq[CDocument] ## implemented interfaces: ascending raw root
    supporting*: seq[CDocument] ## by namespace, then root
    module*: Opt[string]
      ## [SPEC INTERFACE §2] the module binding's runtime module name, if any

  MemberRole = enum
    mrValue ## one value: a scalar, text string, literal or aggregate
    mrPresence ## `bool has_<field>`
    mrBytes ## an unbounded or ranged byte string's pointer
    mrLen ## its `<field>_len`
    mrList ## a variable-length list's element pointer
    mrCount ## its `<field>_count`
    mrArray ## a positive exact-size byte string, `uint8_t <field>[N]`

  CMember = object
    name: string ## the complete, escaped C identifier
    raw: string ## the complete identifier before the escape (§2.1, §2.4)
    role: MemberRole
    byPointer: bool
      ## a value with a struct representation, which a method passes by
      ## pointer (§2.4 rule 10, §2.3), empty values included
    element: string ## a list's element type (§2.4 rule 9)
    ctype: string ## the type spelled before the name
    arrayLen: uint64 ## > 0: `ctype name[N]`
    target: string ## the aggregate embedded by value, if any
    listTarget: string ## the aggregate a list member points into, if any
    recursive: bool ## a recursive by-value edge: `const ctype* name`

  DefKind = enum
    dAlias
    dStruct
    dChoice

  CDef = object
    key: string ## the qualified name; `<owner>#<path>` for an inline type
    doc: int ## the document whose group declares it
    typeName: string
    needs: seq[string] ## defs whose typedef names an alias spells
    forward: bool
    case kind: DefKind
    of dAlias:
      aliased: string
    of dStruct, dChoice:
      tag: string
      members: seq[CMember] ## struct members, or the union's arms
      kindName: string ## a choice's discriminant typedef
      cases: seq[(string, uint64)] ## a choice's arm constants, by value

  DocView = object
    model: SchemaModel
    common: bool ## the pinned common document (G158 names)
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
    macros: Table[string, (int, string)] ## literal macro -> (document, value)
    halves: Table[string, seq[CMember]]
      ## a map-valued method half's members, by its qualified name (§2.4)
    errors: seq[string]

func at[K, V](t: Table[K, V], k: K): V =
  ## A read of a key the caller knows is present.
  t.getOrDefault(k)

func documents*(s: CSchemaSet): seq[CDocument] =
  ## The primary document, if any, then the interfaces, then the supporting
  ## schemas.
  var docs: seq[CDocument]
  if s.primary.isSome:
    docs.add(s.primary.get)
  docs & s.interfaces & s.supporting

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
  ## [SPEC INTERFACE §2.3] A generated text literal: one C string literal with
  ## the exact bytes. Printable ASCII as is, except `\"`, `\\` and `\?`;
  ## `\n`, `\r`, `\t`; every other byte as exactly three octal digits.
  var o = "\""
  for c in s:
    case c
    of '"':
      o.add("\\\"")
    of '\\':
      o.add("\\\\")
    of '?':
      o.add("\\?")
    of '\n':
      o.add("\\n")
    of '\r':
      o.add("\\r")
    of '\t':
      o.add("\\t")
    of ' ' .. '!', '#' .. '>', '@' .. '[', ']' .. '~':
      o.add(c)
    else:
      let b = ord(c)
      o.add('\\')
      o.add(char(ord('0') + (b shr 6)))
      o.add(char(ord('0') + ((b shr 3) and 7)))
      o.add(char(ord('0') + (b and 7)))
  o & "\""

func literalC(d: ScalarData): (string, string) =
  ## [SPEC INTERFACE §2.3] The C type and the generated literal spelling.
  case d.kind
  of skBool:
    ("bool", if d.boolean: "true" else: "false")
  of UnsignedKinds:
    ("uint64_t", "UINT64_C(" & $d.unsigned & ")")
  of SignedKinds:
    if d.signed >= 0:
      ("int64_t", "UINT64_C(" & $d.signed & ")")
    elif d.signed == low(int64):
      ("int64_t", "(-INT64_C(9223372036854775807) - INT64_C(1))")
    else:
      ("int64_t", "(-INT64_C(" & $(-d.signed) & "))")
  of skTstr:
    ("const char*", cString(d.text))
  of skBstr:
    ("const uint8_t*", "") # construction admits no byte-string literal

func stemPath(stem: string, path: openArray[string]): string =
  stem & path.join("")

func inlineKey(o: Owner, path: openArray[string]): string =
  o.name & "#" & path.join("")

func baseName(ctype: string): string =
  ## The type name a member spells, without `const` and pointers.
  ctype.replace("const ", "").replace("*", "").strip

func hexLower(s: string): string =
  for c in s:
    result.add(toHex(ord(c), 2).toLowerAscii)

func contextMarkers*(): seq[string] =
  ## [SPEC INTERFACE §2] The commitment-context markers of the pinned model,
  ## profile and suite: `LOGOS_C_CONTEXT_<KIND>_<hex of the identifier>`.
  @[
    "LOGOS_C_CONTEXT_MODEL_" & hexLower(CommitmentModelId),
    "LOGOS_C_CONTEXT_PROFILE_" & hexLower(HashProfileId),
    "LOGOS_C_CONTEXT_SUITE_" & hexLower(HashSuiteId),
  ]

# Resolution ----------------------------------------------------------------------

func stemOf(g: Gen, doc: int, name: string): string =
  ## [SPEC INTERFACE §2.1] A named declaration's stem: the C namespace component,
  ## one underscore and the capitalized local name.
  ## [IMPL-DECISION G158, pending] The pinned common document's stem is its
  ## local name unchanged, which gives the three names §2.1 fixes
  ## (`logos_error_code_t`, `logos_error_detail_t`, `logos_schema_commitment_t`).
  let v = g.docs[doc]
  let local = localName(name, v.model.namespace)
  if v.common:
    local
  else:
    v.cns & "_" & capitalize(local)

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

func structRef(g: Gen, doc: int, d: Declaration): bool =
  ## [SPEC INTERFACE §2.3, §2.4 rule 10] Whether a use of `d` has a struct
  ## representation, through aliases and into `logos_types.h`. The common
  ## `logos.error_code` is the fixed enum `logos_error_code_t` (§2.1).
  var (cd, cur) = (doc, d)
  while true: # alias chains end: acceptance rejects alias cycles (G153)
    if g.docs[cd].common and cur.name == "logos.error_code":
      return false
    if cur.body.kind in {snLocalRef, snImportedRef}:
      (cd, cur) = g.resolve(cd, cur.body)
    else:
      return cur.body.isAggregate

# Arm labels ------------------------------------------------------------------------

func literalToken(d: ScalarData): Opt[string] =
  ## [SPEC INTERFACE §2.3] `true`/`false`, `num<n>`, `neg<magnitude>`, or a text
  ## literal with each hyphen as an underscore when that is a schema atom.
  case d.kind
  of skBool:
    Opt.some(if d.boolean: "true" else: "false")
  of UnsignedKinds:
    Opt.some("num" & $d.unsigned)
  of SignedKinds:
    if d.signed >= 0:
      Opt.some("num" & $d.signed)
    else:
      Opt.some("neg" & $(uint64(not d.signed) + 1))
  of skTstr:
    let t = d.text.replace('-', '_')
    if t.isSchemaIdentifier:
      Opt.some(t)
    else:
      Opt.none(string)
  of skBstr:
    Opt.none(string)

func referenceLabel*(namespace, name: string): string =
  ## [SPEC INTERFACE §2.3] The arm label of a named reference: the defining C
  ## namespace component, `_`, and the capitalized local declaration name.
  projectNamespace(namespace) & "_" & capitalize(localName(name, namespace))

func armLabelOf*(n: SchemaNode, reference = ""): Opt[string] =
  ## [SPEC INTERFACE §2.3] The candidate label of one canonical arm, without
  ## following named references; `reference` is a reference arm's
  ## `referenceLabel`.
  case n.kind
  of snPrimitive:
    Opt.some(capitalize($n.scalar))
  of snLiteral:
    let t = literalToken(n.literal)
    if t.isSome:
      Opt.some(capitalize(t.get))
    else:
      Opt.none(string)
  of snMap:
    var tokens: seq[string]
    var required: seq[string]
    for f in n.fields: # canonical order: UTF-8 field-name bytes
      if f.optional:
        continue
      required.add(f.name)
      if f.node.kind == snLiteral:
        let t = literalToken(f.node.literal)
        if t.isNone:
          return Opt.none(string) # never silently left out
        tokens.add(t.get)
    if tokens.len > 0:
      Opt.some(capitalize(tokens.join("_")))
    else:
      Opt.some("Map" & required.mapIt("_" & it).join(""))
  of snList:
    Opt.some("List")
  of snTuple:
    Opt.some("Tuple" & $n.items.len)
  of snLocalRef, snImportedRef:
    Opt.some(reference)
  of snChoice:
    Opt.none(string)

func choiceSteps*(labels: openArray[Opt[string]]): (bool, seq[string]) =
  ## [SPEC INTERFACE §2.3] (symbolic, one label or decimal index per canonical
  ## arm): symbolic when every arm has a label and the labels are distinct.
  var res: seq[string]
  var seen: HashSet[string]
  for l in labels:
    if l.isNone or seen.containsOrIncl(l.get):
      return (false, toSeq(0 ..< labels.len).mapIt($it))
    res.add(l.get)
  (true, res)

func discriminantOrder*(symbolic: bool, steps: seq[string]): seq[int] =
  ## [SPEC INTERFACE §2.3] Canonical arm indices by C discriminant value: labels
  ## in ascending ASCII order, or the canonical order itself.
  var order = toSeq(0 ..< steps.len)
  if symbolic:
    order.sort(
      proc(a, b: int): int =
        cmp(steps[a], steps[b])
    )
  order

func armSteps(g: Gen, doc: int, n: SchemaNode): (bool, seq[string]) =
  var labels: seq[Opt[string]]
  for a in n.arms:
    if a.kind in {snLocalRef, snImportedRef}:
      let (d, decl) = g.resolve(doc, a)
      labels.add(armLabelOf(a, referenceLabel(g.docs[d].model.namespace, decl.name)))
    else:
      labels.add(armLabelOf(a))
  choiceSteps(labels)

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
  ## [SPEC INTERFACE §2.1, §2.3] `LOGOS_LITERAL_<stem>`, with the literal's
  ## complete path.
  let name = "LOGOS_LITERAL_" & stemPath(o.stem, path)
  if name in g.macros:
    g.errors.add("C identifier collision: " & name & " is derived twice")
  g.macros[name] = (o.doc, literalC(d)[1])

# Definitions ---------------------------------------------------------------------

proc single(
  g: var Gen, o: Owner, path: seq[string], n: SchemaNode, name: string
): CMember

proc position(
  g: var Gen, o: Owner, path: seq[string], n: SchemaNode, name: string
): CMember

proc addDef(g: var Gen, d: CDef) =
  g.defs[d.key] = d

proc listMembers(
    g: var Gen, o: Owner, path: seq[string], n: SchemaNode, items, count: string
): seq[CMember] =
  ## [SPEC INTERFACE §2.3] `const T* items` + `size_t count` (unescaped names
  ## given), the element at path step `_LI`. A list element adds no by-value
  ## edge.
  let e = g.position(o, path & "_LI", n.element, escapeC(items))
  var m = CMember(
    name: escapeC(items),
    raw: items,
    role: mrList,
    element: e.ctype,
    listTarget: e.target,
  )
  if e.ctype.endsWith("*"):
    m.ctype = e.ctype & " const*" # `[* tstr]`: `const char* const*`
  else:
    m.ctype = "const " & e.ctype & "*"
  @[m, CMember(name: escapeC(count), raw: count, role: mrCount, ctype: "size_t")]

proc fieldMembers(
    g: var Gen, o: Owner, path: seq[string], name: string, n: SchemaNode
): seq[CMember] =
  ## [SPEC INTERFACE §2.2, §2.3] The members of the map field `name` at `path`:
  ## a byte-string pair or array, a list pair, or an inline tuple's adjacent
  ## `<name>_<i>` positions. Each complete identifier is escaped (§2.1).
  case n.kind
  of snPrimitive:
    if n.scalar == skBstr:
      let exact = exactBstr(n)
      if exact.isNone:
        return @[
          CMember(
            name: escapeC(name), raw: name, role: mrBytes, ctype: g.bstrPtrType(n)
          ),
          CMember(
            name: escapeC(name & "_len"),
            raw: name & "_len",
            role: mrLen,
            ctype: "size_t",
          ),
        ]
      if exact.get > 0:
        return @[
          CMember(
            name: escapeC(name),
            raw: name,
            role: mrArray,
            ctype: "uint8_t",
            arrayLen: exact.get,
          )
        ]
  of snList:
    return g.listMembers(o, path, n, name, name & "_count")
  of snTuple:
    if n.items.len > 0:
      var ms: seq[CMember]
      for i, item in n.items:
        var m = g.position(o, path & ("_TU" & $i), item, escapeC(name & "_" & $i))
        m.raw = name & "_" & $i
        ms.add(m)
      return ms
  else:
    discard
  var m = g.single(o, path, n, escapeC(name))
  m.raw = name
  @[m]

proc mapMembers(g: var Gen, o: Owner, path: seq[string], n: SchemaNode): seq[CMember] =
  ## [SPEC INTERFACE §2.3] Canonical field order; `bool has_<f>` right before the
  ## first member of an optional field, governing all of them.
  var ms: seq[CMember]
  for f in n.fields:
    if f.optional:
      ms.add(
        CMember(
          name: escapeC("has_" & f.name),
          raw: "has_" & f.name,
          role: mrPresence,
          ctype: "bool",
        )
      )
    ms.add(g.fieldMembers(o, path & ("_" & capitalize(f.name)), f.name, f.node))
  ms

func emptied(ms: seq[CMember]): seq[CMember] =
  ## [SPEC INTERFACE §2.3] An empty value's struct has one `uint8_t _empty`.
  if ms.len == 0:
    @[CMember(name: "_empty", ctype: "uint8_t")]
  else:
    ms

proc structDef(
    g: var Gen, key, family, stem: string, o: Owner, path: seq[string], n: SchemaNode
) =
  ## The `logos_<stem>_<FAMILY>` struct of a map, byte string, list or tuple
  ## node at (`o`, `path`), typedef `logos_<stem>_t`.
  var ms: seq[CMember]
  case n.kind
  of snMap:
    ms = g.mapMembers(o, path, n)
  of snList:
    ms = g.listMembers(o, path, n, "items", "count")
  of snTuple:
    for i, item in n.items:
      ms.add(g.position(o, path & ("_TU" & $i), item, "item_" & $i))
  of snPrimitive: # bstr
    let exact = exactBstr(n)
    if exact.isNone:
      ms = @[
        CMember(name: "data", ctype: g.bstrPtrType(n)),
        CMember(name: "len", ctype: "size_t"),
      ]
    elif exact.get > 0:
      ms = @[CMember(name: "data", ctype: "uint8_t", arrayLen: exact.get)]
  else:
    discard
  g.addDef(
    CDef(
      kind: dStruct,
      key: key,
      doc: o.doc,
      typeName: "logos_" & stem & "_t",
      tag: "logos_" & stem & "_" & family,
      members: emptied(ms),
    )
  )

proc choiceDef(
    g: var Gen, key, stem: string, o: Owner, path: seq[string], n: SchemaNode
) =
  ## [SPEC INTERFACE §2.3] `typedef uint32_t logos_<stem>_KIND_t`, one
  ## `LOGOS_ARM_<stem>_CASE…` constant per arm, and `logos_<stem>_CHOICE` with the
  ## `kind` member and, when any arm has payload storage, the `value` union.
  ## Symbolic form numbers the labels in ASCII order; indexed form uses the
  ## canonical arm index. A direct literal arm has a literal macro and no member.
  if n.arms.len > 0 and uint64(n.arms.len - 1) > uint64(high(uint32)):
    g.errors.add(
      "mapping limit: the choice " & stem & " has more arms than a uint32_t " &
        "discriminant numbers"
    )
    return
  let (symbolic, steps) = g.armSteps(o.doc, n)
  let order = discriminantOrder(symbolic, steps)
  var cases: seq[(string, uint64)]
  var arms: seq[CMember]
  for value, i in order:
    let a = n.arms[i]
    let (step, constant, member) =
      if symbolic:
        ("_AR_" & steps[i], "_CASE_" & steps[i], "arm_" & steps[i])
      else:
        ("_AR" & steps[i], "_CASE" & steps[i], "arm_" & steps[i])
    cases.add(("LOGOS_ARM_" & stem & constant, uint64(value)))
    if a.kind == snLiteral:
      g.literalMacro(o, path & step, a.literal)
    else:
      arms.add(g.position(o, path & step, a, member))
  g.addDef(
    CDef(
      kind: dChoice,
      key: key,
      doc: o.doc,
      typeName: "logos_" & stem & "_t",
      tag: "logos_" & stem & "_CHOICE",
      members: arms,
      kindName: "logos_" & stem & "_KIND_t",
      cases: cases,
    )
  )

proc position(
    g: var Gen, o: Owner, path: seq[string], n: SchemaNode, name: string
): CMember =
  ## [SPEC INTERFACE §2.3] A tuple position, list element or choice arm: an
  ## inline tuple, list or byte string is one aggregate value named by its path
  ## (`_TUPLE`, `_LIST`, `_BSTR`, a positive exact size as `data[N]`); `[]` and
  ## `bstr .size 0` are the shared empty values.
  let stem = stemPath(o.stem, path)
  case n.kind
  of snPrimitive:
    if n.scalar != skBstr:
      return g.single(o, path, n, name)
    if exactBstr(n) == Opt.some(0'u64):
      return CMember(name: name, ctype: "logos_bstr_size_0_t", byPointer: true)
    let key = inlineKey(o, path)
    g.structDef(key, "BSTR", stem, o, path, n)
    CMember(name: name, ctype: "logos_" & stem & "_t", target: key, byPointer: true)
  of snList:
    let key = inlineKey(o, path)
    g.structDef(key, "LIST", stem, o, path, n)
    CMember(name: name, ctype: "logos_" & stem & "_t", target: key, byPointer: true)
  of snTuple:
    if n.items.len == 0:
      return CMember(name: name, ctype: "logos_tuple_size_0_t", byPointer: true)
    let key = inlineKey(o, path)
    g.structDef(key, "TUPLE", stem, o, path, n)
    CMember(name: name, ctype: "logos_" & stem & "_t", target: key, byPointer: true)
  else:
    g.single(o, path, n, name)

proc single(
    g: var Gen, o: Owner, path: seq[string], n: SchemaNode, name: string
): CMember =
  ## A one-member representation of a scalar, literal, inline map or choice, or
  ## named reference at (`o`, `path`).
  let stem = stemPath(o.stem, path)
  case n.kind
  of snPrimitive:
    case n.scalar
    of skTstr:
      CMember(name: name, ctype: g.tstrType(n))
    of skBstr:
      g.position(o, path, n, name)
    else:
      CMember(name: name, ctype: scalarC(n.scalar))
  of snLiteral:
    g.literalMacro(o, path, n.literal)
    CMember(name: name, ctype: literalC(n.literal)[0])
  of snMap:
    let key = inlineKey(o, path)
    g.structDef(key, "MAP", stem, o, path, n)
    CMember(name: name, ctype: "logos_" & stem & "_t", target: key, byPointer: true)
  of snChoice:
    let key = inlineKey(o, path)
    g.choiceDef(key, stem, o, path, n)
    CMember(name: name, ctype: "logos_" & stem & "_t", target: key, byPointer: true)
  of snList, snTuple:
    g.position(o, path, n, name)
  of snLocalRef, snImportedRef:
    let (d, decl) = g.resolve(o.doc, n)
    CMember(
      name: name,
      ctype: g.typeNameOf(d, decl.name),
      target: g.aggregateOf(d, decl),
      byPointer: g.structRef(d, decl),
    )

proc declaration(g: var Gen, doc: int, d: Declaration) =
  ## The C declarations of one named schema declaration [SPEC INTERFACE §2.3,
  ## §2.4 rules 4-5, §2.5]. A map-valued method half has none (§2.4 flattens it
  ## into parameters, kept in `halves`), but its inline composites and literals
  ## do.
  let o = Owner(doc: doc, name: d.name, stem: g.stemOf(doc, d.name))
  let typeName = g.typeNameOf(doc, d.name)
  case d.kind
  of dkMethod:
    discard
  of dkRequest, dkResponse:
    let n = d.body
    if n.kind == snChoice:
      g.choiceDef(d.name, o.stem, o, @[], n)
    else:
      g.halves[d.name] = g.mapMembers(o, @[], n)
  of dkEvent:
    let n = d.body
    if n.kind == snChoice:
      # [SPEC INTERFACE §2.5] The ordinary choice, no wrapper.
      g.choiceDef(d.name, o.stem, o, @[], n)
    else:
      g.structDef(d.name, "EVENT", o.stem, o, @[], n)
  of dkType:
    let n = d.body
    case n.kind
    of snMap:
      g.structDef(d.name, "MAP", o.stem, o, @[], n)
    of snList:
      g.structDef(d.name, "LIST", o.stem, o, @[], n)
    of snTuple:
      g.structDef(d.name, "TUPLE", o.stem, o, @[], n)
    of snChoice:
      g.choiceDef(d.name, o.stem, o, @[], n)
    of snPrimitive:
      if n.scalar == skBstr:
        g.structDef(d.name, "BSTR", o.stem, o, @[], n)
      else:
        # [SPEC INTERFACE §2.3] A named scalar or constrained string: a typedef.
        let m = g.single(o, @[], n, "")
        g.addDef(
          CDef(
            kind: dAlias, key: d.name, doc: doc, typeName: typeName, aliased: m.ctype
          )
        )
    of snLiteral:
      g.literalMacro(o, @[], n.literal)
      g.addDef(
        CDef(
          kind: dAlias,
          key: d.name,
          doc: doc,
          typeName: typeName,
          aliased: literalC(n.literal)[0],
        )
      )
    of snLocalRef, snImportedRef:
      let (rd, rdecl) = g.resolve(doc, n)
      var a = CDef(
        kind: dAlias,
        key: d.name,
        doc: doc,
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
  ## targets get forward typedefs. So does every aggregate a list member points
  ## into from within its own reference cycle: its name is used before its
  ## complete definition (§2.3 l.1077). Every other use waits for the
  ## definition (`ordered`).
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

proc ordered(g: Gen): Result[seq[CDef], string] =
  ## [SPEC INTERFACE §2.1, §2.3] Every name declared before a use that needs
  ## its declaration and every type defined before a use that needs its
  ## complete definition. [IMPL] Placement is not canonical (§2.1): each
  ## definition sorts by its dependency depth (the longest chain of definitions
  ## it waits for), then by qualified schema name. A definition waits for every
  ## aggregate it embeds by value and for every typedef name it spells that no
  ## forward typedef supplies.
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
  if order.len != g.defs.len:
    return err("the declarations have no dependency order")
  ok(order)

# Rendering -----------------------------------------------------------------------

func render(m: CMember): string =
  if m.recursive:
    "const " & m.ctype & "* " & m.name & ";"
  elif m.arrayLen > 0:
    m.ctype & " " & m.name & "[" & $m.arrayLen & "];"
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
    var e = "typedef uint32_t " & d.kindName & ";\n"
    for (name, value) in d.cases:
      e.add("#define " & name & " " & $value & "u\n")
    var body = "    " & d.kindName & " kind;"
    if d.members.len > 0:
      let arms = d.members.mapIt("        " & render(it)).join("\n")
      body.add("\n    union {\n" & arms & "\n    } value;")
    if d.forward:
      e & "\nstruct " & d.tag & " {\n" & body & "\n};"
    else:
      e & "\ntypedef struct " & d.tag & " {\n" & body & "\n} " & d.typeName & ";"

func forwardTypedef(d: CDef): string =
  "typedef struct " & d.tag & " " & d.typeName & ";"

func identifiers(d: CDef): seq[string] =
  var ids = @[d.typeName]
  if d.kind != dAlias:
    ids.add(d.tag)
  if d.kind == dChoice:
    ids.add(d.kindName)
    ids.add(d.cases.mapIt(it[0]))
  ids

type DocGroup = object
  ## One document's declarations: its constants, literal macros, forward
  ## typedefs, definitions and method typedefs.
  consts: seq[(string, string)]
  macros: seq[(string, string)]
  forwards: seq[string]
  defs: seq[string]
  fns: seq[string]

proc groups(g: Gen, consts: seq[seq[(string, string)]]): Result[seq[DocGroup], string] =
  ## [IMPL] Within a group: constants, literal macros by name, forward typedefs
  ## by qualified name, definitions in dependency order.
  let order = ?g.ordered
  var gs = newSeq[DocGroup](g.docs.len)
  for i in 0 ..< consts.len:
    gs[i].consts = consts[i]
  for name in toSeq(g.macros.keys).sorted:
    let (doc, value) = g.macros.at(name)
    gs[doc].macros.add((name, value))
  var forwards = order.filterIt(it.forward)
  forwards.sort(
    proc(a, b: CDef): int =
      cmp(a.key, b.key)
  )
  for d in forwards:
    gs[d.doc].forwards.add(forwardTypedef(d))
  for d in order:
    gs[d.doc].defs.add(render(d))
  ok(gs)

func flat(gr: DocGroup): seq[string] =
  var res: seq[string]
  for (name, value) in gr.consts:
    res.add("#define " & name & " " & value)
  for (name, value) in gr.macros:
    res.add("#define " & name & " " & value)
  res & gr.forwards & gr.defs & gr.fns

# Methods and module symbols ------------------------------------------------------

type CParam = object
  ctype, name: string
  arrayLen: uint64 ## > 0: `ctype (*name)[N]`

func render(p: CParam): string =
  if p.arrayLen > 0:
    p.ctype & " (*" & p.name & ")[" & $p.arrayLen & "]"
  else:
    p.ctype & " " & p.name

func memberParam(m: CMember, input: bool): CParam =
  ## [SPEC INTERFACE §2.4 rules 2-10, §2.3] One flattened member as a method
  ## parameter: the direction prefix once, on the complete identifier, then the
  ## keyword escape (§2.1). Inputs keep the member's type, except that a struct
  ## representation is `const T*` and an exact-size byte string
  ## `const uint8_t (*)[N]`; outputs point to it, except that a list is
  ## `<element>**` (rule 9) and an exact-size byte string `uint8_t (*)[N]`.
  ## [IMPL I64] An unbounded byte string's output is `const uint8_t**`: §2.3
  ## gives it the ranged form's representation, whose pointer typedef is const.
  let name = escapeC((if input: "in_" else: "out_") & m.raw)
  case m.role
  of mrArray:
    CParam(
      ctype: (if input: "const uint8_t" else: "uint8_t"),
      name: name,
      arrayLen: m.arrayLen,
    )
  of mrList:
    CParam(ctype: (if input: m.ctype else: m.element & "**"), name: name)
  of mrValue:
    if m.byPointer:
      CParam(ctype: (if input: "const " else: "") & m.ctype & "*", name: name)
    else:
      CParam(ctype: (if input: m.ctype else: m.ctype & "*"), name: name)
  of mrPresence, mrBytes, mrLen, mrCount:
    CParam(ctype: (if input: m.ctype else: m.ctype & "*"), name: name)

func halfParams(g: Gen, doc: int, half: string, input: bool): seq[CParam] =
  ## [SPEC INTERFACE §2.4] A method half's parameters: a choice-valued half is the
  ## one `in_request` or `out_response` wrapper (rules 4-5); a map-valued half is
  ## flattened in canonical field order; an empty map adds none (rule 7).
  let d = g.docs[doc].model.find(half).get
  if d.body.kind == snChoice:
    let t = g.typeNameOf(doc, half)
    if input:
      return @[CParam(ctype: "const " & t & "*", name: "in_request")]
    return @[CParam(ctype: t & "*", name: "out_response")]
  g.halves.getOrDefault(half).mapIt(memberParam(it, input))

func methodParams(g: Gen, doc: int, m: Declaration): seq[CParam] =
  ## [SPEC INTERFACE §2.4 rule 1, §3.3] The ABI state parameters, then the
  ## request's, then the response's.
  @[
    CParam(ctype: "logos_module_context_t*", name: "module"),
    CParam(ctype: "logos_response_owner_t*", name: "response_owner"),
  ] & g.halfParams(doc, m.request, true) & g.halfParams(doc, m.response, false)

func renderParams(ps: seq[CParam]): string =
  "(\n" & ps.mapIt("    " & render(it)).join(",\n") & "\n)"

func methodComponent(g: Gen, doc: int, m: Declaration): string =
  ## [SPEC INTERFACE §2.1] `<namespace>_<Method>`: the defining contract's C
  ## namespace component and the bare method name, its first ASCII letter
  ## capitalized.
  let v = g.docs[doc]
  v.cns & "_" & capitalize(bareMethodName(m.name, v.model.namespace))

func fnTypedefName(g: Gen, doc: int, m: Declaration): string =
  "logos_" & g.methodComponent(doc, m) & "_FN_t"

func fnTypedef(g: Gen, doc: int, m: Declaration): string =
  ## [SPEC INTERFACE §2.4] `logos_<namespace>_<Method>_FN_t`, the defining
  ## contract's method typedef.
  "typedef logos_result_t (*" & g.fnTypedefName(doc, m) & ")" &
    renderParams(g.methodParams(doc, m)) & ";"

func callName(g: Gen, doc: int, m: Declaration, moduleC: string): string =
  "logos_" & moduleC & "_CALL_" & g.methodComponent(doc, m)

func callDeclaration(g: Gen, doc: int, m: Declaration, moduleC: string): string =
  ## [SPEC INTERFACE §2.4, §3.3] The concrete provider function: exactly the
  ## typedef's return type and parameters.
  "logos_result_t " & g.callName(doc, m, moduleC) & renderParams(g.methodParams(doc, m)) &
    ";"

func moduleSymbols(moduleC: string, provider: bool): seq[(string, string)] =
  ## [SPEC INTERFACE §2.6] (name, declaration) of the identity and lifecycle
  ## symbols and, for a provider, the call-surface, free and dispatch symbols.
  ## [IMPL] The optional `_MODULE_apply_configuration` and `_MODULE_async_api`
  ## are left to the module author, who declares the ones it exports.
  let p = "logos_" & moduleC & "_MODULE_"
  result = @[
    (p & "name", "const char* " & p & "name(void);"),
    (
      p & "init",
      "logos_result_t " & p & "init(\n" & "    const logos_module_init_input_t* input,\n" &
        "    logos_module_context_t** out_context\n);",
    ),
    (p & "destroy", "void " & p & "destroy(logos_module_context_t* module);"),
  ]
  if provider:
    result.add(
      [
        (p & "call_surface", "const uint8_t* " & p & "call_surface(size_t* out_len);"),
        (p & "free", "void " & p & "free(logos_module_context_t* module, void* ptr);"),
        (
          p & "dispatch",
          "logos_result_t " & p & "dispatch(\n" & "    logos_module_context_t* module,\n" &
            "    const char* method,\n" & "    const uint8_t* params_cbor,\n" &
            "    size_t params_len,\n" & "    uint8_t** out_response_cbor,\n" &
            "    size_t* out_response_len\n);",
        ),
      ]
    )

# logos_types.h -------------------------------------------------------------------

proc newGen(views: seq[DocView], roots: seq[Digest]): Gen =
  var g = Gen(docs: views)
  for i, v in views:
    for d in v.model.declarations:
      if d.kind != dkMethod:
        g.byImport[importKey(roots[i], declarationRoot(v.model, d))] = (i, d.name)
  g

proc commonGen(): Gen =
  ## The pinned common schema's named types, which `logos_types.h` declares.
  let ctx = pinnedContext()
  var g = newGen(
    @[DocView(model: ctx.commonModel, common: true, external: false, cns: "logos")],
    @[ctx.commonRoot],
  )
  for d in ctx.commonModel.declarations:
    # [SPEC INTERFACE §2.1] logos.error_code reuses the fixed status enum.
    if d.kind == dkType and d.name != "logos.error_code":
      g.declaration(0, d)
  g.resolveGraph()
  g

proc commonDeclarations*(): seq[string] =
  ## [SPEC INTERFACE §5.2] The canonical declarations of every named type in the
  ## pinned common schema except `logos.error_code`, with their constraint and
  ## inline support declarations. [IMPL-DECISION G158, pending] Their names use
  ## the local name as the stem.
  let g = commonGen()
  doAssert g.errors.len == 0, "the pinned common schema maps to C"
  var res: seq[string]
  for name in toSeq(g.constraints.keys).sorted:
    res.add(g.constraints.at(name))
  let gs = g.groups(@[]).valueOr:
    raiseAssert "the pinned common schema has a dependency order"
  res & gs[0].flat

func fixedBlock(): (string, string) =
  ## [SPEC INTERFACE §5.2] The fixed C block without its per-module
  ## `logos_<module-C>_MODULE_…` templates (each module header declares its
  ## own), split before the closing C++ linkage wrapper.
  var lines: seq[string]
  for l in LogosTypesFixed.splitLines:
    if "<module-C>" in l or
        l.strip in [
          "/* -- Memory management -- */",
          "/* Optional provider completion capability. */",
        ]:
      continue
    lines.add(l)
  while lines.len > 0 and lines[^1].strip.len == 0:
    discard lines.pop()
  var close = lines.high
  while close > 0 and lines[close].strip != "#ifdef __cplusplus":
    dec close
  var head = lines[0 ..< close]
  while head.len > 0 and head[^1].strip.len == 0:
    discard head.pop()
  (head.join("\n"), lines[close .. ^1].join("\n"))

proc logosTypesHeader*(): string =
  ## [SPEC INTERFACE §5.2] `logos_types.h`: the fixed block, the §2.3 empty
  ## types and the common schema's types, inside the C++ linkage wrapper.
  let (head, close) = fixedBlock()
  "/* logos_types.h: generated by lcn-gen from INTERFACE §2.3, §5.1 and §5.2.\n" &
    " * " & ProvisionalStamp & ". Do not edit. */\n" & "#ifndef LOGOS_TYPES_H\n" &
    "#define LOGOS_TYPES_H\n\n" & head &
    "\n\n/* -- Empty values (INTERFACE §2.3) -- */\n\n" & LogosTypesEmpty.strip & "\n\n" &
    "/* -- Common schema types (INTERFACE §5.1; names: G158 interim) -- */\n\n" &
    commonDeclarations().join("\n\n") & "\n\n" & close &
    "\n\n#endif /* LOGOS_TYPES_H */\n"

# Contract headers ----------------------------------------------------------------

func roleConstant(m: SchemaModel, module: Opt[string]): (string, string) =
  ## [SPEC INTERFACE §2.1] The document-role namespace constant.
  let name =
    case m.role
    of srModule:
      "LOGOS_PRIMARY_NAMESPACE_" & projectModule(module.get(m.moduleName.get("")))
    of srInterface:
      "LOGOS_INTERFACE_NAMESPACE_" & projectNamespace(m.namespace)
    else:
      "LOGOS_SUPPORTING_NAMESPACE_" & projectNamespace(m.namespace)
  (name, cString(m.namespace))

func sensitiveConstants(m: SchemaModel): seq[(string, string)] =
  ## [SPEC INTERFACE §2.1] `LOGOS_SENSITIVE_<namespace>_INDEX<i>`, in the ASCII
  ## order of `_sensitive`; none for an unmarked contract.
  var names: seq[string]
  for d in m.declarations:
    if d.kind == dkMethod:
      if d.sensitiveRequest:
        names.add(d.request)
      if d.sensitiveResponse:
        names.add(d.response)
  names.sort()
  var cs: seq[(string, string)]
  for i, n in names:
    cs.add(
      ("LOGOS_SENSITIVE_" & projectNamespace(m.namespace) & "_INDEX" & $i, cString(n))
    )
  cs

func moduleConstants(s: CSchemaSet): seq[(string, string)] =
  ## [SPEC INTERFACE §2.1] The module binding's metadata: the primary
  ## document's role constant and one `LOGOS_IMPLEMENTS_<module-C>_INDEX<i>` per
  ## implemented interface, in ascending raw root order. Provider-specific: no
  ## shared document guard suppresses them (§3.2).
  if s.module.isNone:
    return @[]
  var cs: seq[(string, string)]
  if s.primary.isSome:
    cs.add(roleConstant(s.primary.get.model, s.module))
  for i, c in s.interfaces:
    cs.add(
      (
        "LOGOS_IMPLEMENTS_" & projectModule(s.module.get) & "_INDEX" & $i,
        cString(c.model.namespace),
      )
    )
  cs

func documentGuard(cns: string): string =
  "LOGOS_DOCUMENT_" & cns & "_DEFINED"

func rootMacros(cns: string, root: Digest): seq[(string, string)] =
  ## [SPEC INTERFACE §3.2] Root bytes 8*i .. 8*i+7, most significant first.
  var ms: seq[(string, string)]
  for i in 0 .. 3:
    var h = "0x"
    for b in root[8 * i ..< 8 * i + 8]:
      h.add(toHex(int(b), 2).toLowerAscii)
    ms.add(("LOGOS_DOCUMENT_" & cns & "_ROOT_" & $i, h & "ULL"))
  ms

type Generated = object
  docs: seq[CDocument]
  cns: seq[string]
  constraints: seq[string]
  groups: seq[DocGroup]
  module: seq[(string, string)]
  symbols: seq[string]
    ## a module binding's provider functions and module symbols (§2.4, §2.6)

proc generate(s: CSchemaSet): Result[Generated, string] =
  var views: seq[DocView]
  var roots: seq[Digest]
  var projections: Table[string, string]
  let docs = s.documents
  for c in docs:
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
  views.add(DocView(model: ctx.commonModel, common: true, external: true, cns: "logos"))
  roots.add(ctx.commonRoot)
  var g = newGen(views, roots)
  for i in 0 ..< docs.len:
    for d in views[i].model.declarations:
      g.declaration(i, d)
  if g.errors.len > 0:
    return err(g.errors[0] & " (INTERFACE §2.1, §2.3)")
  g.resolveGraph()
  var consts: seq[seq[(string, string)]]
  for i, c in docs:
    var cs: seq[(string, string)]
    if c.model.role != srModule:
      cs.add(roleConstant(c.model, s.module))
    cs.add(sensitiveConstants(c.model))
    consts.add(cs)
  let module = moduleConstants(s)
  # [SPEC INTERFACE §2.4] Each document's method typedefs; a module binding's
  # provider functions for its primary and implemented interfaces, then its
  # module symbols (§2.6). A provider contract declares a method or an event.
  var fns = newSeq[seq[(string, string)]](docs.len)
  var symbols: seq[(string, string)]
  var provider = false
  let moduleC = projectModule(s.module.get(""))
  let exposed = (if s.primary.isSome: 1 else: 0) + s.interfaces.len
  for i in 0 ..< docs.len:
    for d in views[i].model.declarations:
      if d.kind == dkMethod:
        fns[i].add((g.fnTypedefName(i, d), g.fnTypedef(i, d)))
        if s.module.isSome and i < exposed:
          symbols.add((g.callName(i, d, moduleC), g.callDeclaration(i, d, moduleC)))
      if d.kind in {dkMethod, dkEvent} and i < exposed:
        provider = true
  if s.module.isSome:
    symbols.add(moduleSymbols(moduleC, provider))
  # [SPEC INTERFACE §2.1] No two schema nodes derive one C identifier.
  var ids: seq[(string, string)]
  for k in toSeq(g.defs.keys).sorted:
    for id in g.defs.at(k).identifiers:
      ids.add((id, k))
  for i, cs in consts:
    for (name, _) in cs:
      ids.add((name, "a schema-metadata constant"))
    ids.add((documentGuard(views[i].cns), "a document guard"))
    for (name, _) in rootMacros(views[i].cns, roots[i]):
      ids.add((name, "a document root macro"))
  for (name, _) in module:
    ids.add((name, "a module-binding constant"))
  for f in fns:
    for (name, _) in f:
      ids.add((name, "a method typedef"))
  for (name, _) in symbols:
    ids.add((name, "a module symbol"))
  for name in g.macros.keys:
    ids.add((name, "a literal macro"))
  var seen: Table[string, string]
  for (id, origin) in ids:
    if id in seen:
      return err(
        "C identifier collision: " & id & " derives from " & origin & " and " &
          seen.at(id) & " (INTERFACE §2.1)"
      )
    seen[id] = origin
  var res = Generated(docs: docs, module: module, symbols: symbols.mapIt(it[1]))
  res.groups = ?g.groups(consts)
  res.groups.setLen(docs.len)
  for i in 0 ..< docs.len:
    res.groups[i].fns = fns[i].mapIt(it[1])
  for v in views[0 ..< docs.len]:
    res.cns.add(v.cns)
  # [SPEC INTERFACE §5.2] logos_types.h already declares the common schema's
  # constraint typedefs; a contract header does not redeclare them.
  let common = commonGen()
  for name in toSeq(g.constraints.keys).sorted:
    if name notin common.constraints:
      res.constraints.add(g.constraints.at(name))
  ok(res)

proc cDeclarations*(s: CSchemaSet): Result[seq[string], string] =
  ## [SPEC INTERFACE §2, §2.1-§2.3, §2.5] The canonical C type declarations and
  ## constants of an accepted schema set or module binding, without the header
  ## frame: constraint typedefs, then each document's role and sensitivity
  ## constants, literal macros, forward typedefs and definitions, then the
  ## module-binding constants. An error says why the set has none: a
  ## namespace-projection collision, two identical C identifiers, or a mapping
  ## limit.
  let gen = ?generate(s)
  var res = gen.constraints
  for gr in gen.groups:
    res.add(gr.flat)
  for (name, value) in gen.module:
    res.add("#define " & name & " " & value)
  ok(res & gen.symbols)

func headerName*(s: CSchemaSet): string =
  ## The bound runtime module name, or the subject document's C namespace
  ## component.
  if s.module.isSome:
    s.module.get
  elif s.primary.isSome:
    projectNamespace(s.primary.get.model.namespace)
  else:
    ""

func revisionCheck*(): string =
  ## [SPEC INTERFACE §2] The mapping-generation check of revision 3u.
  "#if !defined(LOGOS_C_MAPPING_REVISION) || LOGOS_C_MAPPING_REVISION != " &
    $CMappingRevision & "u\n#error \"Incompatible Logos C mapping\"\n#endif"

proc contractHeader*(s: CSchemaSet): Result[string, string] =
  ## [SPEC INTERFACE §2, §3.2] The types header of one accepted set or module
  ## binding. It includes `logos_types.h`, then checks the mapping revision and
  ## the commitment context; each non-common document's group is guarded by
  ## `LOGOS_DOCUMENT_<namespace>_DEFINED` and its four root macros, checked
  ## before a repeated group is suppressed. Nothing else is guarded, so every
  ## check runs on every inclusion; the module-binding constants follow the
  ## groups, outside them.
  let gen = ?generate(s)
  let name = s.headerName
  var h =
    "/* " & name & "_types.h: generated by lcn-gen. " & ProvisionalStamp & ".\n" &
    " * INTERFACE §2.1-§2.6, §3.2: C types, method typedefs and, for a module\n" &
    " * binding, its provider functions and module symbols. Do not edit. */\n\n" &
    "#include \"logos_types.h\"\n" & revisionCheck() & "\n"
  for m in contextMarkers():
    h.add(
      "#if !defined(" & m & ") || " & m & " != 1\n" &
        "#error \"Incompatible Logos commitment context\"\n#endif\n"
    )
  h.add("\n#ifdef __cplusplus\nextern \"C\" {\n#endif\n")
  if gen.constraints.len > 0:
    h.add("\n" & gen.constraints.join("\n") & "\n")
  # Supporting groups first, then interfaces, then the primary document: each
  # group uses only the ones before it.
  var order = toSeq(0 ..< gen.docs.len)
  order.reverse()
  for i in order:
    let c = gen.docs[i]
    let cns = gen.cns[i]
    let guard = documentGuard(cns)
    let ms = rootMacros(cns, c.root)
    h.add("\n/* " & $c.model.role & " document " & c.model.namespace & " */\n")
    h.add("#ifdef " & guard & "\n#if ")
    h.add(
      ms.mapIt("!defined(" & it[0] & ") || " & it[0] & " != " & it[1]).join(
        " || \\\n    "
      )
    )
    h.add(
      "\n#error \"Conflicting Logos schema document " & c.model.namespace &
        "\"\n#endif\n#else\n"
    )
    h.add("#define " & guard & " 1\n")
    for (n, v) in ms:
      h.add("#define " & n & " " & v & "\n")
    let items = gen.groups[i].flat
    if items.len > 0:
      h.add("\n" & items.join("\n\n") & "\n")
    h.add("#endif /* " & guard & " */\n")
  if gen.module.len > 0 or gen.symbols.len > 0:
    h.add("\n/* module binding " & name & " */\n")
    for (n, v) in gen.module:
      h.add("#define " & n & " " & v & "\n")
    for d in gen.symbols:
      h.add("\n" & d & "\n")
  h.add("\n#ifdef __cplusplus\n}\n#endif\n")
  ok(h)
