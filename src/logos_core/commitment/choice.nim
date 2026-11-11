## COMMITMENT §3.1: structural choice selection plans.
##
## A choice schema is valid only when a structural selection plan separates its
## arms: a finite decision tree over the decoded value's CBOR major type, exact
## scalar literal, fixed tuple length, and closed-map field literals and presence,
## whose every leaf holds at most one arm [SPEC COMMITMENT §3.1]. The plan is
## derived from the canonical arm nodes and is never an identity input; a decoder
## follows it to the one candidate arm and then validates the whole value against
## that arm.
##
## Structural outcomes are conservative: an arm stays a candidate unless its schema
## proves it rejects the observation. References are followed (memoized, keyed by
## the observation) and stay terminal nodes in every identity; a reference reached
## again while it is being followed for the same observation proves nothing, so the
## arm stays a candidate.
## [IMPL-DECISION G9] The literals that create outcomes are those on the observed
## value itself (or on the observed field's value), following references and
## nested choices; literals deeper in an arm do not.

{.push raises: [].}

import std/[algorithm, sequtils, sets, tables]
import ../cbor
import ../hash/hashinput
import ../base/hex
import ./schema

type
  SchemaSet* = object
    ## The schema documents a model's references reach. `docs[0]` is the model
    ## itself; imported references resolve by their (schema root, subtree root).
    docs*: seq[SchemaModel]
    imported: Table[string, (int, string)]

  PlanTest* = enum
    ptMajorType = "major type"
    ptScalarLiteral = "scalar literal"
    ptTupleLength = "tuple length"
    ptFieldLiteral = "map-field literal"
    ptFieldPresence = "map-field presence"

  OutcomeKind* = enum
    ocMajor ## the value's CBOR major type is `major`
    ocLiteral ## the observed scalar is exactly `literal`
    ocLength ## the array has `length` elements
    ocAbsent ## the map has no such field
    ocPresent ## the map has the field
    ocOther ## any other scalar, array length or present field value
    ocNotApplicable ## the observation does not exist for this value

  Outcome* = object
    case kind*: OutcomeKind
    of ocMajor:
      major*: uint8
    of ocLiteral:
      literal*: CborValue
    of ocLength:
      length*: uint64
    else:
      discard

  SelectionPlan* = ref object
    ## [SPEC COMMITMENT §3.1] A leaf holds one canonical arm index. A test node
    ## lists every outcome of its test; an outcome that retains no candidate has a
    ## nil child.
    case leaf*: bool
    of true:
      arm*: int
    of false:
      test*: PlanTest
      field*: string ## the map field the two map-field tests observe
      branches*: seq[(Outcome, SelectionPlan)]

  ObsKind = enum
    obMajor
    obScalarIs
    obScalarOther
    obNonScalar
    obLength
    obLengthOther
    obNonArray
    obFieldAbsent
    obFieldIs
    obFieldOther
    obFieldPresent
    obNonMap

  Obs = object
    ## One outcome of one test, as a question asked of a schema node: can it
    ## accept a value with this observed structure?
    kind: ObsKind
    major: uint8
    literal: CborValue
    literals: seq[CborValue]
    length: uint64
    lengths: seq[uint64]
    field: string

  Planner = object
    set: ptr SchemaSet
    memo: Table[string, bool]
    visiting: HashSet[string]

const
  MaxCapacity = high(uint64) ## "more values than any schema names"
  Utf8OneByte = 127'u64 ## U+0001..U+007F; Logos text excludes NUL

func importKey(i: SchemaImport): string =
  toHex(i.root) & toHex(i.subtree)

func addDocument*(
    s: var SchemaSet, m: SchemaModel, root: Digest, roots: seq[(string, Digest)]
) =
  ## Adds a dependency document; `roots` maps each declaration it exports to the
  ## subtree root that imported references to it carry.
  let idx = s.docs.len
  s.docs.add(m)
  for (name, subtree) in roots:
    s.imported[importKey(SchemaImport(root: root, subtree: subtree))] = (idx, name)

func schemaSet*(m: SchemaModel): SchemaSet =
  SchemaSet(docs: @[m])

func resolve(s: SchemaSet, doc: int, n: SchemaNode): Opt[(int, Declaration)] =
  let (d, name) =
    if n.kind == snLocalRef:
      (doc, n.target)
    else:
      s.imported.getOrDefault(importKey(n.imported), (-1, ""))
  if d < 0:
    return Opt.none((int, Declaration))
  let decl = s.docs[d].find(name)
  if decl.isNone or decl.get.kind == dkMethod:
    return Opt.none((int, Declaration))
  Opt.some((d, decl.get))

func resolveImport*(s: SchemaSet, i: SchemaImport): Opt[(int, Declaration)] =
  ## [SPEC COMMITMENT §9.1] The one named type declaration an imported reference
  ## names: its schema root must be a supplied document's and its subtree root
  ## that of one of the document's named types.
  s.resolve(0, SchemaNode(kind: snImportedRef, imported: i)).filter(
    proc(t: (int, Declaration)): bool =
      t[1].kind == dkType
  )

# Scalars -------------------------------------------------------------------------

func literalValue*(s: ScalarData): CborValue =
  ## A literal's value as decoded CBOR, the form outcomes compare by.
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

func key(v: CborValue): string =
  let b = encodeCbor(v)
  var k = newString(b.len)
  for i, x in b:
    k[i] = char(x)
  k

func contains(vs: seq[CborValue], v: CborValue): bool =
  let k = key(v)
  for x in vs:
    if key(x) == k:
      return true
  false

func majorOf*(v: CborValue): uint8 =
  case v.kind
  of ckUint: 0
  of ckNint: 1
  of ckBytes: 2
  of ckText: 3
  of ckArray: 4
  of ckMap: 5
  of ckTag: 6
  of ckSimple, ckFloat: 7

func isScalar(v: CborValue): bool =
  v.kind notin {ckArray, ckMap, ckTag}

func sizeBounds(n: SchemaNode): (uint64, uint64) =
  if n.size.isSome:
    n.size.get
  else:
    (0'u64, high(uint64))

func primitiveAccepts*(n: SchemaNode, v: CborValue): bool =
  ## Whether the decoded scalar `v` is a valid value of the primitive node `n`
  ## [SPEC COMMITMENT §9.1; INTERFACE §1.3 ranges].
  let (lo, hi) = n.sizeBounds
  case n.scalar
  of skBool:
    v.kind == ckSimple and v.simple in {SimpleFalse, SimpleTrue}
  of skUint8 .. skUint64:
    let top =
      case n.scalar
      of skUint8:
        uint64(high(uint8))
      of skUint16:
        uint64(high(uint16))
      of skUint32:
        uint64(high(uint32))
      else:
        high(uint64)
    v.kind == ckUint and v.uint <= top
  of skInt8 .. skInt64:
    let top =
      case n.scalar
      of skInt8:
        uint64(high(int8))
      of skInt16:
        uint64(high(int16))
      of skInt32:
        uint64(high(int32))
      else:
        uint64(high(int64))
    (v.kind == ckUint and v.uint <= top) or (v.kind == ckNint and v.nint <= top)
  of skTstr:
    v.kind == ckText and v.validUtf8 and '\0' notin v.text and
      uint64(v.text.len) in lo .. hi
  of skBstr:
    v.kind == ckBytes and uint64(v.bytes.len) in lo .. hi

func capacity(n: SchemaNode): uint64 =
  ## How many distinct values the primitive accepts, saturating at `MaxCapacity`.
  case n.scalar
  of skBool:
    2
  of skUint8, skInt8:
    256
  of skUint16, skInt16:
    65536
  of skUint32, skInt32:
    1'u64 shl 32
  of skUint64, skInt64:
    MaxCapacity
  of skTstr, skBstr:
    let (lo, hi) = n.sizeBounds
    if hi >= 2:
      return MaxCapacity
    var c = 0'u64
    if lo == 0:
      c += 1
    if hi >= 1:
      c += (if n.scalar == skTstr: Utf8OneByte else: 256)
    c

func acceptsOther(n: SchemaNode, literals: seq[CborValue]): bool =
  ## Whether the primitive accepts some scalar that is none of `literals`.
  var taken = 0'u64
  for l in literals:
    if n.primitiveAccepts(l):
      inc taken
  taken < n.capacity

# Structural questions --------------------------------------------------------------

func obsKey(o: Obs): string =
  var k = $o.kind & "|" & o.field & "|" & $o.major & "|" & $o.length
  if not o.literal.isNil:
    k.add("|" & key(o.literal))
  for l in o.literals:
    k.add("," & key(l))
  for n in o.lengths:
    k.add(";" & $n)
  k

func accepts(p: var Planner, doc: int, n: SchemaNode, o: Obs): bool

func follow(p: var Planner, doc: int, n: SchemaNode, o: Obs): bool =
  let target = p.set[].resolve(doc, n)
  if target.isNone:
    return true # nothing proves a rejection
  let (d, decl) = target.get
  let k = $d & "|" & decl.name & "|" & obsKey(o)
  if k in p.memo:
    return p.memo.getOrDefault(k)
  if k in p.visiting:
    return true # a reference cycle gives no finite outcome for this question
  p.visiting.incl(k)
  let r = p.accepts(d, decl.body, o)
  p.visiting.excl(k)
  p.memo[k] = r
  r

func fieldOf(n: SchemaNode, name: string): Opt[SchemaField] =
  for f in n.fields:
    if f.name == name:
      return Opt.some(f)
  Opt.none(SchemaField)

func accepts(p: var Planner, doc: int, n: SchemaNode, o: Obs): bool =
  ## [SPEC COMMITMENT §3.1] Whether `n` can accept a value with the observed
  ## structure; true unless the schema proves otherwise.
  case n.kind
  of snLocalRef, snImportedRef:
    return p.follow(doc, n, o)
  of snChoice:
    for a in n.arms:
      if p.accepts(doc, a, o):
        return true
    return false
  else:
    discard
  case o.kind
  of obMajor:
    case n.kind
    of snPrimitive:
      case n.scalar
      of skBool:
        o.major == 7
      of skUint8 .. skUint64:
        o.major == 0
      of skInt8 .. skInt64:
        o.major in {0'u8, 1}
      of skTstr:
        o.major == 3
      of skBstr:
        o.major == 2
    of snLiteral:
      o.major == majorOf(literalValue(n.literal))
    of snMap:
      o.major == 5
    else:
      o.major == 4
  of obScalarIs:
    case n.kind
    of snPrimitive:
      n.primitiveAccepts(o.literal)
    of snLiteral:
      key(literalValue(n.literal)) == key(o.literal)
    else:
      false
  of obScalarOther:
    case n.kind
    of snPrimitive:
      n.acceptsOther(o.literals)
    of snLiteral:
      literalValue(n.literal) notin o.literals
    else:
      false
  of obNonScalar:
    n.kind in {snMap, snList, snTuple}
  of obLength:
    (n.kind == snTuple and uint64(n.items.len) == o.length) or n.kind == snList
  of obLengthOther:
    (n.kind == snTuple and uint64(n.items.len) notin o.lengths) or n.kind == snList
  of obNonArray:
    n.kind notin {snList, snTuple}
  of obFieldAbsent:
    n.kind == snMap and (let f = n.fieldOf(o.field); f.isNone or f.get.optional)
  of obFieldPresent:
    n.kind == snMap and n.fieldOf(o.field).isSome
  of obFieldIs:
    if n.kind != snMap or n.fieldOf(o.field).isNone:
      return false
    p.accepts(
      doc, n.fieldOf(o.field).get.node, Obs(kind: obScalarIs, literal: o.literal)
    )
  of obFieldOther:
    if n.kind != snMap or n.fieldOf(o.field).isNone:
      return false
    let f = n.fieldOf(o.field).get.node
    p.accepts(doc, f, Obs(kind: obScalarOther, literals: o.literals)) or
      p.accepts(doc, f, Obs(kind: obNonScalar))
  of obNonMap:
    n.kind != snMap

# What the candidate arms state at their top level ---------------------------------

type Facts = object
  literals: seq[CborValue]
  lengths: seq[uint64]
  fields: seq[string]

func collect(
    p: Planner,
    doc: int,
    n: SchemaNode,
    field: string,
    facts: var Facts,
    seen: var HashSet[string],
) =
  ## [IMPL-DECISION G9] Literals, tuple lengths and field names on the observed
  ## value itself, through references and nested choices. With `field` set, the
  ## literals of that field's value in each map.
  case n.kind
  of snLocalRef, snImportedRef:
    let t = p.set[].resolve(doc, n)
    if t.isSome:
      let (d, decl) = t.get
      if not seen.containsOrIncl($d & "|" & decl.name):
        p.collect(d, decl.body, field, facts, seen)
  of snChoice:
    for a in n.arms:
      p.collect(doc, a, field, facts, seen)
  of snLiteral:
    if field.len == 0:
      let v = literalValue(n.literal)
      if v notin facts.literals:
        facts.literals.add(v)
  of snTuple:
    if field.len == 0 and uint64(n.items.len) notin facts.lengths:
      facts.lengths.add(uint64(n.items.len))
  of snMap:
    if field.len == 0:
      for f in n.fields:
        if f.name notin facts.fields:
          facts.fields.add(f.name)
    else:
      let f = n.fieldOf(field)
      if f.isSome:
        var inner: HashSet[string]
        var sub: Facts
        p.collect(doc, f.get.node, "", sub, inner)
        for l in sub.literals:
          if l notin facts.literals:
            facts.literals.add(l)
  of snPrimitive, snList:
    discard

func facts(
    p: Planner, doc: int, arms: seq[SchemaNode], cands: seq[int], field = ""
): Facts =
  ## Outcomes are listed in a fixed order so the plan never depends on arm order.
  var
    seen: HashSet[string]
    f: Facts
  for i in cands:
    p.collect(doc, arms[i], field, f, seen)
  f.literals.sort(
    proc(a, b: CborValue): int =
      cmpBytes(encodeCbor(a), encodeCbor(b))
  )
  f.lengths.sort()
  f.fields.sort()
  f

# Plan construction -----------------------------------------------------------------

func outcomes(test: PlanTest, f: Facts, field: string): seq[(Outcome, Obs)] =
  var res: seq[(Outcome, Obs)]
  case test
  of ptMajorType:
    for m in 0'u8 .. 7'u8:
      res.add((Outcome(kind: ocMajor, major: m), Obs(kind: obMajor, major: m)))
  of ptScalarLiteral:
    for l in f.literals:
      res.add((Outcome(kind: ocLiteral, literal: l), Obs(kind: obScalarIs, literal: l)))
    res.add((Outcome(kind: ocOther), Obs(kind: obScalarOther, literals: f.literals)))
    res.add((Outcome(kind: ocNotApplicable), Obs(kind: obNonScalar)))
  of ptTupleLength:
    for n in f.lengths:
      res.add((Outcome(kind: ocLength, length: n), Obs(kind: obLength, length: n)))
    res.add((Outcome(kind: ocOther), Obs(kind: obLengthOther, lengths: f.lengths)))
    res.add((Outcome(kind: ocNotApplicable), Obs(kind: obNonArray)))
  of ptFieldLiteral:
    res.add((Outcome(kind: ocAbsent), Obs(kind: obFieldAbsent, field: field)))
    for l in f.literals:
      res.add(
        (
          Outcome(kind: ocLiteral, literal: l),
          Obs(kind: obFieldIs, field: field, literal: l),
        )
      )
    res.add(
      (
        Outcome(kind: ocOther),
        Obs(kind: obFieldOther, field: field, literals: f.literals),
      )
    )
    res.add((Outcome(kind: ocNotApplicable), Obs(kind: obNonMap)))
  of ptFieldPresence:
    res.add((Outcome(kind: ocPresent), Obs(kind: obFieldPresent, field: field)))
    res.add((Outcome(kind: ocAbsent), Obs(kind: obFieldAbsent, field: field)))
    res.add((Outcome(kind: ocNotApplicable), Obs(kind: obNonMap)))
  res

func plan(
    p: var Planner, doc: int, arms: seq[SchemaNode], cands: seq[int]
): Opt[SelectionPlan] =
  if cands.len == 1:
    return Opt.some(SelectionPlan(leaf: true, arm: cands[0]))
  let top = p.facts(doc, arms, cands)
  var tests: seq[(PlanTest, string)] =
    @[(ptMajorType, ""), (ptScalarLiteral, ""), (ptTupleLength, "")]
  for f in top.fields:
    tests.add((ptFieldLiteral, f))
  for f in top.fields:
    tests.add((ptFieldPresence, f))
  for (test, field) in tests:
    let f =
      if test == ptFieldLiteral:
        p.facts(doc, arms, cands, field)
      else:
        top
    var split: seq[(Outcome, seq[int])]
    var progress = true
    for (outcome, obs) in outcomes(test, f, field):
      var kept: seq[int]
      for i in cands:
        if p.accepts(doc, arms[i], obs):
          kept.add(i)
      if kept.len == cands.len:
        progress = false
        break
      split.add((outcome, kept))
    if not progress:
      continue
    var node = SelectionPlan(leaf: false, test: test, field: field)
    for (outcome, kept) in split:
      if kept.len == 0:
        node.branches.add((outcome, SelectionPlan(nil)))
      else:
        let child = p.plan(doc, arms, kept)
        if child.isNone:
          return Opt.none(SelectionPlan)
        node.branches.add((outcome, child.get))
    return Opt.some(node)
  Opt.none(SelectionPlan)

func selectionPlan*(s: SchemaSet, doc: int, n: SchemaNode): Opt[SelectionPlan] =
  ## [SPEC COMMITMENT §3.1] The structural selection plan of the choice node `n`
  ## of `s.docs[doc]`; none when no plan separates its arms (the choice is invalid).
  doAssert n.kind == snChoice
  var p = Planner(set: addr s)
  var all: seq[int]
  for i in 0 ..< n.arms.len:
    all.add(i)
  p.plan(doc, n.arms, all)

# Selection -------------------------------------------------------------------------

func observe(test: PlanTest, field: string, v: CborValue, o: Outcome): bool =
  ## Whether the decoded value `v` falls in outcome `o` of `test`.
  case test
  of ptMajorType:
    o.kind == ocMajor and majorOf(v) == o.major
  of ptScalarLiteral:
    case o.kind
    of ocLiteral:
      v.isScalar and key(v) == key(o.literal)
    of ocNotApplicable:
      not v.isScalar
    else:
      v.isScalar
  of ptTupleLength:
    case o.kind
    of ocLength:
      v.kind == ckArray and uint64(v.items.len) == o.length
    of ocNotApplicable:
      v.kind != ckArray
    else:
      v.kind == ckArray
  of ptFieldLiteral, ptFieldPresence:
    if v.kind != ckMap:
      return o.kind == ocNotApplicable
    var value: CborValue = nil
    for (k, x) in v.entries:
      if k.kind == ckText and k.text == field:
        value = x
    case o.kind
    of ocAbsent:
      value.isNil
    of ocPresent, ocOther:
      not value.isNil
    of ocLiteral:
      not value.isNil and key(value) == key(o.literal)
    else:
      false

func select*(plan: SelectionPlan, v: CborValue): Opt[int] =
  ## [SPEC COMMITMENT §3.1] The one candidate arm the plan leads `v` to, if any.
  ## The caller then validates all of `v` against that arm.
  var node = plan
  while not node.leaf:
    # The outcomes partition all values: `other` is what no listed literal or
    # length takes.
    var
      found = false
      next, other: SelectionPlan
    for (o, child) in node.branches:
      if o.kind == ocOther:
        other = child
      elif observe(node.test, node.field, v, o):
        next = child
        found = true
        break
    if not found and observe(node.test, node.field, v, Outcome(kind: ocOther)):
      next = other
    if next.isNil:
      return Opt.none(int)
    node = next
  Opt.some(node.arm)

# Validation ------------------------------------------------------------------------

func fieldValue(v: CborValue, name: string): CborValue =
  for (k, x) in v.entries:
    if k.kind == ckText and k.text == name:
      return x
  nil

type ValidateFrame = object ## A map, list or tuple whose members are being validated.
  doc: int
  n: SchemaNode
  v: CborValue
  depth: int ## the maps and arrays above `v`
  next: int ## the next schema field or array element
  member: bool ## entered as a member: its segment is the last one on the path

type Entered = enum
  eFailed ## the value is invalid here
  eValid ## a scalar that is valid
  ePushed ## a container whose frame was pushed

func enterValidate(
    s: SchemaSet,
    stack: var seq[ValidateFrame],
    doc: int,
    n: SchemaNode,
    v: CborValue,
    depth: int,
    member: bool,
    path: var seq[CborValue],
): Entered =
  ## Follows references and choice arms from `n`, then validates a scalar or
  ## checks a container's own shape and pushes its frame.
  if v.isNil:
    return eFailed
  var
    doc = doc
    n = n
    followed: seq[SchemaNode] # since the last container, to refuse a cycle
  while n.kind in {snChoice, snLocalRef, snImportedRef}:
    if followed.anyIt(cast[pointer](it) == cast[pointer](n)):
      return eFailed # references and arms that cycle without a container
    followed.add(n)
    if n.kind == snChoice:
      let plan = s.selectionPlan(doc, n)
      if plan.isNone:
        return eFailed
      let arm = plan.get.select(v)
      if arm.isNone:
        return eFailed
      n = n.arms[arm.get]
    else:
      let t = s.resolve(doc, n)
      if t.isNone:
        return eFailed
      doc = t.get[0]
      n = t.get[1].body
  if n.kind in {snMap, snList, snTuple} and depth >= DefaultMaxDepth:
    return eFailed
  case n.kind
  of snPrimitive:
    if n.primitiveAccepts(v): eValid else: eFailed
  of snLiteral:
    if v.isScalar and key(literalValue(n.literal)) == key(v): eValid else: eFailed
  of snMap:
    if v.kind != ckMap:
      return eFailed
    for (k, _) in v.entries:
      if k.kind != ckText or not n.fields.anyIt(it.name == k.text):
        path.add(k)
        return eFailed
    stack.add(ValidateFrame(doc: doc, n: n, v: v, depth: depth, member: member))
    ePushed
  of snList:
    if v.kind != ckArray:
      return eFailed
    stack.add(ValidateFrame(doc: doc, n: n, v: v, depth: depth, member: member))
    ePushed
  of snTuple:
    if v.kind != ckArray or v.items.len != n.items.len:
      return eFailed
    stack.add(ValidateFrame(doc: doc, n: n, v: v, depth: depth, member: member))
    ePushed
  of snChoice, snLocalRef, snImportedRef:
    raiseAssert "followed above"

func validateAt(
    s: SchemaSet,
    doc: int,
    n: SchemaNode,
    v: CborValue,
    depth: int,
    path: var seq[CborValue],
): bool =
  ## As `validates`; on failure `path` locates the first offending item from the
  ## value's root: a text key for a map entry, an index for an array element.
  ##
  ## `depth` counts the maps and arrays above `v`; references and choice arms add
  ## no level. Members are validated depth first in order, with the frames on the
  ## heap, so the native stack does not grow with the payload depth and every
  ## depth up to `DefaultMaxDepth` is supported on any thread
  ## [SPEC INTERFACE §4.5.1] (DECISIONS I51).
  var stack: seq[ValidateFrame]
  if s.enterValidate(stack, doc, n, v, depth, false, path) == eFailed:
    return false
  while stack.len > 0:
    let t = stack.high
    let (d, c, cv, i) = (stack[t].doc, stack[t].n, stack[t].v, stack[t].next)
    var
      found = false
      child: SchemaNode
      x: CborValue
    case c.kind
    of snMap:
      # The next present field in schema order; a required one must be present.
      var j = i
      while j < c.fields.len and x.isNil:
        x = cv.fieldValue(c.fields[j].name)
        if x.isNil and not c.fields[j].optional:
          return false
        inc j
      stack[t].next = j
      if not x.isNil:
        found = true
        child = c.fields[j - 1].node
        path.add(cbor(c.fields[j - 1].name))
    of snList:
      if i < cv.items.len:
        found = true
        (child, x) = (c.element, cv.items[i])
        path.add(cbor(uint64(i)))
      stack[t].next = i + 1
    of snTuple:
      if i < cv.items.len:
        found = true
        (child, x) = (c.items[i], cv.items[i])
        path.add(cbor(uint64(i)))
      stack[t].next = i + 1
    else:
      raiseAssert "frames hold maps, lists and tuples"
    if not found:
      # Every member is valid: the container is, and its own segment goes.
      if stack.pop().member:
        discard path.pop()
      continue
    case s.enterValidate(stack, d, child, x, stack[t].depth + 1, true, path)
    of eFailed:
      return false
    of eValid:
      discard path.pop()
    of ePushed:
      discard
  true

func validatePath*(
    s: SchemaSet, doc: int, n: SchemaNode, v: CborValue
): Result[void, seq[CborValue]] =
  ## Whether `v` is valid under `n` of `s.docs[doc]`; the error is the path to the
  ## first offending item (INTERFACE §5.1 `invalid_params_path_segment`s).
  var path: seq[CborValue]
  if s.validateAt(doc, n, v, 0, path):
    ok()
  else:
    err(path)

func validates*(s: SchemaSet, doc: int, n: SchemaNode, v: CborValue, depth = 0): bool =
  ## Whether the decoded value `v` is valid under the schema node `n` of
  ## `s.docs[doc]`. Maps are closed; a choice selects its one candidate arm by its
  ## structural selection plan and then validates the whole value against that arm
  ## [SPEC COMMITMENT §3.1]. Plans are rebuilt per call [IMPL]; a decoder that
  ## validates many values caches them.
  var path: seq[CborValue]
  s.validateAt(doc, n, v, depth, path)

# Every choice in a document ----------------------------------------------------------

func walk(
    s: SchemaSet, n: SchemaNode, path: var seq[PathSegment], at: string
): Result[void, string] =
  case n.kind
  of snMap:
    for f in n.fields:
      path.add(PathSegment(kind: psField, field: f.name))
      ?s.walk(f.node, path, at)
      path.setLen(path.len - 1)
  of snList:
    path.add(PathSegment(kind: psListElement))
    ?s.walk(n.element, path, at)
    path.setLen(path.len - 1)
  of snTuple:
    for i, x in n.items:
      path.add(PathSegment(kind: psTuplePosition, index: uint64(i)))
      ?s.walk(x, path, at)
      path.setLen(path.len - 1)
  of snChoice:
    if s.selectionPlan(0, n).isNone:
      return err(
        "no structural selection plan separates the choice at " & at & " " &
          toDiag(toCbor(path))
      )
    for i, x in n.arms:
      path.add(PathSegment(kind: psChoiceArm, index: uint64(i)))
      ?s.walk(x, path, at)
      path.setLen(path.len - 1)
  else:
    discard
  ok()

func checkImports(s: SchemaSet, n: SchemaNode, at: string): Result[void, string] =
  case n.kind
  of snImportedRef:
    if s.resolveImport(n.imported).isNone:
      return err(at & " imports a root pair that names no supplied named type")
  of snMap:
    for f in n.fields:
      ?s.checkImports(f.node, at)
  of snList:
    ?s.checkImports(n.element, at)
  of snTuple:
    for x in n.items:
      ?s.checkImports(x, at)
  of snChoice:
    for x in n.arms:
      ?s.checkImports(x, at)
  else:
    discard
  ok()

func checkImports*(s: SchemaSet): Result[void, string] =
  ## [SPEC COMMITMENT §9.1] Every imported reference in `s.docs[0]` resolves to
  ## exactly one named type of a supplied document.
  for d in s.docs[0].declarations:
    if d.kind != dkMethod:
      ?s.checkImports(d.body, d.name)
  ok()

func checkChoices*(s: SchemaSet): Result[void, string] =
  ## [SPEC COMMITMENT §3.1] Every choice node in `s.docs[0]` has a selection plan.
  for d in s.docs[0].declarations:
    if d.kind != dkMethod:
      var path: seq[PathSegment]
      ?s.walk(d.body, path, d.name)
  ok()
