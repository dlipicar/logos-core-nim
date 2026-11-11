## Resolution and canonicalization (cdCDDLe §6, §7): source rules to the
## canonical model. Errors come in stage order: syntax and unsupported constructs
## (in source order), then resolution, then canonical-rule violations.

{.push raises: [].}

import std/[algorithm, sets]
import ./[model, syntax]

type Canon = object
  src: string
  defined: HashSet[string]
  scope: HashSet[string]

func fail(c: Canon, pos: int, class: CddlErrorClass, msg: string): CddlError =
  errorAt(c.src, pos, class, msg)

func checkNames(c: Canon, n: SrcNode): Result[void, CddlError] =
  ## Every name resolves: a §5.1 primitive, `true`/`false`, a rule of this
  ## document, or a name of the external scope [G14].
  case n.kind
  of skName:
    if n.name.parsePrimitive.isSome or n.name in ["true", "false"]:
      return ok()
    if n.name.isPreludeName:
      return err(
        c.fail(
          n.pos,
          ecUnsupported,
          "the RFC 8610 prelude type " & n.name & " is outside the cdCDDLe §5.1 subset",
        )
      )
    if n.name notin c.defined and n.name notin c.scope:
      return err(c.fail(n.pos, ecResolution, "undefined name " & n.name))
  of skLiteral:
    discard
  of skArray, skMap:
    for m in n.members:
      ?c.checkNames(m.typ)
  of skChoice:
    for a in n.alternatives:
      ?c.checkNames(a)
  of skRange:
    ?c.checkNames(n.low)
    ?c.checkNames(n.high)
  of skSize:
    ?c.checkNames(n.target)
    ?c.checkNames(n.controller)
  of skParen:
    ?c.checkNames(n.inner)
  ok()

func integerOf(n: SrcNode): Literal =
  let u = unwrap(n)
  doAssert u.kind == skLiteral and u.literal.isIntegerLiteral
  u.literal

func literalType(l: Literal): CddlType =
  CddlType(kind: tkLiteral, literal: l)

proc build(c: Canon, n: SrcNode): Result[CddlType, CddlError] =
  case n.kind
  of skParen:
    c.build(n.inner)
  of skName:
    let prim = n.name.parsePrimitive
    if prim.isSome:
      ok(CddlType(kind: tkPrimitive, primitive: prim.get))
    elif n.name == "true" or n.name == "false":
      ok(literalType(boolLiteral(n.name == "true")))
    else:
      ok(CddlType(kind: tkReference, name: n.name))
  of skLiteral:
    ok(literalType(n.literal))
  of skArray:
    var node = CddlType(kind: tkArray)
    for m in n.members:
      let typ = ?c.build(m.typ)
      node.members.add(Member(typ: typ, occurrence: m.occurrence))
    ok(node)
  of skMap:
    var
      node = CddlType(kind: tkMap)
      seen: HashSet[string]
    for m in n.members:
      let key = m.key.get
      if seen.containsOrIncl(key):
        return err(c.fail(m.pos, ecCanonical, "duplicate map key " & key))
      let typ = ?c.build(m.typ)
      node.members.add(Member(key: m.key, typ: typ, occurrence: m.occurrence))
    node.members.sort(
      proc(a, b: Member): int =
        cmp(a.key.get, b.key.get)
    )
    ok(node)
  of skChoice:
    var node = CddlType(kind: tkChoice)
    for a in n.alternatives:
      let t = ?c.build(a)
      if t.kind == tkChoice:
        node.alternatives.add(t.alternatives)
      else:
        node.alternatives.add(t)
    ok(node)
  of skRange:
    let
      low = integerOf(n.low)
      high = integerOf(n.high)
      order = cmpInteger(low, high)
    if order > 0:
      return
        err(c.fail(n.pos, ecUnsupported, "range lower bound exceeds its upper bound"))
    if order == 0:
      return ok(literalType(low))
    ok(CddlType(kind: tkRange, low: low, high: high))
  of skSize:
    let target = unwrap(n.target).name.parsePrimitive.get
    if target == pBool:
      return
        err(c.fail(n.pos, ecCanonical, "the .size target must be uint, tstr or bstr"))
    let ctl = unwrap(n.controller)
    var controller: CddlType
    if ctl.kind == skLiteral:
      if ctl.literal.kind != lkUint:
        return
          err(c.fail(ctl.pos, ecCanonical, "the .size controller must be non-negative"))
      controller = literalType(ctl.literal)
    else:
      let
        low = integerOf(ctl.low)
        high = integerOf(ctl.high)
      if low.kind != lkUint or high.kind != lkUint:
        return err(
          c.fail(ctl.pos, ecCanonical, "both .size range bounds must be non-negative")
        )
      let order = cmpInteger(low, high)
      if order > 0:
        return err(
          c.fail(ctl.pos, ecUnsupported, "range lower bound exceeds its upper bound")
        )
      controller =
        if order == 0:
          literalType(low)
        else:
          CddlType(kind: tkRange, low: low, high: high)
    ok(CddlType(kind: tkSize, target: target, controller: controller))

proc canonicalize*(
    src: string, rules: openArray[SrcRule], scope: openArray[string] = []
): Result[CddlDocument, CddlError] =
  ## Resolves and canonicalizes parsed rules. `scope` names rules defined outside
  ## this document (G14); references to them stay reference nodes.
  var c = Canon(src: src)
  for name in scope:
    if not name.isIdentifier or name.isPreludeName or name[0] == '$':
      return err(cddlError(ecResolution, "invalid external scope name " & name))
    c.scope.incl(name)
  for r in rules:
    if r.name.isPreludeName:
      return err(
        c.fail(
          r.pos, ecResolution, r.name & " is an RFC 8610 prelude name (cdCDDLe §6)"
        )
      )
    if r.name in c.scope:
      return err(
        c.fail(r.pos, ecResolution, r.name & " is also defined in the external scope")
      )
    if c.defined.containsOrIncl(r.name):
      return err(c.fail(r.pos, ecResolution, "duplicate rule " & r.name))
  for r in rules:
    ?c.checkNames(r.typ)
  var doc: CddlDocument
  for r in rules:
    let typ = ?c.build(r.typ)
    doc.rules.add(Rule(name: r.name, typ: typ))
  doc.rules.sort(
    proc(a, b: Rule): int =
      cmp(a.name, b.name)
  )
  ok(doc)

proc parseCddl*(
    source: string, scope: openArray[string] = []
): Result[CddlDocument, CddlError] =
  ## Source text to the canonical model (cdCDDLe §5 parse, resolve, canonicalize).
  let rules = ?parseSource(source)
  canonicalize(source, rules, scope)
