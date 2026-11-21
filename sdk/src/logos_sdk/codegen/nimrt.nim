## Runtime support for lcn-gen's Nim output [D29].
##
## A generated module embeds the schema documents it was generated from and
## loads them once per thread (`base/perthread`), as an accepted construction
## input set. Its decoders check a
## value against the declaration first (INTERFACE §4.5: deterministic CBOR, then
## the schema) and only then convert it; choice arms are picked by the
## structural selection plan (COMMITMENT §3.1), never by trial. Loading builds
## the plan of every choice the documents' values reach, once, with the set it
## belongs to (`choice.PlannedSet`, DECISIONS I101): a check selects arms by
## those plans and still validates the whole value.
##
## Marked payloads (INTERFACE §1.2.1, l.380-386; DECISIONS G276, G278): for a
## request or response declaration that `_sensitive` marks, `check` reports a
## fixed message without the path, `encodeChecked` and `decodeChecked` run in
## the marked scope and wipe a rejected tree, and the generated codecs wipe their
## intermediate trees. `wipeTyped` erases a generated value. Unmarked
## declarations work as before.

{.push raises: [].}

import std/[sequtils, sets, strutils, tables]
import ../cbor
import ../commitment
import ../hash
import ../iface/accept
import ../base/[perthread, wipe]

export cbor, results, sequtils, perthread, wipe

type
  GeneratedSchema* = object
    sets: seq[PlannedSet]
      ## one per document, each with that document first, and with the plans
      ## of every choice its values reach (DECISIONS I101)
    bodies: Table[string, (int, SchemaNode)] ## declaration -> (document, body)
    plans: Table[string, SelectionPlan] ## `<declaration>#<path>` -> plan
    marked: HashSet[string]
      ## [SPEC INTERFACE §1.2.1] the request and response declarations
      ## `_sensitive` marks

  EmptyTuple* = object ## [SPEC INTERFACE §2.3] the schema `[]`

func choiceKey*(declaration: string, path: openArray[string]): string =
  ## The key generated code names a choice node by: its owner and its C path
  ## components (`field`, `list_item`, `tuple_<i>`, `arm_<i>`).
  var k = declaration & "#"
  for i, p in path:
    if i > 0:
      k.add('/')
    k.add(p)
  k

proc addPlans(
    g: var GeneratedSchema, doc: int, owner: string, path: seq[string], n: SchemaNode
) =
  case n.kind
  of snMap:
    for f in n.fields:
      g.addPlans(doc, owner, path & f.name, f.node)
  of snList:
    g.addPlans(doc, owner, path & "list_item", n.element)
  of snTuple:
    for i, item in n.items:
      g.addPlans(doc, owner, path & ("tuple_" & $i), item)
  of snChoice:
    let plan = g.sets[doc].planOf(0, n)
    doAssert plan.isSome, "an accepted choice has a selection plan"
    g.plans[choiceKey(owner, path)] = plan.get
    for i, a in n.arms:
      g.addPlans(doc, owner, path & ("arm_" & $i), a)
  else:
    discard

proc add(g: var GeneratedSchema, set: SchemaSet) =
  let doc = g.sets.len
  g.sets.add(planned(set))
  for d in set.docs[0].declarations:
    if d.kind != dkMethod:
      g.bodies[d.name] = (doc, d.body)
      g.addPlans(doc, d.name, @[], d.body)
  for name in sensitiveDeclarations(set.docs[0]):
    g.marked.incl(name)

proc loadSchemaSet*(s: ContractSet): GeneratedSchema =
  ## The declarations of an accepted set, for value work (a module's
  ## configuration schema, DECISIONS I87).
  var g = GeneratedSchema()
  for c in s.documents:
    g.add(schemaSetFor(c.model, s.context))
  g

proc loadSchema*(
    primary: string, interfaces, supporting: openArray[string], system = false
): GeneratedSchema =
  ## The accepted set a generated module was made from. A failure means the
  ## module no longer matches this library's acceptance rules: regenerate it.
  let s =
    acceptContractSet(primary, interfaces, supporting, AcceptOptions(system: system))
  doAssert s.isOk, "generated module: its schema set is not accepted: " & s.error
  loadSchemaSet(s.get)

proc loadBindingSchema*(
    module: string, interfaces, supporting: openArray[string], system = false
): GeneratedSchema =
  ## [DECISIONS G339] The declarations of an interface-only module binding
  ## (INTERFACE §2, l.2833-2835): no primary document, `interfaces` as its
  ## implemented set. A failure means the module no longer matches this
  ## library's acceptance rules: regenerate it.
  let b = acceptBinding(
    module, Opt.none(string), interfaces, supporting, AcceptOptions(system: system)
  )
  doAssert b.isOk, "generated module: its binding is not accepted: " & b.error
  let ctx = b.get.context
  var g = GeneratedSchema()
  for c in b.get.documents:
    g.add(schemaSetFor(c.model, ctx))
  g

proc loadCommonSchema*(): GeneratedSchema =
  ## The pinned common schema (INTERFACE §5.1).
  var g = GeneratedSchema()
  g.add(schemaSet(pinnedContext().commonModel))
  g

func marks*(g: GeneratedSchema, declaration: string): bool =
  ## [SPEC INTERFACE §1.2.1] Whether `_sensitive` marks the declaration.
  declaration in g.marked

proc check*(
    g: GeneratedSchema, declaration: string, v: CborValue
): Result[void, string] =
  ## [SPEC INTERFACE §4.5] `v` is a value of the declaration. [DECISIONS G278]
  ## For a marked declaration the message is fixed: no path, which may hold
  ## the value's own keys.
  let (doc, body) = g.bodies.getOrDefault(declaration, (-1, nil))
  if doc < 0:
    return err(declaration & " is not declared")
  # [IMPL] (DECISIONS I101) Over the plans built at load: the whole value is
  # validated, as by `SchemaSet`'s `validatePath`, without replanning a choice.
  g.sets[doc].validatePath(0, body, v).isOkOr:
    if g.marks(declaration):
      return err("not a " & declaration & " value")
    return err(
      "not a " & declaration & " value at [" & error.mapIt(toDiag(it)).join(", ") & "]"
    )
  ok()

func declares*(g: GeneratedSchema, declaration: string): bool =
  declaration in g.bodies

proc checkPath*(
    g: GeneratedSchema, declaration: string, v: CborValue
): Result[void, seq[CborValue]] =
  ## [SPEC INTERFACE §4.5, §5.1] `check` with the path from `v` to the first
  ## item the schema rejects, for `logos.invalid_params_detail`.
  let (doc, body) = g.bodies.getOrDefault(declaration, (-1, nil))
  if doc < 0:
    return err(newSeq[CborValue]())
  g.sets[doc].validatePath(0, body, v)

proc commitment*(
    g: GeneratedSchema, declaration: string, v: CborValue
): Result[(Digest, Digest), string] =
  ## [SPEC TRANSPORT §4.1; RUNTIME l.3747] The payload commitment of a checked
  ## value: the declaration's subtree root and the value root.
  let (doc, _) = g.bodies.getOrDefault(declaration, (-1, nil))
  if doc < 0:
    return err(declaration & " is not declared")
  let r = ?g.sets[doc].schemaSet.normalize(0, declaration, v)
  let root = ?valueRoot(r)
  ok((r.subtreeRoot, root))

proc arm*(g: GeneratedSchema, key: string, v: CborValue): int =
  ## The arm a checked value takes at the choice `key`.
  let plan = g.plans.getOrDefault(key)
  doAssert not plan.isNil, "no choice " & key
  let i = plan.select(v)
  doAssert i.isSome, "a checked value selects an arm of " & key
  i.get

proc encodeChecked*(
    g: GeneratedSchema, declaration: string, v: CborValue
): Result[seq[byte], string] =
  ## Logos deterministic CBOR of a value the declaration accepts. `v` stays
  ## the caller's: the generated `encode` of a marked declaration wipes it.
  markedScope(g.marks(declaration)):
    g.check(declaration, v).isOkOr:
      return err(error)
    result = ok(encodeCbor(v))

proc decodeChecked*(
    g: GeneratedSchema, declaration: string, data: openArray[byte]
): Result[CborValue, string] =
  ## [SPEC INTERFACE §4.4, §4.5] One deterministic-CBOR item, then the schema.
  ## A marked value the schema rejects is wiped (DECISIONS G276); one it
  ## accepts is the caller's.
  let marked = g.marks(declaration)
  markedScope(marked):
    let v = decodeCbor(data).valueOr:
      return err($error)
    g.check(declaration, v).isOkOr:
      if marked:
        wipe(v)
      return err(error)
    result = ok(v)

func boxed*[T](x: T): ref T =
  ## A recursive by-value edge's value on the heap.
  let r = new(T)
  r[] = x
  r

# Codec steps (DECISIONS I79) -------------------------------------------------------
#
# A generated codec converts one object (or one alias with a container body) per
# step. It stores what it can at once and makes room for each nested object: an
# entry, item or field it hands to a later step as a task. Every container is
# allocated at its final size before any task points into it, and nothing a task
# points to moves, so tasks may run in any order; the drivers run them from a
# heap list, and the native stack does not grow with the nesting.

type
  EncStep* = proc(w: var EncWork, src: pointer, dst: ptr CborValue) {.
    nimcall, gcsafe, raises: []
  .} ## Stores the CBOR value of the Nim value at `src` into `dst`.

  EncWork* = object ## The encoding tasks not run yet.
    tasks: seq[(EncStep, pointer, ptr CborValue)]

  DecStep* =
    proc(w: var DecWork, v: CborValue, dst: pointer) {.nimcall, gcsafe, raises: [].}
    ## Stores the Nim value of the checked value `v` into `dst`.

  DecWork* = object ## The decoding tasks not run yet.
    tasks: seq[(DecStep, CborValue, pointer)]

proc later*(w: var EncWork, step: EncStep, src: pointer, dst: ptr CborValue) =
  w.tasks.add((step, src, dst))

proc later*(w: var DecWork, step: DecStep, v: CborValue, dst: pointer) =
  w.tasks.add((step, v, dst))

proc runEnc*(step: EncStep, src: pointer): CborValue =
  ## The CBOR value of the Nim value at `src`.
  var w: EncWork
  var root: CborValue
  step(w, src, addr root)
  while w.tasks.len > 0:
    let (s, x, d) = w.tasks.pop()
    s(w, x, d)
  root

proc runDec*(step: DecStep, v: CborValue, dst: pointer) =
  ## Stores the Nim value of the checked value `v` into `dst`.
  var w: DecWork
  step(w, v, dst)
  while w.tasks.len > 0:
    let (s, x, d) = w.tasks.pop()
    s(w, x, d)

# Erasure of generated values (DECISIONS G276) -----------------------------------
#
# `wipeTyped` zeroes a generated value in place: its texts and byte strings to
# their capacity, its numbers, and every element and field below it, then
# empties its lists. Like the codecs it keeps its frames on the heap (I79), so
# a deep value costs no native stack. A `ref` (a recursive edge) is followed
# only while this value holds the sole reference (orc and arc): a target the
# module also keeps is the module's own copy and stays intact (INTERFACE
# l.388, l.399). Under refc no reference count is exact, so recursive edges
# are not followed (a non-claim, CONFORMANCE). A case object's discriminator
# is left as it is.

type
  WipeStep = proc(w: var WipeWork, p: pointer) {.nimcall, gcsafe, raises: [].}

  WipeWork = object ## The parts not wiped yet.
    tasks: seq[(WipeStep, pointer)]

proc wipeValue[T](w: var WipeWork, x: var T) {.gcsafe, raises: [].}

proc wipeAt[T](w: var WipeWork, p: pointer) {.nimcall, gcsafe, raises: [].} =
  wipeValue(w, cast[ptr T](p)[])

proc emptyAt[T](w: var WipeWork, p: pointer) {.nimcall, gcsafe, raises: [].} =
  # Runs after every element below it: the tasks run last in, first out.
  cast[ptr seq[T]](p)[].setLen(0)

proc zeroScalar[T](x: var T) =
  x = default(T)

proc wipeValue[T](w: var WipeWork, x: var T) =
  when T is string:
    wipe(x)
  elif T is seq[SomeNumber] or T is seq[bool] or T is seq[char]:
    wipe(x)
  elif T is CborValue:
    wipe(x)
  elif T is seq:
    w.tasks.add((WipeStep(emptyAt[typeof(x[0])]), pointer(addr x)))
    for e in x.mitems:
      w.tasks.add((WipeStep(wipeAt[typeof(e)]), pointer(addr e)))
  elif T is Opt:
    if x.isSome:
      wipeValue(w, x.get)
  elif T is ref:
    when defined(gcDestructors):
      if not x.isNil and isUniqueRef(x):
        w.tasks.add((WipeStep(wipeAt[typeof(x[])]), pointer(addr x[])))
  elif T is object or T is tuple:
    for f in fields(x):
      when f is SomeNumber or f is enum or f is bool or f is char:
        # A discriminator is not assignable this way: it is skipped.
        when compiles(zeroScalar(f)):
          zeroScalar(f)
      else:
        wipeValue(w, f)
  elif T is SomeNumber or T is enum or T is bool or T is char:
    x = default(T)
  elif T is array:
    for e in x.mitems:
      wipeValue(w, e)

proc wipeTyped*[T](x: var T) =
  ## [SPEC INTERFACE l.380-386; DECISIONS G276] Erases a generated value: the
  ## generated dispatch and call helpers wipe the typed request and response
  ## of a marked method once they are done with them.
  var w: WipeWork
  wipeValue(w, x)
  while w.tasks.len > 0:
    let (s, p) = w.tasks.pop()
    s(w, p)

func asInt64*(v: CborValue): int64 =
  ## A checked signed integer.
  v.getInt64.get

func asBool*(v: CborValue): bool =
  ## A checked boolean.
  v.getBool.get
