## lcn-gen's typed provider functions for the module kit [IMPL] (INTERFACE
## §2.3, §2.4, §2.7).
##
## From `cmap`'s C layout of a module binding, the kit gets:
##
## - Mirrors: one Nim type per §2.3 declaration with the C layout, named by its
##   C typedef. Struct members are positional (`m0`, `m1`, …, the C name in a
##   comment), so no C identifier has to be a Nim one. A choice is `kind` and,
##   when an arm has payload storage, a `{.union.}` named `<typedef>_value`.
##   Typedefs and constraint typedefs are Nim aliases. The common schema's
##   mirrors are `codegen/common_mirrors.nim` (`commonMirrorModule`).
## - Converters for each aggregate, in both directions:
##   - `cOut_<typedef>` writes a checked CBOR value into a mirror, with storage
##     from the call's arena (`callrt`).
##   - `cIn_<typedef>` reads a mirror into a CBOR value.
##
##   A C discriminant maps to its canonical arm through the layout, never by
##   equality (§2.3).
## - For each provider function:
##   - a request builder, from the typed inputs to deterministic-CBOR params;
##   - a response writer, from the checked response to the outputs;
##   - the generic body that the export template instantiates.
## - A layout table: each mirror's size, alignment and member offsets, keyed by
##   C name. The tests compare it with the C compiler's view of the generated
##   header.
##
## Every name the generated Nim declares starts with a lowercase letter or with
## `kit`. Nim types from `nimgen` start with an uppercase one, so the two never
## meet. Two C names that Nim would treat as one identifier stop generation.

{.push raises: [].}

import std/[algorithm, sequtils, sets, strutils, tables]
import results
import ../base/hex
import ../hash/hashinput
import ../pins
import ../commitment
import ../iface/[accept, cmap, names]
import ./nimrt

type
  MDoc = object
    model: SchemaModel
    common: bool ## the pinned common document
    external: bool ## its converters are in `common_mirrors`

  Owner = object
    doc: int
    name: string ## the owning declaration's qualified name

  Step =
    tuple
      key: string ## the `nimrt.choiceKey` component
      c: string ## the C path step (§2.1)

  MGen = object
    docs: seq[MDoc]
    byImport: Table[string, (int, string)]
    layout: CLayout ## the declarations this module mirrors
    common: CLayout ## the common schema's, for external references
    schema: string ## the expression naming this module's `GeneratedSchema`
    forwards: seq[string]
    procs: seq[string]
    visited: HashSet[string] ## defs whose converters are emitted
    errors: seq[string]
    tmp: int
    emitLiterals: bool
      ## [SPEC INTERFACE §2.3 l.1096] the input converters encode a request (call
      ## helpers): a literal position emits the required literal instead of
      ## reading its C member, which a provider-side conversion reads so that
      ## validation rejects another value

  KitMethod* = object ## What the kit's generic body calls for one provider function.
    request*: string ## the qualified request half (joins `CProviderCall`)
    response*: string
    bare*: string ## the bare method name `checkedRequest` takes
    handler*: string ## the author's handler, quoted
    requestType*: string ## the Nim request type

  KitMirrors* = object
    types*: string ## the mirror `type` section
    procs*: string ## converters, builders and generic bodies
    exports*: seq[string] ## the exported procs, for the export template
    layout*: string ## the layout table proc

# Names -----------------------------------------------------------------------------

func nimNorm(id: string): string =
  if id.len == 0:
    ""
  else:
    id[0] & id[1 ..^ 1].toLowerAscii.replace("_", "")

func fieldStep(name: string): Step =
  (name, "_" & capitalize(name))

func listStep(): Step =
  ("list_item", "_LI")

func tupleStep(i: int): Step =
  ("tuple_" & $i, "_TU" & $i)

func defKey(o: Owner, path: seq[Step]): string =
  ## `cmap`'s key: the declaration, or `<owner>#<C path>` for an inline type.
  if path.len == 0:
    o.name
  else:
    o.name & "#" & path.mapIt(it.c).join("")

func planKey(o: Owner, path: seq[Step]): string =
  choiceKey(o.name, path.mapIt(it.key))

func nimOf(ctype: string): string =
  ## The Nim spelling of a C type that a member, element or typedef names.
  case ctype
  of "bool": "bool"
  of "uint8_t": "uint8"
  of "uint16_t": "uint16"
  of "uint32_t": "uint32"
  of "uint64_t": "uint64"
  of "int8_t": "int8"
  of "int16_t": "int16"
  of "int32_t": "int32"
  of "int64_t": "int64"
  of "size_t": "csize_t"
  of "const char*": "cstring"
  of "const uint8_t*": "ptr UncheckedArray[uint8]"
  of "logos_error_code_t": "CErrorCode"
  else: ctype

func memberType(m: CMember): string =
  if m.recursive:
    "ptr " & nimOf(m.ctype)
  elif m.role == mrList:
    "ptr UncheckedArray[" & nimOf(m.element) & "]"
  elif m.arrayLen > 0:
    "array[" & $m.arrayLen & ", uint8]"
  else:
    nimOf(m.ctype)

func constraintType(name: string): string =
  if name.startsWith("logos_tstr_size_"): "cstring" else: "ptr UncheckedArray[uint8]"

func unionName(d: CDef): string =
  d.typeName & "_value"

# Schema ------------------------------------------------------------------------------

func resolve(g: MGen, doc: int, n: SchemaNode): (int, Declaration) =
  if n.kind == snLocalRef:
    (doc, g.docs[doc].model.find(n.target).get)
  else:
    let (d, name) = g.byImport.getOrDefault(
      toHex(n.imported.root) & toHex(n.imported.subtree), (0, "")
    )
    (d, g.docs[d].model.find(name).get)

func isErrorCode(g: MGen, doc: int, name: string): bool =
  g.docs[doc].common and name == "logos.error_code"

type Final = object
  doc: int
  decl: Declaration
  errorCode: bool

func final(g: MGen, doc: int, n: SchemaNode): Final =
  ## The declaration a reference names, through aliases; `logos.error_code`
  ## is the fixed enum (§2.1), not its choice.
  var (d, decl) = g.resolve(doc, n)
  while true: # alias chains end: acceptance rejects alias cycles (G153)
    if g.isErrorCode(d, decl.name):
      return Final(doc: d, decl: decl, errorCode: true)
    if decl.body.kind notin {snLocalRef, snImportedRef}:
      return Final(doc: d, decl: decl)
    (d, decl) = g.resolve(d, decl.body)

func isAggregate(n: SchemaNode): bool =
  n.kind in {snMap, snList, snTuple, snChoice} or
    (n.kind == snPrimitive and n.scalar == skBstr)

func exactBstr(n: SchemaNode): Opt[uint64] =
  if n.kind == snPrimitive and n.scalar == skBstr and n.size.isSome and
      n.size.get[0] == n.size.get[1]:
    Opt.some(n.size.get[0])
  else:
    Opt.none(uint64)

func memberCount(n: SchemaNode): int =
  ## [SPEC INTERFACE §2.3] The C members of one map field (`cmap.fieldMembers`).
  case n.kind
  of snPrimitive:
    if n.scalar == skBstr and exactBstr(n).isNone: 2 else: 1
  of snList:
    2
  of snTuple:
    max(n.items.len, 1)
  else:
    1

func armSteps(g: MGen, doc: int, n: SchemaNode): (bool, seq[string]) =
  var labels: seq[Opt[string]]
  for a in n.arms:
    if a.kind in {snLocalRef, snImportedRef}:
      let (d, decl) = g.resolve(doc, a)
      labels.add(armLabelOf(a, referenceLabel(g.docs[d].model.namespace, decl.name)))
    else:
      labels.add(armLabelOf(a))
  choiceSteps(labels)

proc defOf(g: var MGen, doc: int, key: string): CDef =
  let found =
    if g.docs[doc].external:
      key in g.common.defs
    else:
      key in g.layout.defs
  if not found:
    g.errors.add("the C layout has no declaration " & key)
    return CDef(kind: dStruct)
  if g.docs[doc].external:
    g.common.defs.getOrDefault(key, CDef(kind: dStruct))
  else:
    g.layout.defs.getOrDefault(key, CDef(kind: dStruct))

# Code ----------------------------------------------------------------------------

proc line(c: var seq[string], ind: int, s: string) =
  c.add(spaces(ind) & s)

proc fresh(g: var MGen, base: string): string =
  inc g.tmp
  base & $g.tmp

proc literalCbor(d: ScalarData): string =
  case d.kind
  of skBool:
    "cbor(" & $d.boolean & ")"
  of UnsignedKinds:
    "cbor(" & $d.unsigned & "'u64)"
  of SignedKinds:
    if d.signed == low(int64):
      "cbor(low(int64))"
    else:
      "cbor(" & $d.signed & "'i64)"
  of skTstr:
    "cbor(" & escape(d.text) & ")"
  of skBstr:
    "cbor(newSeq[byte]())"

proc aggregate(g: var MGen, o: Owner, path: seq[Step], n: SchemaNode)

# CBOR to C -------------------------------------------------------------------------

proc outScalar(k: ScalarKind, t, v: string): string =
  case k
  of skBool:
    "asBool(" & v & ")"
  of UnsignedKinds:
    t & "(" & v & ".uint)"
  of SignedKinds:
    t & "(asInt64(" & v & "))"
  of skTstr:
    "?a.text(" & v & ".text)"
  of skBstr:
    "" # never a scalar position

proc outAggregate(
    g: var MGen,
    c: var seq[string],
    ind: int,
    typeName: string,
    recursive: bool,
    v, dst: string,
) =
  if recursive:
    let p = g.fresh("p")
    c.line(ind, "let " & p & " = ?a.boxed(" & typeName & ")")
    c.line(ind, "?cOut_" & typeName & "(a, " & v & ", " & p & "[], depth + 1)")
    c.line(ind, dst & " = " & p)
  else:
    c.line(ind, "?cOut_" & typeName & "(a, " & v & ", " & dst & ", depth + 1)")

proc outPos(
    g: var MGen,
    c: var seq[string],
    ind: int,
    o: Owner,
    path: seq[Step],
    n: SchemaNode,
    m: CMember,
    v, dst: string,
) =
  ## Writes the checked value `v` of a one-member position: a scalar, text,
  ## literal, inline aggregate or reference.
  case n.kind
  of snPrimitive:
    if n.scalar != skBstr:
      c.line(ind, dst & " = " & outScalar(n.scalar, nimOf(m.ctype), v))
    elif exactBstr(n) != Opt.some(0'u64): # else the shared empty value
      g.aggregate(o, path, n)
      let d = g.defOf(o.doc, defKey(o, path))
      g.outAggregate(c, ind, d.typeName, m.recursive, v, dst)
  of snLiteral:
    c.line(ind, dst & " = " & outScalar(n.literal.kind, nimOf(m.ctype), v))
  of snMap, snChoice, snList, snTuple:
    if n.kind == snTuple and n.items.len == 0:
      return # the shared empty value
    g.aggregate(o, path, n)
    let d = g.defOf(o.doc, defKey(o, path))
    g.outAggregate(c, ind, d.typeName, m.recursive, v, dst)
  of snLocalRef, snImportedRef:
    let f = g.final(o.doc, n)
    if f.errorCode:
      c.line(ind, dst & " = CErrorCode(" & v & ".uint)")
    elif f.decl.body.isAggregate:
      let d = g.defOf(f.doc, f.decl.name)
      g.outAggregate(c, ind, d.typeName, m.recursive, v, dst)
    elif f.decl.body.kind == snLiteral:
      c.line(ind, dst & " = " & outScalar(f.decl.body.literal.kind, nimOf(m.ctype), v))
    else:
      c.line(ind, dst & " = " & outScalar(f.decl.body.scalar, nimOf(m.ctype), v))

proc outField(
    g: var MGen,
    c: var seq[string],
    ind: int,
    o: Owner,
    path: seq[Step],
    n: SchemaNode,
    ms: seq[CMember],
    dsts: seq[string],
    v: string,
) =
  ## Writes one field's (or one aggregate's) members from the checked value `v`.
  case n.kind
  of snPrimitive:
    if n.scalar == skBstr:
      let exact = exactBstr(n)
      if exact.isNone:
        c.line(ind, "?a.bytes(" & v & ".bytes, " & dsts[0] & ", " & dsts[1] & ")")
      elif exact.get > 0:
        c.line(ind, "?fill(" & v & ".bytes, " & dsts[0] & ")")
      return
  of snList:
    let items = g.fresh("items")
    let arr = g.fresh("arr")
    c.line(ind, "let " & items & " = " & v & ".items")
    c.line(
      ind, "let " & arr & " = ?a.list(" & nimOf(ms[0].element) & ", " & items & ".len)"
    )
    c.line(ind, "for i, it in " & items & ":")
    let e = CMember(ctype: ms[0].element, target: ms[0].listTarget)
    g.outPos(c, ind + 2, o, path & listStep(), n.element, e, "it", arr & "[i]")
    c.line(ind, dsts[0] & " = " & arr)
    c.line(ind, dsts[1] & " = csize_t(" & items & ".len)")
    return
  of snTuple:
    if n.items.len > 0:
      for i, item in n.items:
        g.outPos(
          c, ind, o, path & tupleStep(i), item, ms[i], v & ".items[" & $i & "]", dsts[i]
        )
    return
  else:
    discard
  g.outPos(c, ind, o, path, n, ms[0], v, dsts[0])

proc outMap(
    g: var MGen,
    c: var seq[string],
    ind: int,
    o: Owner,
    path: seq[Step],
    n: SchemaNode,
    members: seq[CMember],
    dst: seq[string],
    v: string,
) =
  ## [SPEC INTERFACE §2.3, §2.4] A map's fields, in canonical order, into its
  ## members: a struct's, or a flattened method half's.
  var mi = 0
  for f in n.fields:
    let fpath = path & fieldStep(f.name)
    var presence = -1
    if f.optional:
      if mi >= members.len or members[mi].role != mrPresence:
        g.errors.add("the C layout of " & defKey(o, path) & " has no has_" & f.name)
        return
      presence = mi
      inc mi
    let k = memberCount(f.node)
    if mi + k > members.len:
      g.errors.add("the C layout of " & defKey(o, path) & " lacks members of " & f.name)
      return
    let ms = members[mi ..< mi + k]
    let dsts = dst[mi ..< mi + k]
    mi += k
    let fv = g.fresh("f")
    if f.optional:
      c.line(ind, "let " & fv & " = " & v & ".lookup(" & escape(f.name) & ")")
      c.line(ind, "if " & fv & ".isSome:")
      c.line(ind + 2, dst[presence] & " = true")
      g.outField(c, ind + 2, o, fpath, f.node, ms, dsts, fv & ".get")
    else:
      c.line(ind, "let " & fv & " = " & v & ".lookup(" & escape(f.name) & ").get")
      g.outField(c, ind, o, fpath, f.node, ms, dsts, fv)
  if mi != members.len and not (n.fields.len == 0 and members.len == 1):
    g.errors.add("the C layout of " & defKey(o, path) & " has extra members")

# C to CBOR -------------------------------------------------------------------------

proc inScalar(k: ScalarKind, src: string): string =
  case k
  of skBool:
    "cbor(" & src & ")"
  of UnsignedKinds:
    "cbor(uint64(" & src & "))"
  of SignedKinds:
    "cbor(int64(" & src & "))"
  of skTstr:
    "?inText(" & src & ")"
  of skBstr:
    ""

proc inAggregate(typeName: string, recursive: bool, src: string): string =
  if recursive:
    "?cIn_" & typeName & "((?present(" & src & "))[], depth + 1)"
  else:
    "?cIn_" & typeName & "(" & src & ", depth + 1)"

proc inPos(
    g: var MGen, o: Owner, path: seq[Step], n: SchemaNode, m: CMember, src: string
): string =
  ## The CBOR value of a one-member position read from `src`.
  case n.kind
  of snPrimitive:
    if n.scalar != skBstr:
      return inScalar(n.scalar, src)
    if exactBstr(n) == Opt.some(0'u64):
      return "cbor(newSeq[byte]())"
    g.aggregate(o, path, n)
    inAggregate(g.defOf(o.doc, defKey(o, path)).typeName, m.recursive, src)
  of snLiteral:
    if g.emitLiterals:
      literalCbor(n.literal)
    else:
      inScalar(n.literal.kind, src)
  of snMap, snChoice, snList, snTuple:
    if n.kind == snTuple and n.items.len == 0:
      return "cborArray()"
    g.aggregate(o, path, n)
    inAggregate(g.defOf(o.doc, defKey(o, path)).typeName, m.recursive, src)
  of snLocalRef, snImportedRef:
    let f = g.final(o.doc, n)
    if f.errorCode:
      "cbor(int64(" & src & "))"
    elif f.decl.body.isAggregate:
      inAggregate(g.defOf(f.doc, f.decl.name).typeName, m.recursive, src)
    elif f.decl.body.kind == snLiteral:
      if g.emitLiterals:
        literalCbor(f.decl.body.literal)
      else:
        inScalar(f.decl.body.literal.kind, src)
    else:
      inScalar(f.decl.body.scalar, src)

proc inField(
    g: var MGen,
    c: var seq[string],
    ind: int,
    o: Owner,
    path: seq[Step],
    n: SchemaNode,
    ms: seq[CMember],
    srcs: seq[string],
): string =
  ## The CBOR value of one field (or one aggregate) read from its members.
  case n.kind
  of snPrimitive:
    if n.scalar == skBstr:
      let exact = exactBstr(n)
      if exact.isNone:
        return "?inBytes(" & srcs[0] & ", " & srcs[1] & ")"
      if exact.get > 0:
        return "cbor(" & srcs[0] & ")"
      return "cbor(newSeq[byte]())"
  of snList:
    let count = g.fresh("n")
    let items = g.fresh("items")
    c.line(ind, "let " & count & " = ?counted(" & srcs[0] & ", " & srcs[1] & ")")
    c.line(ind, "var " & items & " = newSeq[CborValue](" & count & ")")
    c.line(ind, "for i in 0 ..< " & count & ":")
    let e = CMember(ctype: ms[0].element, target: ms[0].listTarget)
    let x = g.inPos(o, path & listStep(), n.element, e, srcs[0] & "[i]")
    c.line(ind + 2, items & "[i] = " & x)
    return "cborArray(" & items & ")"
  of snTuple:
    if n.items.len > 0:
      var xs: seq[string]
      for i, item in n.items:
        xs.add(g.inPos(o, path & tupleStep(i), item, ms[i], srcs[i]))
      return "cborArray(" & xs.join(", ") & ")"
  else:
    discard
  g.inPos(o, path, n, ms[0], srcs[0])

proc inMap(
    g: var MGen,
    c: var seq[string],
    ind: int,
    o: Owner,
    path: seq[Step],
    n: SchemaNode,
    members: seq[CMember],
    src: seq[string],
    entries: string,
) =
  var mi = 0
  for f in n.fields:
    let fpath = path & fieldStep(f.name)
    var presence = -1
    if f.optional:
      presence = mi
      inc mi
    let k = memberCount(f.node)
    if mi + k > members.len:
      return # `outMap` reports the mismatch
    let ms = members[mi ..< mi + k]
    let srcs = src[mi ..< mi + k]
    mi += k
    let key = "cbor(" & escape(f.name) & ")"
    if f.optional:
      c.line(ind, "if " & src[presence] & ":")
      let x = g.inField(c, ind + 2, o, fpath, f.node, ms, srcs)
      c.line(ind + 2, entries & ".add((" & key & ", " & x & "))")
    else:
      let x = g.inField(c, ind, o, fpath, f.node, ms, srcs)
      c.line(ind, entries & ".add((" & key & ", " & x & "))")

# Converters ------------------------------------------------------------------------

proc aggregate(g: var MGen, o: Owner, path: seq[Step], n: SchemaNode) =
  ## Emits `cOut_<T>` and `cIn_<T>` for the aggregate at (`o`, `path`), once.
  let key = defKey(o, path)
  if key in g.visited or g.docs[o.doc].external:
    return
  g.visited.incl(key)
  let d = g.defOf(o.doc, key)
  if d.kind == dAlias:
    g.errors.add("the C layout declares " & key & " as a typedef")
    return
  let t = d.typeName
  let outSig =
    "proc cOut_" & t & "*(a: var CallArena, v: CborValue, dst: var " & t &
    ", depth: int): Result[void, string]"
  let inSig =
    "proc cIn_" & t & "*(src: " & t & ", depth: int): Result[CborValue, string]"
  g.forwards.add(outSig)
  g.forwards.add(inSig)
  var oc = @[outSig & " =", "  ?depthCheck(depth)"]
  var ic = @[inSig & " =", "  ?depthCheck(depth)"]
  let member = toSeq(0 ..< d.members.len).mapIt("dst.m" & $it)
  let source = toSeq(0 ..< d.members.len).mapIt("src.m" & $it)
  case n.kind
  of snMap:
    g.outMap(oc, 2, o, path, n, d.members, member, "v")
    ic.line(2, "var e: seq[CborEntry]")
    g.inMap(ic, 2, o, path, n, d.members, source, "e")
    ic.line(2, "ok(cborMap(e))")
  of snChoice:
    let (symbolic, steps) = g.armSteps(o.doc, n)
    if d.cases.len != n.arms.len or d.caseArms.len != n.arms.len:
      g.errors.add("the C layout of " & key & " has other arms")
      return
    oc.line(2, "case " & g.schema & ".arm(" & escape(planKey(o, path)) & ", v)")
    ic.line(2, "case src.kind")
    var mi = 0
    for ci, (_, value) in d.cases:
      let i = d.caseArms[ci]
      let a = n.arms[i]
      let apath =
        path & (("arm_" & $i), (if symbolic: "_AR_" & steps[i]
          else: "_AR" & steps[i]))
      oc.line(2, "of " & $i & ":")
      oc.line(4, "dst.kind = " & $value & "'u32")
      ic.line(2, "of " & $value & "'u32:")
      if a.kind == snLiteral:
        ic.line(4, "ok(" & literalCbor(a.literal) & ")")
      else:
        if mi >= d.members.len:
          g.errors.add("the C layout of " & key & " lacks an arm member")
          return
        let m = d.members[mi]
        let arm = "value.m" & $mi
        inc mi
        g.outPos(oc, 4, o, apath, a, m, "v", "dst." & arm)
        ic.line(4, "ok(" & g.inPos(o, apath, a, m, "src." & arm) & ")")
    oc.line(2, "else:")
    oc.line(4, "return err(" & escape("no arm of " & key) & ")")
    ic.line(2, "else:")
    ic.line(
      4,
      "err(\"the discriminant \" & $src.kind & " & escape(" names no arm of " & key) &
        ")",
    )
  of snList:
    g.outField(oc, 2, o, path, n, d.members, @["dst.m0", "dst.m1"], "v")
    ic.line(
      2, "ok(" & g.inField(ic, 2, o, path, n, d.members, @["src.m0", "src.m1"]) & ")"
    )
  of snTuple:
    let names = toSeq(0 ..< max(n.items.len, 1)).mapIt("dst.m" & $it)
    let srcs = toSeq(0 ..< max(n.items.len, 1)).mapIt("src.m" & $it)
    g.outField(oc, 2, o, path, n, d.members, names, "v")
    if n.items.len == 0:
      ic.line(2, "ok(cborArray())")
    else:
      ic.line(2, "ok(" & g.inField(ic, 2, o, path, n, d.members, srcs) & ")")
  of snPrimitive: # bstr
    g.outField(oc, 2, o, path, n, d.members, @["dst.m0", "dst.m1"], "v")
    ic.line(
      2, "ok(" & g.inField(ic, 2, o, path, n, d.members, @["src.m0", "src.m1"]) & ")"
    )
  else:
    g.errors.add("no aggregate at " & key)
    return
  oc.line(2, "ok()")
  g.procs.add(oc.join("\n"))
  g.procs.add(ic.join("\n"))

proc declarations(g: var MGen) =
  ## Converters for every aggregate the non-external documents declare, inline
  ## ones included; a map-valued method half's inline aggregates come with its
  ## builders.
  for i, v in g.docs:
    if v.external:
      continue
    for d in v.model.declarations:
      if d.kind == dkMethod or g.isErrorCode(i, d.name):
        continue
      let o = Owner(doc: i, name: d.name)
      if d.kind in {dkRequest, dkResponse} and d.body.kind == snMap:
        continue
      if d.body.isAggregate:
        g.aggregate(o, @[], d.body)

# Mirrors ---------------------------------------------------------------------------

proc mirrorTypes(g: var MGen, reserved: seq[string]): seq[string] =
  ## The type section's entries. `reserved` are mirror names declared
  ## elsewhere (the common ones).
  var names: Table[string, string]
  for name in reserved:
    names[nimNorm(name)] = name
  var ts: seq[string]
  for name in g.layout.constraints:
    ts.add("  " & name & "* = " & constraintType(name))
    names[nimNorm(name)] = name
  for key in toSeq(g.layout.defs.keys).sorted:
    let d = g.layout.defs.getOrDefault(key)
    var ids = @[d.typeName]
    case d.kind
    of dAlias:
      ts.add("  " & d.typeName & "* = " & nimOf(d.aliased))
    of dStruct:
      var t = "  " & d.typeName & "* = object ## `" & d.tag & "`"
      for i, m in d.members:
        t.add("\n    m" & $i & "*: " & memberType(m) & " ## " & m.name)
      ts.add(t)
    of dChoice:
      ids.add(d.kindName)
      ts.add("  " & d.kindName & "* = uint32")
      var t =
        "  " & d.typeName & "* = object ## `" & d.tag & "`\n    kind*: " & d.kindName
      if d.members.len > 0:
        ids.add(d.unionName)
        var u = "  " & d.unionName & "* {.union.} = object"
        for i, m in d.members:
          u.add("\n    m" & $i & "*: " & memberType(m) & " ## " & m.name)
        ts.add(u)
        t.add("\n    value*: " & d.unionName)
      ts.add(t)
    for id in ids:
      let k = nimNorm(id)
      if k in names and names.getOrDefault(k) != id:
        g.errors.add(
          "Nim identifier collision: " & id & " and " & names.getOrDefault(k) &
            " name one Nim type"
        )
      names[k] = id
  ts

proc layoutRows(g: MGen): seq[string] =
  ## [IMPL] Size and alignment of each struct, offset of each member, by C name.
  for key in toSeq(g.layout.defs.keys).sorted:
    let d = g.layout.defs.getOrDefault(key)
    let t = d.typeName
    case d.kind
    of dAlias:
      discard
    of dStruct:
      result.add("(" & escape(t) & ", sizeof(" & t & "))")
      result.add("(" & escape(t & "@align") & ", alignof(" & t & "))")
      for i, m in d.members:
        result.add(
          "(" & escape(t & "." & m.name) & ", offsetOf(" & t & ", m" & $i & "))"
        )
    of dChoice:
      result.add("(" & escape(t) & ", sizeof(" & t & "))")
      result.add("(" & escape(t & "@align") & ", alignof(" & t & "))")
      result.add("(" & escape(t & ".kind") & ", offsetOf(" & t & ", kind))")
      if d.members.len > 0:
        result.add("(" & escape(t & ".value") & ", offsetOf(" & t & ", value))")
        result.add("(" & escape(t & ".value@size") & ", sizeof(" & d.unionName & "))")

func layoutProc(name: string, rows: seq[string]): string =
  "proc " & name &
    "*(): seq[(string, int)] =\n  ## [IMPL] Each mirror's size, alignment and member offsets, by C name (tests).\n" &
  (
    if rows.len == 0:
      "  @[]"
    else:
      "  @[\n" & rows.mapIt("    " & it & ",").join("\n") & "\n  ]"
  )

proc newMGen(docs: seq[MDoc], roots: seq[Digest]): MGen =
  var g = MGen(docs: docs)
  for i, v in docs:
    for d in v.model.declarations:
      if d.kind != dkMethod:
        g.byImport[toHex(roots[i]) & toHex(declarationRoot(v.model, d))] = (i, d.name)
  g

# The common schema ---------------------------------------------------------------

proc commonMirrorModule*(importPrefix = "../"): Result[string, string] =
  ## [IMPL] `codegen/common_mirrors.nim`: the mirrors and converters of the
  ## pinned common schema's types (INTERFACE §5.1, §5.2), which every kit
  ## shares, and the shared empty values (§2.3).
  let ctx = pinnedContext()
  var g = newMGen(@[MDoc(model: ctx.commonModel, common: true)], @[ctx.commonRoot])
  g.layout = commonLayout()
  g.common = g.layout
  g.schema = "commonSchema()"
  g.declarations()
  var types = @[
    "  logos_bstr_size_0_t* = object ## `logos_bstr_size_0`\n    m0*: uint8 ## _empty",
    "  logos_tuple_size_0_t* = object ## `logos_tuple_size_0`\n    m0*: uint8 ## _empty",
  ]
  types.add(g.mirrorTypes(@["logos_bstr_size_0_t", "logos_tuple_size_0_t"]))
  if g.errors.len > 0:
    return err(g.errors[0])
  var rows = @[
    "(\"logos_bstr_size_0_t\", sizeof(logos_bstr_size_0_t))",
    "(\"logos_tuple_size_0_t\", sizeof(logos_tuple_size_0_t))",
  ]
  rows.add(g.layoutRows)
  ok(
    "## common_mirrors.nim: generated by lcn-gen from the pinned common schema\n" &
      "## (INTERFACE §5.1, §5.2). PROVISIONAL (spec " & SpecRevision[0 .. 7] &
      "). Nim objects with the\n" &
      "## C layout of `logos_types.h`'s schema types and their converters (`cmirror`).\n" &
      "## Do not edit.\n\n#!fmt: off\n{.push raises: [], gcsafe.}\n\nimport " &
      importPrefix & "codegen/[callrt, nimrt]\nimport " & importPrefix &
      "base/perthread\n\nexport callrt, nimrt\n\n" &
      "perThread(commonSchema, GeneratedSchema, loadCommonSchema())\n\ntype\n" &
      types.join("\n\n") & "\n\n" & g.forwards.join("\n") & "\n\n" & g.procs.join(
      "\n\n"
    ) & "\n\n" & layoutProc("commonMirrorLayout", rows) & "\n"
  )

# A module binding ----------------------------------------------------------------

proc paramTypes(m: CMember, input: bool): (string, string) =
  ## [SPEC INTERFACE §2.4 rules 8-10] (parameter type, staged output type) of
  ## one flattened member (`cmap.memberParam`).
  case m.role
  of mrArray:
    ("ptr array[" & $m.arrayLen & ", uint8]", "array[" & $m.arrayLen & ", uint8]")
  of mrList:
    let l = "ptr UncheckedArray[" & nimOf(m.element) & "]"
    (if input: (l, "") else: ("ptr " & l, l))
  of mrValue:
    if input and not m.byPointer:
      (nimOf(m.ctype), "")
    else:
      ("ptr " & nimOf(m.ctype), nimOf(m.ctype))
  of mrPresence, mrBytes, mrLen, mrCount:
    (if input: (nimOf(m.ctype), "") else: ("ptr " & nimOf(m.ctype), nimOf(m.ctype)))

type MethodPieces = object
  ## The parts of one method's typed signature that the kit's provider function
  ## and the consumer's call helper share: everything after the state and owner
  ## parameters (`p0`, `p1`), and the builders between them and CBOR.
  params: seq[string] ## `p2: T`, … (inputs, then outputs)
  ins, outs: seq[string] ## parameter names
  staged: seq[(string, string)] ## (local, type) per output
  builders: seq[string]
    ## `<prefix>Request<k>` (typed inputs to params bytes) and, when the
    ## response has outputs, `<prefix>Respond<k>` (checked response to the
    ## staged outputs)

proc findHalf(docs: seq[MDoc], name: string): (int, Declaration) =
  for i, v in docs:
    let d = v.model.find(name)
    if d.isSome:
      return (i, d.get)
  (0, Declaration())

proc methodPieces(
    g: var MGen,
    docs: seq[MDoc],
    request, response, methodName: string,
    k: int,
    prefix: string,
): MethodPieces =
  ## [SPEC INTERFACE §2.4] One method's flattened parameters (`cmap.methodParams`
  ## after its first two) and its builders, named `<prefix>Request<k>` and
  ## `<prefix>Respond<k>`.
  var r = MethodPieces()
  var reqLines, resLines: seq[string]
  var reqParams, resParams: seq[string]
  template next(): string =
    "p" & $(r.params.len + 2)

  # The request.
  let (rqDoc, rq) = findHalf(docs, request)
  let rqOwner = Owner(doc: rqDoc, name: request)
  if rq.body.kind == snChoice:
    g.aggregate(rqOwner, @[], rq.body)
    let t = g.defOf(rqDoc, request).typeName
    let p = next()
    r.params.add(p & ": ptr " & t)
    reqParams.add(p & ": ptr " & t)
    r.ins.add(p)
    reqLines.line(2, "ok(encodeCbor(?cIn_" & t & "((?present(" & p & "))[], depth)))")
  else:
    let members = g.layout.halves.getOrDefault(request)
    var srcs: seq[string]
    for m in members:
      let p = next()
      let (pt, _) = paramTypes(m, true)
      r.params.add(p & ": " & pt)
      reqParams.add(p & ": " & pt)
      r.ins.add(p)
      srcs.add(
        if m.role == mrArray or (m.role == mrValue and m.byPointer):
          "(?present(" & p & "))[]"
        else:
          p
      )
    reqLines.line(2, "var e: seq[CborEntry]")
    g.inMap(reqLines, 2, rqOwner, @[], rq.body, members, srcs, "e")
    reqLines.line(2, "ok(encodeCbor(cborMap(e)))")
  # The response.
  let (rsDoc, rs) = findHalf(docs, response)
  let rsOwner = Owner(doc: rsDoc, name: response)
  if rs.body.kind == snChoice:
    g.aggregate(rsOwner, @[], rs.body)
    let t = g.defOf(rsDoc, response).typeName
    let p = next()
    let o = "o" & p[1 ..^ 1]
    r.params.add(p & ": ptr " & t)
    r.outs.add(p)
    r.staged.add((o, t))
    resParams.add(o & ": var " & t)
    resLines.line(2, "?cOut_" & t & "(a, v, " & o & ", depth)")
  else:
    let members = g.layout.halves.getOrDefault(response)
    var targets: seq[string]
    for m in members:
      let p = next()
      let o = "o" & p[1 ..^ 1]
      let (pt, st) = paramTypes(m, false)
      r.params.add(p & ": " & pt)
      r.outs.add(p)
      r.staged.add((o, st))
      resParams.add(o & ": var " & st)
      targets.add(o)
    g.outMap(resLines, 2, rsOwner, @[], rs.body, members, targets, "v")
  resLines.line(2, "ok()")
  # The builders.
  let reqSig = "proc " & prefix & "Request" & $k & "("
  if rq.body.kind != snChoice and g.layout.halves.getOrDefault(request).len == 0:
    r.builders.add(
      reqSig & "): Result[seq[byte], string] =\n  ## `" & methodName &
        "`'s request params: the empty map.\n  ok(encodeCbor(cborMap()))"
    )
  else:
    r.builders.add(
      reqSig & reqParams.join(", ") & "): Result[seq[byte], string] =\n" & "  ## `" &
        methodName & "`'s request params from its typed inputs.\n" &
        "  let depth {.used.} = 1\n" & reqLines.join("\n")
    )
  if r.staged.len > 0:
    r.builders.add(
      "proc " & prefix & "Respond" & $k & "(a: var CallArena, v: CborValue, " &
        resParams.join(", ") & "): Result[void, string] =\n  ## `" & methodName &
        "`'s outputs from its checked response.\n  let depth {.used.} = 1\n" &
        resLines.join("\n")
    )
  r

proc setGen(
    s: ContractSet, schema: string, emitLiterals = false
): Result[(MGen, seq[MDoc]), string] =
  ## A generator over the set's documents and the pinned common one, with every
  ## declared aggregate's converters (`MGen.emitLiterals`).
  let layout = ?cLayout(s.cSchemaSet)
  var docs: seq[MDoc]
  var roots: seq[Digest]
  for c in s.documents:
    docs.add(MDoc(model: c.model))
    roots.add(c.root)
  let ctx = pinnedContext()
  docs.add(MDoc(model: ctx.commonModel, common: true, external: true))
  roots.add(ctx.commonRoot)
  var g = newMGen(docs, roots)
  g.layout = layout
  g.common = commonLayout()
  g.schema = schema
  g.emitLiterals = emitLiterals
  g.declarations()
  ok((g, docs))

proc finish(
    g: var MGen, extra: seq[string], layoutName: string
): Result[(string, string, string), string] =
  ## (types, procs, layout proc): the mirror type section, the converters then
  ## `extra`, and the layout table, once every aggregate has its converters.
  for key, d in g.layout.defs:
    if d.kind != dAlias and key notin g.visited:
      g.errors.add("no converters for " & key)
  var reserved = @["logos_bstr_size_0_t", "logos_tuple_size_0_t"]
  reserved.add(g.common.constraints)
  for _, d in g.common.defs:
    reserved.add(d.typeName)
    if d.kind == dChoice:
      reserved.add(d.kindName)
      reserved.add(d.unionName)
  let types = g.mirrorTypes(reserved)
  if g.errors.len > 0:
    return err(g.errors[0])
  ok(
    (
      (if types.len > 0: "type\n" & types.join("\n\n") else: ""),
      (
        g.forwards.join("\n") & "\n\n" & g.procs.join("\n\n") & "\n\n" &
        extra.join("\n\n")
      ).strip,
      layoutProc(layoutName, g.layoutRows),
    )
  )

proc kitMirrors*(
    s: ContractSet, prefix: string, methods: seq[KitMethod]
): Result[KitMirrors, string] =
  ## [SPEC INTERFACE §2.4] The typed provider functions of the module binding
  ## `s`, for `kitgen`; `prefix` starts the exported procs' Nim names.
  var (g, docs) = ?setGen(s, "kitSchema()")
  var byRequest: Table[string, KitMethod]
  for m in methods:
    byRequest[m.request] = m
  var res = KitMirrors()
  var callProcs: seq[string]
  for k, call in g.layout.calls:
    if call.request notin byRequest:
      return err("no handler for " & call.methodName)
    let km = byRequest.getOrDefault(call.request)
    let mp =
      g.methodPieces(docs, call.request, call.response, call.methodName, k, "kit")
    callProcs.add(mp.builders)
    let params =
      @["p0: ptr LogosModuleContext", "p1: ptr LogosResponseOwner"] & mp.params
    let nonNull = @["p0", "p1"] & mp.outs
    # The generic body.
    var body =
      "proc kitCall" & $k & "[T](" & params.join(", ") & "): LogosResult =\n" & "  ## `" &
      call.symbol & "` (INTERFACE §2.4): `" & call.methodName & "`.\n" & "  mixin " &
      km.handler & "\n" & "  if " & nonNull.mapIt(it & " == nil").join(" or ") & ":\n" &
      "    return failureResult(moduleError(\"a null module, response owner or output\"))\n" &
      "  let params = kitRequest" & $k & "(" & mp.ins.join(", ") & ").valueOr:\n" &
      "    return failureResult(failure(ecInvalidParams, error))\n" &
      "  let request = kitValidator().checkedRequest(" & escape(km.bare) &
      ", params).valueOr:\n" & "    return failureResult(error)\n" &
      "  let instance {.cursor.} = cast[T](instanceOf(p0))\n" & "  let response = " &
      km.handler & "(instance, fromChecked(" & km.requestType & ", request)).valueOr:\n" &
      "    return failureResult(error)\n" & "  let v = toCbor(response)\n" &
      "  kitSchema().check(" & escape(call.response) & ", v).isOkOr:\n" &
      "    return failureResult(moduleError(\"the response does not match its schema: \" & error))\n"
    if mp.staged.len > 0:
      body.add("  var arena: CallArena\n")
      for (local, t) in mp.staged:
        body.add("  var " & local & ": " & t & "\n")
      body.add(
        "  kitRespond" & $k & "(arena, v, " & mp.staged.mapIt(it[0]).join(", ") &
          ").isOkOr:\n" & "    arena.release()\n" &
          "    return failureResult(moduleError(\"the response has no canonical C value: \" & error))\n"
      )
      for i, p in mp.outs:
        body.add("  " & p & "[] = " & mp.staged[i][0] & "\n")
      body.add("  p1[] = arena.owner\n")
    else:
      body.add("  p1[] = LogosResponseOwner()\n")
    body.add("  okResult()")
    callProcs.add(body)
    let names = toSeq(0 ..< params.len).mapIt("p" & $it)
    res.exports.add(
      "  proc " & prefix & "KitCall" & $k & "(" & params.join(", ") &
        "): LogosResult {.exportc: \"" & call.symbol &
        "\", dynlib, cdecl, gcsafe, raises: [].} =\n" & "    kitEnter()\n" &
        "    kitCall" & $k & "[T](" & names.join(", ") & ")"
    )
  (res.types, res.procs, res.layout) = ?g.finish(callProcs, prefix & "Layout")
  ok(res)

proc callMirrors*(
    s: ContractSet, prefix: string, names: Table[string, string]
): Result[KitMirrors, string] =
  ## [SPEC INTERFACE §2.7.2, App A.5] The typed call helpers of every method the
  ## set `s` exposes, for `callsgen`: `invoke` over the Nim types (`names`, the
  ## `nimgen` type of each declaration) and, for C callers, the bodies of
  ## `lcn_invoke_<namespace>_<Method>` and `lcn_clear_<namespace>_<Method>`,
  ## which the export template defines; `prefix` starts their Nim names.
  var (g, docs) = ?setGen(s, "callsSchema()", emitLiterals = true)
  var res = KitMirrors()
  var callProcs: seq[string]
  for k, m in g.layout.methods:
    let mp = g.methodPieces(docs, m.request, m.response, m.methodName, k, "call")
    callProcs.add(mp.builders)
    let request = names.getOrDefault(m.request)
    let response = names.getOrDefault(m.response)
    if request.len == 0 or response.len == 0:
      return err("no Nim type for " & m.methodName)
    let call =
      "routeCall(p0, " & escape(m.bare) & ", params, callsSchema(), " &
      escape(m.response) & ")"
    # Nim callers.
    callProcs.add(
      "proc invoke*(route: ptr LogosRouteHandle, request: " & request & "): Result[" &
        response & ", InvocationFailure] =\n" & "  ## `" & m.methodName &
        "` through `route` (INTERFACE §5.2).\n" & "  let p0 = route\n" &
        "  let params = encodeCbor(toCbor(request))\n" & "  let v = ?" & call & "\n" &
        "  ok(fromChecked(" & response & ", v))"
    )
    # C callers.
    let params = @["p0: ptr LogosRouteHandle", "p1: ptr LogosResponseOwner"] & mp.params
    let nonNull = @["p0", "p1"] & mp.outs
    var body =
      "proc callInvoke" & $k & "(" & params.join(", ") & "): LogosResult =\n" &
      "  ## `lcn_invoke_" & m.component & "` (INTERFACE §2.7.2, App A.5): `" &
      m.methodName & "`.\n" & "  if " & nonNull.mapIt(it & " == nil").join(" or ") &
      ":\n" &
      "    return failureResult(moduleError(\"a null route, response owner or output\"))\n" &
      "  let params = callRequest" & $k & "(" & mp.ins.join(", ") & ").valueOr:\n" &
      "    return failureResult(failure(ecInvalidParams, error))\n" & "  let v = " & call &
      ".valueOr:\n" & "    return failureResult(error)\n"
    if mp.staged.len > 0:
      body.add("  var arena: CallArena\n")
      for (local, t) in mp.staged:
        body.add("  var " & local & ": " & t & "\n")
      body.add(
        "  callRespond" & $k & "(arena, v, " & mp.staged.mapIt(it[0]).join(", ") &
          ").isOkOr:\n" & "    arena.release()\n" &
          "    return failureResult(moduleError(\"the response has no canonical C value: \" & error))\n"
      )
      for i, p in mp.outs:
        body.add("  " & p & "[] = " & mp.staged[i][0] & "\n")
      body.add("  p1[] = arena.owner\n")
    else:
      body.add("  discard v\n  p1[] = LogosResponseOwner()\n")
    body.add("  okResult()")
    callProcs.add(body)
    let outParams = mp.params[mp.params.len - mp.outs.len .. ^1]
    let clearParams = @["p1: ptr LogosResponseOwner"] & outParams
    var clear =
      "proc callClear" & $k & "(" & clearParams.join(", ") & ") =\n" & "  ## `lcn_clear_" &
      m.component & "` (INTERFACE §2.7.2): clears the owner, then\n" &
      "  ## resets every output object without reading it.\n" & "  clearOwner(p1)"
    for p in mp.outs:
      clear.add("\n  resetOutput(" & p & ")")
    callProcs.add(clear)
    let all = toSeq(0 ..< params.len).mapIt("p" & $it)
    let clearNames = @["p1"] & mp.outs
    res.exports.add(
      "  proc " & prefix & "Invoke" & $k & "(" & params.join(", ") &
        "): LogosResult {.exportc: \"lcn_invoke_" & m.component &
        "\", dynlib, cdecl, gcsafe, raises: [].} =\n" & "    kitEnter()\n" &
        "    callInvoke" & $k & "(" & all.join(", ") & ")\n\n" & "  proc " & prefix &
        "Clear" & $k & "(" & clearParams.join(", ") & ") {.exportc: \"lcn_clear_" &
        m.component & "\", dynlib, cdecl, gcsafe, raises: [].} =\n" & "    callClear" &
        $k & "(" & clearNames.join(", ") & ")"
    )
  (res.types, res.procs, res.layout) = ?g.finish(callProcs, prefix & "Layout")
  ok(res)
