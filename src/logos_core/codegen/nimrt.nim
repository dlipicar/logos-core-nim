## Runtime support for lcn-gen's Nim output [D29].
##
## A generated module embeds the schema documents it was generated from and
## loads them once per thread (`base/perthread`), as an accepted construction
## input set. Its decoders check a
## value against the declaration first (INTERFACE §4.5: deterministic CBOR, then
## the schema) and only then convert it; choice arms are picked by the
## structural selection plan (COMMITMENT §3.1), never by trial.

{.push raises: [].}

import std/[sequtils, strutils, tables]
import ../cbor
import ../commitment
import ../hash
import ../iface/accept
import ../base/perthread

export cbor, results, sequtils, perthread

type
  GeneratedSchema* = object
    sets: seq[SchemaSet] ## one per document, each with that document first
    bodies: Table[string, (int, SchemaNode)] ## declaration -> (document, body)
    plans: Table[string, SelectionPlan] ## `<declaration>#<path>` -> plan

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
    let plan = selectionPlan(g.sets[doc], 0, n)
    doAssert plan.isSome, "an accepted choice has a selection plan"
    g.plans[choiceKey(owner, path)] = plan.get
    for i, a in n.arms:
      g.addPlans(doc, owner, path & ("arm_" & $i), a)
  else:
    discard

proc add(g: var GeneratedSchema, set: SchemaSet) =
  let doc = g.sets.len
  g.sets.add(set)
  for d in set.docs[0].declarations:
    if d.kind != dkMethod:
      g.bodies[d.name] = (doc, d.body)
      g.addPlans(doc, d.name, @[], d.body)

proc loadSchema*(
    primary: string, interfaces, supporting: openArray[string], system = false
): GeneratedSchema =
  ## The accepted set a generated module was made from. A failure means the
  ## module no longer matches this library's acceptance rules: regenerate it.
  let s =
    acceptContractSet(primary, interfaces, supporting, AcceptOptions(system: system))
  doAssert s.isOk, "generated module: its schema set is not accepted: " & s.error
  var g = GeneratedSchema()
  for c in s.get.documents:
    g.add(schemaSetFor(c.model, s.get.context))
  g

proc loadCommonSchema*(): GeneratedSchema =
  ## The pinned common schema (INTERFACE §5.1).
  var g = GeneratedSchema()
  g.add(schemaSet(pinnedContext().commonModel))
  g

proc check*(
    g: GeneratedSchema, declaration: string, v: CborValue
): Result[void, string] =
  ## [SPEC INTERFACE §4.5] `v` is a value of the declaration.
  let (doc, body) = g.bodies.getOrDefault(declaration, (-1, nil))
  if doc < 0:
    return err(declaration & " is not declared")
  g.sets[doc].validatePath(0, body, v).isOkOr:
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
  let r = ?g.sets[doc].normalize(0, declaration, v)
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
  ## Logos deterministic CBOR of a value the declaration accepts.
  ?g.check(declaration, v)
  ok(encodeCbor(v))

proc decodeChecked*(
    g: GeneratedSchema, declaration: string, data: openArray[byte]
): Result[CborValue, string] =
  ## [SPEC INTERFACE §4.4, §4.5] One deterministic-CBOR item, then the schema.
  let v = decodeCbor(data).valueOr:
    return err($error)
  ?g.check(declaration, v)
  ok(v)

func boxed*[T](x: T): ref T =
  ## A recursive by-value edge's value on the heap.
  let r = new(T)
  r[] = x
  r

func asInt64*(v: CborValue): int64 =
  ## A checked signed integer.
  v.getInt64.get

func asBool*(v: CborValue): bool =
  ## A checked boolean.
  v.getBool.get
