## lcn-gen's Nim output [D29]: Nim types and Logos deterministic-CBOR codecs for
## an accepted schema set.
##
## The Nim mapping is ours [IMPL]; INTERFACE fixes only the C one. It follows the
## C mapping's (revision 3) stems, paths and arm labels where Nim allows:
##
## - A named map or choice (types, method halves, events) is an object or a case
##   object named by the PascalCase of its C stem (`storage.space_info` →
##   `StorageSpaceInfo`, `sensor.control.settings` → `SensorNSControlSettings`;
##   common types use their local name, as `logos_types.h` does under G158). An
##   inline map or choice adds its C path and `Map` / `Choice`
##   (`StorageEntryARFileMap`, `StorageRecordSubInnerChoice`).
## - A choice's kind enum lists the C arm labels in C discriminant order
##   (`ValueKind.Bool`, `.Tstr`, `.Uint64`), or `Case<i>` in indexed form; an
##   arm's payload field is `arm_<label>` / `arm_<i>`.
## - Any other named declaration is a type alias with `enc<Name>` / `dec<Name>`.
## - Scalars map to `bool`, `uint8`..`uint64`, `int8`..`int64`, `string` and
##   `seq[byte]`; lists to `seq`; tuples to anonymous tuples (`[]` to
##   `EmptyTuple`); optional fields to `Opt`; `logos.error_code` to `ErrorCode`.
## - A literal map field defaults to its literal; a literal choice arm has no
##   payload. Encoders always emit the literal, whatever the field holds
##   [SPEC INTERFACE §2.3].
## - A reference on a by-value cycle (the C mapping's recursive edges) is a
##   `ref`.
## - Nim identifiers ignore case after their first letter and underscores, so
##   C names that differ only there collide in Nim: such a set has no Nim
##   output, and generation fails with the colliding names.
##
## Decoders accept only checked values: deterministic CBOR, then the schema
## (`nimrt.check`), then conversion.

{.push raises: [].}

import std/[algorithm, sequtils, sets, strutils, tables]
import ../base/hex
import ../hash/hashinput
import ../pins
import ../commitment
import ../iface/accept
import ./nimrt

type
  NimOptions* = object
    importPrefix*: string
      ## How the output imports this library, e.g. `logos_core/` (the default) or
      ## a relative path ending in `logos_core/`.
    schemaAccessor*: string
      ## When set, the module also exports a template of this name that returns
      ## its per-thread `GeneratedSchema`, for code that validates payloads of
      ## the set itself (the engine's Runtime Control binding) [IMPL].

  Doc = object
    model: SchemaModel
    common: bool ## the pinned common document: names drop `logos`
    external: bool ## generated in `iface/common_types`, imported here
    cns: string

  Owner = object
    doc: int
    name: string ## the owning declaration's qualified name
    stem: string ## its C stem

  Step =
    tuple
      key: string ## the `nimrt.choiceKey` component
      c: string ## the C path step (§2.1): `_Field`, `_LI`, `_TU<i>`, `_AR…`

  NGen = object
    docs: seq[Doc]
    byImport: Table[string, (int, string)]
    boxed: HashSet[string] ## occurrence keys of recursive references
    types: seq[string]
    consts: seq[string]
    forwards: seq[string]
    procs: seq[string]
    api: seq[string]
    idents: Table[string, string] ## Nim-normalized identifier -> origin
    errors: seq[string]

const
  NimKeywords = [
    "addr", "and", "as", "asm", "bind", "block", "break", "case", "cast", "concept",
    "const", "continue", "converter", "defer", "discard", "distinct", "div", "do",
    "elif", "else", "end", "enum", "except", "export", "finally", "for", "from", "func",
    "if", "import", "in", "include", "interface", "is", "isnot", "iterator", "let",
    "macro", "method", "mixin", "mod", "nil", "not", "notin", "object", "of", "or",
    "out", "proc", "ptr", "raise", "ref", "return", "shl", "shr", "static", "template",
    "try", "tuple", "type", "using", "var", "when", "while", "xor", "yield",
  ]
  ReservedTypes = [
    "CborValue", "CborEntry", "CborKind", "CborError", "GeneratedSchema", "EmptyTuple",
    "Result", "Opt", "ErrorCode", "SchemaSet", "SchemaNode", "Digest",
  ]

func at[K, V](t: Table[K, V], k: K): V =
  t.getOrDefault(k)

# Names ---------------------------------------------------------------------------

func pascal(stem: string): string =
  var s = ""
  for part in stem.split('_'):
    if part.len > 0:
      s.add(part[0].toUpperAscii & part[1 ..^ 1])
  s

func nimNorm(id: string): string =
  ## Nim identifier equality: first character exact, the rest case- and
  ## underscore-insensitive.
  if id.len == 0:
    ""
  else:
    id[0] & id[1 ..^ 1].toLowerAscii.replace("_", "")

func field(name: string): string =
  if name in NimKeywords:
    "`" & name & "`"
  else:
    name

proc claim(g: var NGen, id, origin: string) =
  let k = nimNorm(id)
  if k in g.idents:
    g.errors.add(
      "Nim identifier collision: " & id & " from " & origin & " and " & g.idents.at(k)
    )
  else:
    g.idents[k] = origin

func stemOf(g: NGen, doc: int, name: string): string =
  ## The C stem (§2.1; G158 interim for the common schema).
  let v = g.docs[doc]
  if v.common:
    localName(name, v.model.namespace)
  else:
    v.cns & "_" & capitalize(localName(name, v.model.namespace))

func isErrorCode(g: NGen, doc: int, name: string): bool =
  g.docs[doc].common and name == "logos.error_code"

func typeNameOf(g: NGen, doc: int, name: string): string =
  if g.isErrorCode(doc, name):
    "ErrorCode"
  else:
    pascal(g.stemOf(doc, name))

func inlineName(o: Owner, path: seq[Step], suffix: string): string =
  pascal(o.stem & path.mapIt(it.c).join("")) & suffix

func keys(path: seq[Step]): seq[string] =
  path.mapIt(it.key)

func fieldStep(name: string): Step =
  (name, "_" & capitalize(name))

func listStep(): Step =
  ("list_item", "_LI")

func tupleStep(i: int): Step =
  ("tuple_" & $i, "_TU" & $i)

func resolve(g: NGen, doc: int, n: SchemaNode): (int, Declaration) =
  if n.kind == snLocalRef:
    (doc, g.docs[doc].model.find(n.target).get)
  else:
    let (d, name) = g.byImport.getOrDefault(
      toHex(n.imported.root) & toHex(n.imported.subtree), (0, "")
    )
    (d, g.docs[d].model.find(name).get)

func isObject(n: SchemaNode): bool =
  n.kind in {snMap, snChoice}

func literalOf(g: NGen, doc: int, n: SchemaNode): Opt[ScalarData] =
  ## The literal a node requires, through named aliases.
  var (cd, cur) = (doc, n)
  while true:
    case cur.kind
    of snLiteral:
      return Opt.some(cur.literal)
    of snLocalRef, snImportedRef:
      let (d, decl) = g.resolve(cd, cur)
      (cd, cur) = (d, decl.body)
    else:
      return Opt.none(ScalarData)

# Nim spelling ----------------------------------------------------------------------

func scalarNim(k: ScalarKind): string =
  case k
  of skBool: "bool"
  of skUint8: "uint8"
  of skUint16: "uint16"
  of skUint32: "uint32"
  of skUint64: "uint64"
  of skInt8: "int8"
  of skInt16: "int16"
  of skInt32: "int32"
  of skInt64: "int64"
  of skTstr: "string"
  of skBstr: "seq[byte]"

func literalNim(d: ScalarData): string =
  case d.kind
  of skBool:
    $d.boolean
  of UnsignedKinds:
    $d.unsigned & "'u64"
  of SignedKinds:
    if d.signed == low(int64):
      "low(int64)"
    else:
      $d.signed & "'i64"
  of skTstr:
    escape(d.text)
  of skBstr:
    "@[]" # construction admits no byte-string literal

func literalType(d: ScalarData): string =
  case d.kind
  of skBool: "bool"
  of UnsignedKinds: "uint64"
  of SignedKinds: "int64"
  of skTstr: "string"
  of skBstr: "seq[byte]"

# Recursion -----------------------------------------------------------------------

proc occurrences(
    g: NGen,
    doc: int,
    owner: string,
    path: seq[string],
    n: SchemaNode,
    acc: var seq[(string, string)],
) =
  ## By-value references below `n`: (occurrence key, target declaration).
  case n.kind
  of snMap:
    for f in n.fields:
      g.occurrences(doc, owner, path & f.name, f.node, acc)
  of snTuple:
    for i, item in n.items:
      g.occurrences(doc, owner, path & ("tuple_" & $i), item, acc)
  of snChoice:
    for i, a in n.arms:
      g.occurrences(doc, owner, path & ("arm_" & $i), a, acc)
  of snLocalRef, snImportedRef:
    let (d, decl) = g.resolve(doc, n)
    if not g.docs[d].external:
      acc.add((choiceKey(owner, path), decl.name))
  else:
    discard # a list element is behind a seq: no by-value edge

proc findBoxed(g: var NGen) =
  ## A reference whose edge lies on a by-value cycle is a `ref` (the C mapping's
  ## recursive edges, §2.3). An alias's own body is never boxed: every cycle
  ## also passes through a map, tuple or choice (G153), whose edge is.
  var nodes: seq[string]
  var edges: Table[string, seq[string]]
  var occ: seq[(string, string, string)] # (owner, occurrence, target)
  for i, v in g.docs:
    if v.external:
      continue
    for d in v.model.declarations:
      if d.kind == dkMethod:
        continue
      nodes.add(d.name)
      var acc: seq[(string, string)]
      g.occurrences(i, d.name, @[], d.body, acc)
      for (k, t) in acc:
        edges.mgetOrPut(d.name, @[]).add(t)
        occ.add((d.name, k, t))
  nodes.sort()
  let comp = sccs(nodes, edges)
  var size: Table[int, int]
  for k in nodes:
    size.mgetOrPut(comp.at(k), 0).inc
  for (owner, k, t) in occ:
    if comp.at(owner) == comp.at(t) and (size.at(comp.at(owner)) > 1 or owner == t) and
        not k.endsWith("#"):
      g.boxed.incl(k)

# Expressions -----------------------------------------------------------------------

proc enc(g: NGen, o: Owner, path: seq[Step], n: SchemaNode, x: string): string

proc refEnc(g: NGen, o: Owner, path: seq[Step], n: SchemaNode, x: string): string =
  let (d, decl) = g.resolve(o.doc, n)
  let x =
    if choiceKey(o.name, path.keys) in g.boxed:
      x & "[]"
    else:
      x
  if g.isErrorCode(d, decl.name):
    "cbor(uint64(ord(" & x & ")))"
  elif decl.body.isObject:
    "toCbor(" & x & ")"
  else:
    "enc" & g.typeNameOf(d, decl.name) & "(" & x & ")"

proc enc(g: NGen, o: Owner, path: seq[Step], n: SchemaNode, x: string): string =
  ## A Nim expression encoding `x`, a value of the node at (`o`, `path`).
  case n.kind
  of snPrimitive:
    case n.scalar
    of UnsignedKinds:
      "cbor(uint64(" & x & "))"
    of SignedKinds:
      "cbor(int64(" & x & "))"
    else:
      "cbor(" & x & ")"
  of snLiteral:
    "cbor(" & literalNim(n.literal) & ")"
  of snMap, snChoice:
    "toCbor(" & x & ")"
  of snList:
    "cborArray(" & x & ".mapIt(" & g.enc(o, path & listStep(), n.element, "it") & "))"
  of snTuple:
    var items: seq[string]
    for i, item in n.items:
      items.add(g.enc(o, path & tupleStep(i), item, x & "[" & $i & "]"))
    "cborArray(" & items.join(", ") & ")"
  of snLocalRef, snImportedRef:
    g.refEnc(o, path, n, x)

proc dec(g: NGen, o: Owner, path: seq[Step], n: SchemaNode, v: string): string

proc refDec(g: NGen, o: Owner, path: seq[Step], n: SchemaNode, v: string): string =
  let (d, decl) = g.resolve(o.doc, n)
  let name = g.typeNameOf(d, decl.name)
  let e =
    if g.isErrorCode(d, decl.name):
      "ErrorCode(" & v & ".uint)"
    elif decl.body.isObject:
      "fromChecked(" & name & ", " & v & ")"
    else:
      "dec" & name & "(" & v & ")"
  if choiceKey(o.name, path.keys) in g.boxed:
    "boxed(" & e & ")"
  else:
    e

proc dec(g: NGen, o: Owner, path: seq[Step], n: SchemaNode, v: string): string =
  ## A Nim expression converting the checked value `v` of the node at
  ## (`o`, `path`).
  case n.kind
  of snPrimitive:
    case n.scalar
    of skBool:
      "asBool(" & v & ")"
    of UnsignedKinds:
      scalarNim(n.scalar) & "(" & v & ".uint)"
    of SignedKinds:
      scalarNim(n.scalar) & "(asInt64(" & v & "))"
    of skTstr:
      v & ".text"
    of skBstr:
      v & ".bytes"
  of snLiteral:
    literalNim(n.literal)
  of snMap:
    "fromChecked(" & inlineName(o, path, "Map") & ", " & v & ")"
  of snChoice:
    "fromChecked(" & inlineName(o, path, "Choice") & ", " & v & ")"
  of snList:
    v & ".items.mapIt(" & g.dec(o, path & listStep(), n.element, "it") & ")"
  of snTuple:
    if n.items.len == 0:
      return "EmptyTuple()"
    var items: seq[string]
    for i, item in n.items:
      items.add(g.dec(o, path & tupleStep(i), item, v & ".items[" & $i & "]"))
    if items.len == 1:
      "(" & items[0] & ",)"
    else:
      "(" & items.join(", ") & ")"
  of snLocalRef, snImportedRef:
    g.refDec(o, path, n, v)

# Types -----------------------------------------------------------------------------

proc genObject(g: var NGen, o: Owner, path: seq[Step], n: SchemaNode, name: string)

proc typeExpr(g: var NGen, o: Owner, path: seq[Step], n: SchemaNode): string =
  ## The Nim type of the node at (`o`, `path`); inline maps and choices are
  ## generated on the way.
  case n.kind
  of snPrimitive:
    scalarNim(n.scalar)
  of snLiteral:
    literalType(n.literal)
  of snMap:
    let name = inlineName(o, path, "Map")
    g.genObject(o, path, n, name)
    name
  of snChoice:
    let name = inlineName(o, path, "Choice")
    g.genObject(o, path, n, name)
    name
  of snList:
    "seq[" & g.typeExpr(o, path & listStep(), n.element) & "]"
  of snTuple:
    if n.items.len == 0:
      return "EmptyTuple"
    var items: seq[string]
    for i, item in n.items:
      items.add(g.typeExpr(o, path & tupleStep(i), item))
    if items.len == 1:
      "(" & items[0] & ",)"
    else:
      "(" & items.join(", ") & ")"
  of snLocalRef, snImportedRef:
    let (d, decl) = g.resolve(o.doc, n)
    let name = g.typeNameOf(d, decl.name)
    if choiceKey(o.name, path.keys) in g.boxed:
      "ref " & name
    else:
      name

proc genObject(g: var NGen, o: Owner, path: seq[Step], n: SchemaNode, name: string) =
  g.claim(name, choiceKey(o.name, path.keys))
  let key = choiceKey(o.name, path.keys)
  g.forwards.add("proc toCbor*(x: " & name & "): CborValue")
  g.forwards.add("proc fromChecked*(T: type " & name & ", v: CborValue): " & name)
  if n.kind == snMap:
    var decl = "  " & name & "* = object"
    var encBody =
      "proc toCbor*(x: " & name & "): CborValue =\n  var e: seq[CborEntry]\n"
    var decBody =
      "proc fromChecked*(T: type " & name & ", v: CborValue): " & name & " =\n  var r = " &
      name & "()\n"
    var seen: Table[string, string]
    for f in n.fields:
      let fname = field(f.name)
      if nimNorm(f.name) in seen:
        g.errors.add(
          "Nim identifier collision: fields " & f.name & " and " &
            seen.at(nimNorm(f.name)) & " of " & name
        )
      seen[nimNorm(f.name)] = f.name
      let fpath = path & fieldStep(f.name)
      let t = g.typeExpr(o, fpath, f.node)
      let lit = g.literalOf(o.doc, f.node)
      if f.optional:
        decl.add("\n    " & fname & "*: Opt[" & t & "]")
        encBody.add(
          "  if x." & fname & ".isSome:\n    e.add((cbor(" & escape(f.name) & "), " &
            g.enc(o, fpath, f.node, "x." & fname & ".get") & "))\n"
        )
        decBody.add(
          "  block:\n    let f = v.lookup(" & escape(f.name) &
            ")\n    if f.isSome:\n      r." & fname & " = Opt.some(" &
            g.dec(o, fpath, f.node, "f.get") & ")\n"
        )
      else:
        let default =
          if lit.isSome:
            " = " & literalNim(lit.get)
          else:
            ""
        decl.add("\n    " & fname & "*: " & t & default)
        encBody.add(
          "  e.add((cbor(" & escape(f.name) & "), " &
            g.enc(o, fpath, f.node, "x." & fname) & "))\n"
        )
        if lit.isNone:
          decBody.add(
            "  r." & fname & " = " &
              g.dec(o, fpath, f.node, "v.lookup(" & escape(f.name) & ").get") & "\n"
          )
    g.types.add(decl)
    g.procs.add(encBody & "  cborMap(e)")
    g.procs.add(decBody & "  r")
  else: # choice
    let kind = name & "Kind"
    g.claim(kind, key)
    var labels: seq[Opt[string]]
    for a in n.arms:
      if a.kind in {snLocalRef, snImportedRef}:
        let (d, decl) = g.resolve(o.doc, a)
        labels.add(armLabelOf(a, referenceLabel(g.docs[d].model.namespace, decl.name)))
      else:
        labels.add(armLabelOf(a))
    let (symbolic, steps) = choiceSteps(labels)
    var members: seq[string] # by canonical arm index
    var seen: Table[string, string]
    for i in 0 ..< n.arms.len:
      let m = (if symbolic: steps[i] else: "Case" & steps[i])
      if nimNorm(m) in seen:
        g.errors.add(
          "Nim identifier collision: arms " & m & " and " & seen.at(nimNorm(m)) & " of " &
            name
        )
      seen[nimNorm(m)] = m
      members.add(m)
    func armPath(i: int): seq[Step] =
      path & (("arm_" & $i), (if symbolic: "_AR_" & steps[i]
        else: "_AR" & steps[i]))

    var enumDecl = "  " & kind & "* {.pure.} = enum"
    var decl = "  " & name & "* = object\n    case kind*: " & kind
    var encBody = "proc toCbor*(x: " & name & "): CborValue =\n  case x.kind\n"
    var decBody =
      "proc fromChecked*(T: type " & name & ", v: CborValue): " & name &
      " =\n  case generatedSchema().arm(" & escape(key) & ", v)\n"
    for i in discriminantOrder(symbolic, steps):
      let a = n.arms[i]
      let m = members[i]
      let field = "arm_" & steps[i]
      enumDecl.add("\n    " & m)
      decl.add("\n    of " & kind & "." & m & ":")
      encBody.add("  of " & kind & "." & m & ":\n    ")
      if a.kind == snLiteral:
        decl.add("\n      discard")
        encBody.add(g.enc(o, armPath(i), a, "") & "\n")
      else:
        decl.add("\n      " & field & "*: " & g.typeExpr(o, armPath(i), a))
        encBody.add(g.enc(o, armPath(i), a, "x." & field) & "\n")
    for i, a in n.arms:
      let field = "arm_" & steps[i]
      decBody.add("  of " & $i & ":\n    " & name & "(kind: " & kind & "." & members[i])
      if a.kind == snLiteral:
        decBody.add(")\n")
      else:
        decBody.add(", " & field & ": " & g.dec(o, armPath(i), a, "v") & ")\n")
    g.types.add(enumDecl)
    g.types.add(decl)
    g.procs.add(encBody.strip(leading = false))
    g.procs.add(
      decBody & "  else:\n    raiseAssert \"a checked value selects a known arm\""
    )

proc genDeclaration(g: var NGen, doc: int, d: Declaration) =
  if d.kind == dkMethod or g.isErrorCode(doc, d.name):
    return
  let o = Owner(doc: doc, name: d.name, stem: g.stemOf(doc, d.name))
  let name = g.typeNameOf(doc, d.name)
  if d.body.isObject:
    g.genObject(o, @[], d.body, name)
    # The checked API of a named map or choice.
    let q = escape(d.name)
    g.api.add(
      "proc fromCbor*(T: type " & name & ", v: CborValue): Result[" & name &
        ", string] =\n  ## A value checked against `" & d.name &
        "`.\n  ?generatedSchema().check(" & q & ", v)\n  ok(fromChecked(T, v))"
    )
    g.api.add(
      "proc encode*(x: " & name &
        "): Result[seq[byte], string] =\n  ## Logos deterministic CBOR, checked against `" &
        d.name & "`.\n  generatedSchema().encodeChecked(" & q & ", toCbor(x))"
    )
    g.api.add(
      "proc decode*(T: type " & name & ", data: openArray[byte]): Result[" & name &
        ", string] =\n  ## One deterministic-CBOR `" & d.name &
        "` value.\n  let v = ?generatedSchema().decodeChecked(" & q &
        ", data)\n  ok(fromChecked(T, v))"
    )
  else:
    g.claim(name, d.name)
    g.claim("enc" & name, d.name)
    g.claim("dec" & name, d.name)
    g.types.add("  " & name & "* = " & g.typeExpr(o, @[], d.body))
    if d.body.kind == snLiteral:
      g.claim(name & "Literal", d.name)
      g.consts.add(
        "const " & name & "Literal* = " & literalNim(d.body.literal) & " ## `" & d.name &
          "`"
      )
    g.forwards.add("proc enc" & name & "*(x: " & name & "): CborValue")
    g.forwards.add("proc dec" & name & "*(v: CborValue): " & name)
    g.procs.add(
      "proc enc" & name & "*(x: " & name & "): CborValue =\n  " &
        g.enc(o, @[], d.body, "x")
    )
    g.procs.add(
      "proc dec" & name & "*(v: CborValue): " & name & " =\n  " &
        g.dec(o, @[], d.body, "v")
    )

# Modules ---------------------------------------------------------------------------

proc newNGen(docs: seq[Doc], roots: seq[Digest]): NGen =
  var g = NGen(docs: docs)
  for i, v in docs:
    for d in v.model.declarations:
      if d.kind != dkMethod:
        g.byImport[toHex(roots[i]) & toHex(declarationRoot(v.model, d))] = (i, d.name)
  for t in ReservedTypes:
    g.idents[nimNorm(t)] = "the runtime"
  g

proc assemble(g: NGen, header, imports, schema: string): Result[string, string] =
  if g.errors.len > 0:
    return err(g.errors[0])
  # nph leaves everything after `#!fmt: off` as written: generated modules are
  # compared byte for byte with lcn-gen's output, and nph 0.7.0 ignores the
  # `.nph.toml` exclusions.
  var s =
    header & "\n\n#!fmt: off\n{.push raises: [], gcsafe.}\n\n" & imports & "\n" & schema &
    "\n"
  if g.types.len > 0:
    s.add("\ntype\n" & g.types.join("\n\n") & "\n")
  if g.consts.len > 0:
    s.add("\n" & g.consts.join("\n") & "\n")
  if g.forwards.len > 0:
    s.add("\n" & g.forwards.join("\n") & "\n")
  for p in g.procs:
    s.add("\n" & p & "\n")
  for p in g.api:
    s.add("\n" & p & "\n")
  ok(s)

func stamp(): string =
  "PROVISIONAL (spec " & SpecRevision[0 .. 7] & ")"

proc commonNimModule*(
    opts = NimOptions(importPrefix: "logos_core/")
): Result[string, string] =
  ## The Nim types of the pinned common schema (INTERFACE §5.1):
  ## `iface/common_types.nim`.
  let ctx = pinnedContext()
  var g = newNGen(
    @[Doc(model: ctx.commonModel, common: true, external: false)], @[ctx.commonRoot]
  )
  g.findBoxed()
  for d in ctx.commonModel.declarations:
    g.genDeclaration(0, d)
  g.assemble(
    "## common_types.nim: generated by lcn-gen from the pinned common schema\n" &
      "## (INTERFACE §5.1). " & stamp() &
      ". Nim types with Logos deterministic-CBOR codecs\n## (D29). Do not edit.",
    "import " & opts.importPrefix & "codegen/nimrt\nfrom " & opts.importPrefix &
      "iface/outcome import ErrorCode\n\nexport nimrt, ErrorCode\n",
    "perThread(generatedSchema, GeneratedSchema, loadCommonSchema())\ndiscard generatedSchema()",
  )

proc nimTypeNames*(s: ContractSet): Table[string, string] =
  ## The Nim type `nimModule` gives each named declaration of `s` other than a
  ## method, by qualified name (the module kit names request, response and event
  ## types with it).
  var docs: seq[Doc]
  var roots: seq[Digest]
  for c in s.documents:
    docs.add(Doc(model: c.model, cns: projectNamespace(c.model.namespace)))
    roots.add(c.root)
  let g = newNGen(docs, roots)
  for i, v in docs:
    for d in v.model.declarations:
      if d.kind != dkMethod:
        result[d.name] = g.typeNameOf(i, d.name)

proc nimModule*(
    s: ContractSet, opts = NimOptions(importPrefix: "logos_core/"), system = false
): Result[string, string] =
  ## The Nim types and codecs of one accepted set (every document's
  ## declarations). The module embeds the documents and reloads them at start.
  var docs: seq[Doc]
  var roots: seq[Digest]
  for c in s.documents:
    docs.add(Doc(model: c.model, cns: projectNamespace(c.model.namespace)))
    roots.add(c.root)
  let ctx = pinnedContext()
  docs.add(Doc(model: ctx.commonModel, common: true, external: true))
  roots.add(ctx.commonRoot)
  var g = newNGen(docs, roots)
  for d in ctx.commonModel.declarations:
    if d.kind != dkMethod:
      g.idents[nimNorm(g.typeNameOf(docs.len - 1, d.name))] = "the common schema"
  g.findBoxed()
  for i in 0 ..< docs.len - 1:
    for d in docs[i].model.declarations:
      g.genDeclaration(i, d)
  let name = s.cSchemaSet.headerName
  let schema =
    "const\n  primaryDocument = " & escape(s.primary.source) &
    "\n  interfaceDocuments: array[" & $s.interfaces.len & ", string] = [" &
    s.interfaces.mapIt(escape(it.source)).join(", ") & "]\n  supportingDocuments: array[" &
    $s.supporting.len & ", string] = [" &
    s.supporting.mapIt(escape(it.source)).join(", ") &
    "]\n\nperThread(\n  generatedSchema,\n  GeneratedSchema,\n  loadSchema(primaryDocument, interfaceDocuments, supportingDocuments, " &
    $system & "),\n)\ndiscard generatedSchema()" & (
      if opts.schemaAccessor.len > 0:
        "\n\ntemplate " & opts.schemaAccessor &
          "*(): GeneratedSchema =\n  ## This set's schema, loaded once per thread.\n  generatedSchema()"
      else:
        ""
    )
  g.assemble(
    "## " & name & "_types.nim: generated by lcn-gen. " & stamp() &
      ".\n## Nim types with Logos deterministic-CBOR codecs (D29). Do not edit.",
    "import " & opts.importPrefix & "codegen/nimrt\nimport " & opts.importPrefix &
      "iface/common_types\n\nexport nimrt, common_types\n",
    schema,
  )
