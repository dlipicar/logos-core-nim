## A schema suite for the rules of a generated contract set (DECISIONS I88, W2):
## the Runtime Types and Runtime Control (RUNTIME §9.2, §9.3) and the Capability
## Authority contract. For each rule, values built from the accepted model (the
## smallest and the largest each bound allows, and each arm of a top-level
## choice) validate and round-trip byte for byte through the generated codec;
## values just outside a size, range or choice bound, a map missing a required
## field and a map with an unknown one are refused. Independent of the code
## under test: the values come from the model, the verdicts from the schema.

import std/[macros, strutils, tables]
import ../../src/logos_core/cbor
import ../../src/logos_core/[commitment, hash]
import ../../src/logos_core/codegen/nimrt
import ../../src/logos_core/iface/accept

export cbor, nimrt

type
  RuleModel* = object
    g*: GeneratedSchema
    byName: Table[string, SchemaNode] ## every non-method declaration's body
    bySubtree: Table[Digest, SchemaNode] ## the same, by declaration root
    names*: seq[string] ## the primary document's rules, in model order
    moduleName*: string

  Shape = enum
    smallest ## required fields only, empty lists, minimal sizes and values
    largest ## every optional field, one list item, maximal sizes and values

proc add(m: var RuleModel, model: SchemaModel) =
  for d in model.declarations:
    if d.kind != dkMethod:
      m.byName[d.name] = d.body
      m.bySubtree[declarationRoot(model, d)] = d.body

proc ruleModel*(docs: (string, seq[string], seq[string])): RuleModel =
  ## The accepted set a generated module embeds (`rcDocuments`, `caDocuments`).
  let s = acceptContractSet(docs[0], docs[1], docs[2], AcceptOptions(system: true)).get
  result.g = loadSchemaSet(s)
  for c in s.documents:
    result.add(c.model)
  result.add(s.context.commonModel)
  for d in s.primary.model.declarations:
    if d.kind != dkMethod:
      result.names.add(d.name)
  result.moduleName = s.primary.model.moduleName.get("")

proc resolve(m: RuleModel, n: SchemaNode): SchemaNode =
  var x = n
  for _ in 0 .. 64:
    case x.kind
    of snLocalRef:
      doAssert x.target in m.byName, "unresolved " & x.target
      x = m.byName.getOrDefault(x.target)
    of snImportedRef:
      doAssert x.imported.subtree in m.bySubtree, "unresolved import"
      x = m.bySubtree.getOrDefault(x.imported.subtree)
    else:
      return x
  doAssert false, "a reference cycle"

func literalValue(s: ScalarData): CborValue =
  case s.kind
  of skBool:
    cbor(s.boolean)
  of skUint8 .. skUint64:
    cbor(s.unsigned)
  of skInt8 .. skInt64:
    cbor(s.signed)
  of skTstr:
    cbor(s.text)
  of skBstr:
    cbor(s.bytes)

const LargestBytes = 65536 ## a larger maximum is sampled at its minimum

func highOf(k: ScalarKind): uint64 =
  case k
  of skUint8:
    uint64(high(uint8))
  of skUint16:
    uint64(high(uint16))
  of skUint32:
    uint64(high(uint32))
  else:
    high(uint64)

func lowOf(k: ScalarKind): int64 =
  case k
  of skInt8:
    int64(low(int8))
  of skInt16:
    int64(low(int16))
  of skInt32:
    int64(low(int32))
  else:
    low(int64)

proc sizeOf(n: SchemaNode, shape: Shape): int =
  let (lo, hi) = n.size.get((0'u64, 16'u64))
  if shape == largest and hi <= LargestBytes:
    int(hi)
  else:
    int(max(lo, 0'u64))

proc sample(m: RuleModel, n: SchemaNode, shape: Shape, arm = -1): CborValue =
  let n = m.resolve(n)
  case n.kind
  of snPrimitive:
    case n.scalar
    of skBool:
      cbor(shape == largest)
    of skUint8 .. skUint64:
      cbor(
        if shape == largest:
          highOf(n.scalar)
        else:
          0'u64
      )
    of skInt8 .. skInt64:
      cbor(
        if shape == largest:
          lowOf(n.scalar)
        else:
          0'i64
      )
    of skTstr:
      cbor("a".repeat(n.sizeOf(shape)))
    of skBstr:
      cbor(newSeq[byte](n.sizeOf(shape)))
  of snLiteral:
    literalValue(n.literal)
  of snMap:
    var entries: seq[CborEntry]
    for f in n.fields:
      if not f.optional or shape == largest:
        entries.add((cbor(f.name), m.sample(f.node, shape)))
    cborMap(entries)
  of snList:
    if shape == largest:
      cborArray(m.sample(n.element, shape))
    else:
      cborArray()
  of snTuple:
    var items: seq[CborValue]
    for i in n.items:
      items.add(m.sample(i, shape))
    cborArray(items)
  of snChoice:
    let i =
      if arm >= 0:
        arm
      elif shape == largest:
        n.arms.high
      else:
        0
    m.sample(n.arms[i], shape)
  of snLocalRef, snImportedRef:
    doAssert false, "resolved above"
    cbor(0'u64)

proc samples*(m: RuleModel, rule: string): seq[CborValue] =
  ## The smallest and largest value of `rule`, and of each arm of a top-level
  ## choice.
  let body = m.resolve(m.byName.getOrDefault(rule))
  doAssert body != nil, rule & " is not declared"
  if body.kind == snChoice:
    for i in 0 ..< body.arms.len:
      result.add(m.sample(body, smallest, i))
      result.add(m.sample(body, largest, i))
  else:
    result.add(m.sample(body, smallest))
    result.add(m.sample(body, largest))

proc composite*(m: RuleModel, rule: string): bool =
  ## Whether the rule is generated as a Nim object or variant (a map, or a
  ## choice that is not only literals), so its codec must exist.
  let body = m.resolve(m.byName.getOrDefault(rule))
  case body.kind
  of snMap:
    true
  of snChoice:
    for a in body.arms:
      if m.resolve(a).kind != snLiteral:
        return true
    false
  else:
    false

proc outside*(m: RuleModel, rule: string): seq[(string, CborValue)] =
  ## Values just outside the rule's own bounds, each with what it breaks.
  let body = m.resolve(m.byName.getOrDefault(rule))
  case body.kind
  of snPrimitive:
    case body.scalar
    of skTstr, skBstr:
      if body.size.isSome:
        let (lo, hi) = body.size.get
        proc sized(n: int): CborValue =
          if body.scalar == skTstr:
            cbor("a".repeat(n))
          else:
            cbor(newSeq[byte](n))

        if lo > 0:
          result.add(("below the minimum size", sized(int(lo) - 1)))
        if hi <= 16 * 1024 * 1024:
          result.add(("above the maximum size", sized(int(hi) + 1)))
      result.add(("another major type", cbor(true)))
    of skUint8 .. skUint32:
      result.add(("above the range", cbor(highOf(body.scalar) + 1)))
      result.add(("negative", cbor(-1'i64)))
    of skUint64:
      result.add(("negative", cbor(-1'i64)))
    of skInt8 .. skInt32:
      result.add(("below the range", cbor(lowOf(body.scalar) - 1)))
    of skInt64, skBool:
      result.add(("another major type", cbor("x")))
  of snLiteral:
    result.add(("another value", cbor("zz-not-the-literal")))
  of snChoice:
    result.add(("no arm", cbor("zz-not-an-arm")))
  of snMap:
    let full = m.sample(body, largest)
    var extra = full.entries
    extra.add((cbor("zz_unknown"), cbor(0'u64)))
    result.add(("an unknown field", cborMap(extra)))
    for f in body.fields:
      if not f.optional:
        var short: seq[CborEntry]
        for e in full.entries:
          if e.key.getText.get("") != f.name:
            short.add(e)
        result.add(("without " & f.name, cborMap(short)))
        break
  of snList:
    result.add(("not an array", cborMap()))
  of snTuple:
    result.add(("one item short", cborArray()))
  of snLocalRef, snImportedRef:
    discard

macro codecTable*(prefix: static string, rules: static openArray[string]): untyped =
  ## `proc(rule: string, v: CborValue): Opt[seq[byte]]`: the deterministic CBOR
  ## of `v` decoded into the rule's generated Nim type and encoded again; none
  ## for a rule generated as a plain Nim type (an alias of a primitive).
  ## The type is the rule's name in the generated form: `logos.a_b.c_d` is
  ## `<prefix>AB` & `CD`.
  let rule = ident"rule"
  let v = ident"v"
  var cases = nnkCaseStmt.newTree(rule)
  for r in rules:
    var name = prefix
    let parts = r.split('.')
    for p in parts[1 .. ^1]:
      for w in p.split('_'):
        if w.len > 0:
          name.add(w[0].toUpperAscii & w[1 .. ^1])
    let t = ident(name)
    cases.add nnkOfBranch.newTree(
      newLit(r),
      quote do:
        when declared(`t`) and compiles(toCbor(fromChecked(`t`, `v`))):
          Opt.some(encodeCbor(toCbor(fromChecked(`t`, `v`))))
        else:
          Opt.none(seq[byte]),
    )
  cases.add nnkElse.newTree(
    quote do:
      Opt.none(seq[byte])
  )
  result = quote:
    proc(`rule`: string, `v`: CborValue): Opt[seq[byte]] {.closure.} =
      `cases`

proc checkRule*(
    m: RuleModel,
    rule: string,
    codec: proc(rule: string, v: CborValue): Opt[seq[byte]] {.closure.},
): seq[string] =
  ## What is wrong with `rule`'s schema or codec; empty when nothing is.
  for v in m.samples(rule):
    let r = m.g.check(rule, v)
    if r.isErr:
      result.add("refuses its own sample " & toDiag(v) & ": " & r.error)
      continue
    let back = codec(rule, v)
    if back.isSome and back.get != encodeCbor(v):
      result.add("the codec changes " & toDiag(v))
  for (what, v) in m.outside(rule):
    if m.g.check(rule, v).isOk:
      result.add("accepts a value " & what)
