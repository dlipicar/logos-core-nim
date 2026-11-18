## INTERFACE §3: the reverse mapper, from an explicit set of C headers to the
## Logos canonical schema model, CDDL and the module binding.
##
## [SPEC INTERFACE §3, §3.2-§3.8] `reconstruct` works in five steps:
##
## 1. **Classify.** Every item of every supplied body (`cinput`, `cparse`) is a
##    frame item, a constraint typedef, an item of one namespace group (by the
##    C namespace component its identifier decodes to, §2.1 l.791-795) or an
##    item of one module family (`logos_<module-C>_…`). Anything else is
##    rejected (l.2224).
## 2. **Select.** `--module` or `--subject`, else the only module family, else
##    the only group (l.2282-2286). The reconstruction input is the selecting
##    header and its include closure; a group reached through a contract-header
##    include is supplied as a dependency (l.2325, l.2385), and a group merely
##    present is another document (G318).
## 3. **Reconstruct.** Roles come from the role constants or the single-group
##    inference (l.2337-2354). Each group's declarations are rebuilt top-down
##    from aggregate containment and type use (l.2520-2531): a member's type is
##    either the inline stem derived for its exact path, a named declaration, a
##    fixed common name or a scalar, and identifiers are never split below the
##    owner (l.2528).
## 4. **Re-accept.** The documents are emitted as CDDL (`cddl/emit`) and
##    accepted (`accept.acceptContractSet`, `acceptBinding`), which computes the
##    roots; the identity checks, implements order and dependencies are checked
##    against them.
## 5. **Compare.** The forward mapping regenerates `H'` (`cmap.contractHeader`);
##    the input's selected items must equal `H'`'s, modulo the variations G319
##    allows (IF l.642, l.893, l.2634). Then declare-before-use (G319).
##
## Each rejection the specification names has its reason (`creject`). The CDDL
## printed in step 4 is an intermediate in memory: nothing is returned before
## every check has passed (IF l.2941).
##
## [IMPL-DECISION G158, pending] The fixed common types are recognized by the
## names this repository's `logos_types.h` declares (`cmap.commonLayout`).

{.push raises: [].}

import std/[algorithm, sequtils, sets, strutils, tables]
import results
import ../cbor/encode
import ../hash/hashinput
import ../cddl/emit
import ./[accept, cinput, cliteral, cparse]

export cinput, accept

type
  RmapOptions* = object
    module*: string ## reconstruct this runtime module
    subject*: string ## reconstruct the document of this exact namespace
    system*: bool ## the documents may use Logos-reserved names (INTERFACE §1.3)

  RDocument* = object ## One reconstructed document.
    namespace*: string
    role*: SchemaRole
    cddl*: string ## the CDDL text that was accepted
    contract*: Contract

  Reconstruction* = object
    module*: Opt[string] ## a module reconstruction's runtime module name
    primary*: Opt[RDocument] ## the subject document, or the module's primary
    interfaces*: seq[RDocument] ## a module's implemented interfaces, raw root order
    supporting*: seq[RDocument] ## the supporting schemas they use
    schemaSet*: CSchemaSet
    header*: string ## `H'`, the canonical header of the reconstructed set

  Common = ref object
    types: Table[string, string] ## fixed common type name -> qualified name
    predeclared: HashSet[string] ## every `logos_…_t` name `logos_types.h` declares
    constraints: HashSet[string] ## the constraint typedefs `logos_types.h` declares
    lifecycle: Table[string, string] ## `_MODULE_` operation -> signature

  Occ = object ## One namespace group in one header body.
    header: int
    cns, ns: string
    items: seq[CItem]
    guards: seq[CItem]

  HeaderView = object
    occs: OrderedTable[string, Occ]
    modules: OrderedTable[string, seq[CItem]] ## module-C -> its items
    constraints: seq[CItem]

  Role = enum
    roleNone
    roleModule
    roleInterface
    roleSupporting

  Def = object
    item: CItem
    name, tag, family: string

  Mode = enum
    mStruct ## a struct or union member
    mIn ## an input parameter
    mOut ## an output parameter

  RawMember = object
    name: string ## unescaped, without its direction prefix
    ctype: CType
    line: int

  Builder = object
    c: Common
    header: string
    cns, ns: string
    defs: Table[string, Def] ## by typedef name
    aliases: Table[string, CItem]
    kinds: Table[string, CItem]
    literals: Table[string, CItem]
    arms: Table[string, CItem]
    sensitive: seq[CItem]
    fns: seq[CItem]
    used: HashSet[string]
    refs: HashSet[string] ## other namespaces referenced
    localRefs: seq[(string, int)]
    decls: seq[EDeclaration]
    names: HashSet[string]
    halves: HashSet[string] ## request and response declarations
    callable: bool ## a method or an event

  Group = object
    occ: Occ
    role: Role
    doc: EDocument
    refs: HashSet[string]
    callable: bool
    contract: Opt[Contract]
    text: string

const
  Families = ["MAP", "LIST", "TUPLE", "BSTR", "CHOICE", "EVENT"]
  PrimaryPrefix = "LOGOS_PRIMARY_NAMESPACE_"
  InterfacePrefix = "LOGOS_INTERFACE_NAMESPACE_"
  SupportingPrefix = "LOGOS_SUPPORTING_NAMESPACE_"
  ImplementsPrefix = "LOGOS_IMPLEMENTS_"
  SensitivePrefix = "LOGOS_SENSITIVE_"
  LiteralPrefix = "LOGOS_LITERAL_"
  ArmPrefix = "LOGOS_ARM_"
  # [SPEC INTERFACE §2.6 l.1645-1676, §5.2] [IMPL-DECISION G322] The lifecycle
  # family's declarations; parameter names are free, types are exact.
  LifecycleTemplates = """
const char* logos_M_MODULE_name(void);
logos_result_t logos_M_MODULE_init(const logos_module_init_input_t* input, logos_module_context_t** out_context);
logos_result_t logos_M_MODULE_apply_configuration(logos_module_context_t* module, const uint8_t* configuration_cbor, size_t configuration_cbor_len);
void logos_M_MODULE_destroy(logos_module_context_t* module);
const uint8_t* logos_M_MODULE_call_surface(size_t* out_len);
void logos_M_MODULE_free(logos_module_context_t* module, void* ptr);
logos_result_t logos_M_MODULE_dispatch(logos_module_context_t* module, const char* method, const uint8_t* params_cbor, size_t params_len, uint8_t** out_response_cbor, size_t* out_response_len);
const logos_async_provider_api_t* logos_M_MODULE_async_api(void);
"""
  RequiredOps = ["name", "init", "destroy"]
  ProviderOps = ["call_surface", "free", "dispatch"]

# Helpers ---------------------------------------------------------------------------

func fail(reason: RejectReason, header: string, line: int, msg: string): Rejection =
  reject(reason, header, line, msg)

func hasUpper(a: string): bool =
  for c in a:
    if c in {'A' .. 'Z'}:
      return true
  false

func isCapitalized(a: string): bool =
  a.len > 0 and a[0] in {'A' .. 'Z'} and not a[1 ..^ 1].hasUpper

func canonicalDigits(s: string): Opt[uint64] =
  ## A decimal number without leading zeros (except `0`).
  if s.len == 0 or s.len > 19 or (s.len > 1 and s[0] == '0'):
    return Opt.none(uint64)
  var v = 0'u64
  for c in s:
    if c notin {'0' .. '9'}:
      return Opt.none(uint64)
    v = v * 10 + uint64(ord(c) - ord('0'))
  Opt.some(v)

func isPlain(t: CType, base: string): bool =
  t.base == base and not t.isConst and t.pointers == 0 and t.arrayLen == 0 and
    not t.constPtr and not t.ptrToArray

func isPtr(t: CType, base: string, n: int, isConst = false): bool =
  t.base == base and t.isConst == isConst and t.pointers == n and t.arrayLen == 0 and
    not t.constPtr and not t.ptrToArray

func typeStem(name: string): Opt[string] =
  ## `logos_<stem>_t` -> `<stem>`.
  if name.len > 8 and name.startsWith("logos_") and name.endsWith("_t"):
    Opt.some(name[6 ..^ 3])
  else:
    Opt.none(string)

type Stem = object
  cns, owner, rest, ns, local: string

proc splitStem(stem, header: string, line: int): Result[Stem, Rejection] =
  ## [SPEC INTERFACE §2.1 l.791-795] The C namespace component (lowercase atoms
  ## and `NS`), the owner (a capitalized atom and its lowercase atoms) and the
  ## path steps after it, which are compared, never parsed.
  let atoms = stem.split('_')
  var i = 0
  var cnsAtoms: seq[string] = @[]
  while i < atoms.len and not atoms[i].isCapitalized:
    let a = atoms[i]
    if a.len == 0 or (a.hasUpper and a != "NS"):
      return err(fail(rkName, header, line, stem & ": not a canonical C name"))
    cnsAtoms.add(a)
    inc i
  if i == atoms.len or cnsAtoms.len == 0:
    return err(
      fail(rkName, header, line, stem & ": no namespace and owner (INTERFACE §2.1)")
    )
  var ownerAtoms = @[atoms[i]]
  inc i
  while i < atoms.len and atoms[i].len > 0 and not atoms[i].hasUpper:
    ownerAtoms.add(atoms[i])
    inc i
  var s = Stem(cns: cnsAtoms.join("_"), owner: ownerAtoms.join("_"))
  if i < atoms.len:
    s.rest = "_" & atoms[i ..^ 1].join("_")
  let ns = decodeNamespace(s.cns)
  if ns.isErr:
    return err(fail(rkName, header, line, ns.error))
  s.ns = ns.get
  s.local = toLowerAscii(s.owner[0]) & s.owner[1 ..^ 1]
  if not s.local.isSchemaIdentifier:
    return err(fail(rkName, header, line, stem & ": " & s.owner & " is not an owner"))
  ok(s)

func tagFamily(tag: string): (string, string) =
  ## `logos_<stem>_<FAMILY>` -> (stem, family), or ("", "").
  if not tag.startsWith("logos_"):
    return ("", "")
  for f in Families:
    if tag.endsWith("_" & f) and tag.len > 7 + f.len:
      return (tag[6 ..^ (f.len + 2)], f)
  ("", "")

proc unescaped(id, header: string, line: int): Result[string, Rejection] =
  ## [SPEC INTERFACE §2.1, §3.4 l.2499-2502] The keyword escape reversed on a
  ## complete identifier: an unescaped keyword and an unnecessary escape are
  ## both rejected.
  if id in CEscapedIdentifiers:
    return err(fail(rkEscape, header, line, id & " is a keyword and must be escaped"))
  if id.endsWith("_"):
    let base = id[0 ..^ 2]
    if base in CEscapedIdentifiers:
      return ok(base)
    return err(fail(rkEscape, header, line, id & ": an unnecessary escape"))
  ok(id)

proc literalOf(it: CItem, header: string): Result[CScalar, Rejection] =
  recognizeLiteral(it.tokens, header, it.line)

func scalarName(base: string): string =
  ## [SPEC INTERFACE §2.2] The CDDL prelude name of a C scalar type.
  case base
  of "bool": "bool"
  of "uint8_t": "uint8"
  of "uint16_t": "uint16"
  of "uint32_t": "uint32"
  of "uint64_t": "uint64"
  of "int8_t": "int8"
  of "int16_t": "int16"
  of "int32_t": "int32"
  of "int64_t": "int64"
  else: ""

func prim(name: string): ENode =
  ENode(kind: enPrim, prim: name)

func sizeName(name, kind: string): Opt[(uint64, uint64)] =
  ## `logos_<kind>_size_<n>_t` or `logos_<kind>_size_<lo>_<hi>_t`.
  let p = "logos_" & kind & "_size_"
  if not name.startsWith(p) or not name.endsWith("_t"):
    return Opt.none((uint64, uint64))
  let parts = name[p.len ..^ 3].split('_')
  if parts.len == 1:
    let n = canonicalDigits(parts[0])
    if n.isSome:
      return Opt.some((n.get, n.get))
  elif parts.len == 2:
    let lo = canonicalDigits(parts[0])
    let hi = canonicalDigits(parts[1])
    if lo.isSome and hi.isSome:
      return Opt.some((lo.get, hi.get))
  Opt.none((uint64, uint64))

func signature(it: CItem): string =
  ## A function's types without parameter names.
  var ps: seq[string] = @[]
  for p in it.params:
    ps.add($p.ctype)
  $it.ctype & "(" & (if it.voidParams: "void" else: ps.join(", ")) & ")"

# The predefined environment ------------------------------------------------------

proc commonEnv(): Common =
  ## [SPEC INTERFACE §3.1 l.2217-2219, §3.2 l.2332-2335, §5.2] The names
  ## `logos_types.h` declares and the common declarations they map to.
  let c = Common()
  let lay = commonLayout()
  for k, d in lay.defs:
    if '#' notin k:
      c.types[d.typeName] = k
  c.types["logos_error_code_t"] = "logos.error_code"
  for n in lay.constraints:
    c.constraints.incl(n)
  let text = logosTypesHeader()
  var i = 0
  while i < text.len:
    if text[i] in IdentChars and (i == 0 or text[i - 1] notin IdentChars):
      var j = i
      while j < text.len and text[j] in IdentChars:
        inc j
      let id = text[i ..< j]
      if id.startsWith("logos_") and id.endsWith("_t"):
        c.predeclared.incl(id)
      i = j
    else:
      inc i
  let lc = parseHeader("lifecycle", LifecycleTemplates)
  if lc.isOk:
    for it in lc.get.items:
      let op = it.name["logos_M_MODULE_".len ..^ 1]
      c.lifecycle[op] = signature(it)
  c

# Classification --------------------------------------------------------------------

type ClassKind = enum
  ckFrame
  ckConstraint
  ckGroup
  ckModule

proc classify(
    c: Common, it: CItem, header: string
): Result[(ClassKind, string), Rejection] =
  ## Which group (by C namespace component) or module family (by module-C) an
  ## item belongs to.
  case it.kind
  of ciInclude, ciRevisionCheck, ciContextCheck, ciDocumentGuard:
    ok((ckFrame, ""))
  of ciDefine:
    let n = it.name
    if n.startsWith(PrimaryPrefix):
      return ok((ckModule, n[PrimaryPrefix.len ..^ 1]))
    if n.startsWith(ImplementsPrefix):
      let k = n.rfind("_INDEX")
      if k > ImplementsPrefix.len:
        return ok((ckModule, n[ImplementsPrefix.len ..< k]))
    if n.startsWith(InterfacePrefix):
      return ok((ckGroup, n[InterfacePrefix.len ..^ 1]))
    if n.startsWith(SupportingPrefix):
      return ok((ckGroup, n[SupportingPrefix.len ..^ 1]))
    if n.startsWith(SensitivePrefix):
      let k = n.rfind("_INDEX")
      if k > SensitivePrefix.len:
        return ok((ckGroup, n[SensitivePrefix.len ..< k]))
    if n.startsWith(LiteralPrefix):
      let s = ?splitStem(n[LiteralPrefix.len ..^ 1], header, it.line)
      return ok((ckGroup, s.cns))
    if n.startsWith(ArmPrefix):
      let k = n.find("_CASE")
      if k > ArmPrefix.len:
        let s = ?splitStem(n[ArmPrefix.len ..< k], header, it.line)
        return ok((ckGroup, s.cns))
    if n.startsWith("LOGOS_"):
      return err(
        fail(
          rkRestatedFact,
          header,
          it.line,
          n & " is no constant the mapping defines (INTERFACE §2 l.636)",
        )
      )
    err(fail(rkOutsideSubset, header, it.line, "the macro " & n & " (INTERFACE §3.1)"))
  of ciAlias, ciForward, ciStruct, ciFnTypedef:
    var name = it.name
    if it.kind == ciStruct and name.len == 0:
      let (stem, family) = tagFamily(it.tag)
      if family.len == 0:
        return err(fail(rkPath, header, it.line, "struct " & it.tag & ": no family"))
      name = "logos_" & stem & "_t"
    if it.kind == ciAlias and
        (sizeName(name, "tstr").isSome or sizeName(name, "bstr").isSome):
      return ok((ckConstraint, ""))
    if name in c.predeclared:
      return err(
        fail(
          rkFixedType,
          header,
          it.line,
          name & " is declared by logos_types.h (INTERFACE §3.2 l.2335)",
        )
      )
    if it.kind == ciFnTypedef:
      if not name.startsWith("logos_") or not name.endsWith("_FN_t"):
        return err(fail(rkFunction, header, it.line, name & ": not a method typedef"))
      let s = ?splitStem(name[6 ..^ 6], header, it.line)
      return ok((ckGroup, s.cns))
    let stem = typeStem(name)
    if stem.isNone:
      return
        err(fail(rkOutsideSubset, header, it.line, name & " is no schema-derived name"))
    var st = stem.get
    if st.endsWith("_KIND"):
      st = st[0 ..^ 6]
    let s = ?splitStem(st, header, it.line)
    ok((ckGroup, s.cns))
  of ciFunction:
    let n = it.name
    for marker in ["_MODULE_", "_CALL_"]:
      let k = n.find(marker)
      if n.startsWith("logos_") and k > 6:
        return ok((ckModule, n[6 ..< k]))
    err(
      fail(
        rkOutsideSubset,
        header,
        it.line,
        n & " is neither a provider function nor a module symbol (INTERFACE §3.1)",
      )
    )

proc view(c: Common, h: ParsedHeader, index: int): Result[HeaderView, Rejection] =
  ## One body's items by group and module family, with document guards
  ## flattened (their children must belong to the guarded group).
  var v = HeaderView()
  proc occ(
      v: var HeaderView, cns: string, h: ParsedHeader, index, line: int
  ): Result[void, Rejection] =
    if cns notin v.occs:
      let ns = decodeNamespace(cns)
      if ns.isErr:
        return err(fail(rkName, h.name, line, ns.error))
      v.occs[cns] = Occ(header: index, cns: cns, ns: ns.get)
    ok()

  proc place(
      c: Common,
      v: var HeaderView,
      it: CItem,
      h: ParsedHeader,
      index: int,
      guard: string,
  ): Result[void, Rejection] =
    let (k, key) = ?classify(c, it, h.name)
    case k
    of ckFrame:
      discard
    of ckConstraint:
      v.constraints.add(it)
    of ckModule:
      if guard.len > 0:
        return err(
          fail(
            rkConditional,
            h.name,
            it.line,
            it.name &
              ": provider-specific declarations are never guarded (INTERFACE §3.2 l.2326)",
          )
        )
      v.modules.mgetOrPut(key, @[]).add(it)
    of ckGroup:
      if guard.len > 0 and key != guard:
        return err(
          fail(
            rkNotCanonical,
            h.name,
            it.line,
            it.name & " is inside the document guard of another namespace",
          )
        )
      ?v.occ(key, h, index, it.line)
      v.occs.mgetOrPut(key, Occ()).items.add(it)
    ok()

  for it in h.items:
    if it.kind == ciDocumentGuard:
      ?v.occ(it.name, h, index, it.line)
      v.occs.mgetOrPut(it.name, Occ()).guards.add(it)
      for ch in it.children:
        ?place(c, v, ch, h, index, it.name)
    else:
      ?place(c, v, it, h, index, "")
  ok(v)

# Frame checks ---------------------------------------------------------------------

proc checkFrame(h: ParsedHeader): Result[void, Rejection] =
  ## [SPEC INTERFACE §2 l.656-678] A supplied revision or context check must be
  ## the one this mapping and the pinned commitment context generate.
  let markers = contextMarkers()
  for it in h.items:
    case it.kind
    of ciRevisionCheck:
      let v = ?literalOf(it, h.name)
      if v.kind != cskInt or v.negative or v.magnitude != uint64(CMappingRevision):
        return err(
          fail(
            rkRevisionCheck, h.name, it.line,
            "the C mapping revision check must compare with 3u",
          )
        )
    of ciContextCheck:
      let v = ?literalOf(it, h.name)
      if it.name notin markers:
        return err(
          fail(rkContextCheck, h.name, it.line, it.name & " is not the pinned context")
        )
      if v.kind != cskInt or v.negative or v.magnitude != 1:
        return err(
          fail(rkContextCheck, h.name, it.line, it.name & " must be compared with 1")
        )
    else:
      discard
  for it in h.items:
    if it.kind == ciAlias:
      let t = sizeName(it.name, "tstr")
      let b = sizeName(it.name, "bstr")
      if t.isSome or b.isSome:
        # [SPEC INTERFACE §2.2] the canonical constraint typedef
        let (lo, hi) = (if t.isSome: t.get else: b.get)
        let canonical =
          if t.isSome:
            (
              if lo == hi: "logos_tstr_size_" & $lo & "_t"
              else: "logos_tstr_size_" & $lo & "_" & $hi & "_t"
            )
          else:
            "logos_bstr_size_" & $lo & "_" & $hi & "_t"
        let base = (if t.isSome: "char" else: "uint8_t")
        if it.name != canonical or lo > hi or not it.ctype.isPtr(base, 1, true):
          return err(
            fail(
              rkNotCanonical, h.name, it.line, it.name & ": not a canonical constraint"
            )
          )
  ok()

# Reconstruction of one group -------------------------------------------------------

proc single(
  b: var Builder, t: CType, stem: string, line: int
): Result[ENode, Rejection] {.gcsafe.}

proc aggregate(
  b: var Builder, d: Def, stem: string
): Result[ENode, Rejection] {.gcsafe.}

proc valueType(b: Builder, t: CType, mode: Mode, line: int): Result[CType, Rejection] =
  ## A member or parameter type in its value form: a recursive or by-pointer
  ## `const T*` aggregate is `T` (the comparison with `H'` checks which one the
  ## position needs), and an output loses its pointer.
  var v = t
  if mode == mOut:
    if v.pointers == 0 or v.ptrToArray:
      return err(fail(rkMember, b.header, line, "an output parameter is a pointer"))
    dec v.pointers
    if v.pointers == 0:
      v.constPtr = false
    return ok(v)
  if v.isConst and v.pointers == 1 and not v.constPtr and v.base.startsWith("logos_"):
    v.isConst = false
    v.pointers = 0
  ok(v)

proc position(
    b: var Builder, t: CType, stem: string, line: int
): Result[ENode, Rejection] =
  ## [SPEC INTERFACE §2.3] A tuple position, list element or choice arm.
  if t.isPlain("logos_bstr_size_0_t"):
    return ok(ENode(kind: enSized, base: "bstr", lo: 0, hi: 0))
  if t.isPlain("logos_tuple_size_0_t"):
    return ok(ENode(kind: enTuple, items: @[]))
  b.single(t, stem, line)

proc literalNode(v: CScalar): ENode =
  case v.kind
  of cskBool:
    ENode(kind: enBool, boolean: v.boolean)
  of cskInt:
    ENode(kind: enInt, negative: v.negative, magnitude: v.magnitude)
  of cskText:
    ENode(kind: enText, text: v.text)

proc typeNode(
    b: var Builder, t: CType, stem: string, line: int
): Result[ENode, Rejection] =
  ## [SPEC INTERFACE §3.4, §3.5 l.2520-2531] The schema node a value type
  ## spells at the path whose stem is `stem`.
  let s = scalarName(t.base)
  if s.len > 0 and t.isPlain(t.base):
    return ok(prim(s))
  if t.isPtr("char", 1, true):
    return ok(prim("tstr"))
  if t.isPlain(t.base):
    let size = sizeName(t.base, "tstr")
    if size.isSome:
      return ok(ENode(kind: enSized, base: "tstr", lo: size.get[0], hi: size.get[1]))
    if t.base == "logos_" & stem & "_t":
      # the inline stem derived for this exact path
      if t.base notin b.defs:
        return
          err(fail(rkIncompleteGroup, b.header, line, t.base & " has no definition"))
      if t.base in b.used:
        return err(
          fail(
            rkCollision,
            b.header,
            line,
            t.base & " is derived by two paths (INTERFACE §3.5 l.2531, §3.2 l.2387)",
          )
        )
      b.used.incl(t.base)
      let d = b.defs.getOrDefault(t.base)
      if d.family == "EVENT":
        return err(fail(rkEvent, b.header, line, t.base & ": an inline event"))
      return b.aggregate(d, stem)
    if t.base in b.c.types:
      return ok(ENode(kind: enRef, target: b.c.types.getOrDefault(t.base)))
    let ts = typeStem(t.base)
    if ts.isSome and sizeName(t.base, "bstr").isNone and t.base notin b.c.predeclared:
      let st = ?splitStem(ts.get, b.header, line)
      if st.rest.len > 0:
        return err(
          fail(
            rkPath,
            b.header,
            line,
            t.base & " is not the type of the path " & stem &
              " (INTERFACE §3.5 l.2526-2531)",
          )
        )
      let q = st.ns & "." & st.local
      if st.ns == b.ns:
        b.localRefs.add((q, line))
      else:
        b.refs.incl(st.ns)
      return ok(ENode(kind: enRef, target: q))
  if t.isPlain("size_t") or t.isPtr("uint8_t", 1, true) or
      sizeName(t.base, "bstr").isSome or t.pointers > 0:
    return err(
      fail(
        rkMember, b.header, line,
        "an unmatched byte-string, length or count member (INTERFACE §3.3, §3.4)",
      )
    )
  err(
    fail(
      rkOutsideSubset,
      b.header,
      line,
      $t & " is not a schema type of the C subset (INTERFACE §3.1)",
    )
  )

proc single(
    b: var Builder, t: CType, stem: string, line: int
): Result[ENode, Rejection] {.gcsafe.} =
  ## A literal, when the path has its `LOGOS_LITERAL_<stem>` macro (§2.3), else
  ## the node the type spells.
  let lit = LiteralPrefix & stem
  if lit in b.literals:
    b.used.incl(lit)
    let it = b.literals.getOrDefault(lit)
    let v = ?literalOf(it, b.header)
    let fits =
      case v.kind
      of cskBool:
        t.isPlain("bool")
      of cskInt:
        (if v.negative: t.isPlain("int64_t") else: t.isPlain("uint64_t"))
      of cskText:
        t.isPtr("char", 1, true)
    if not fits:
      return err(
        fail(
          rkLiteralKind,
          b.header,
          it.line,
          lit & ": a " & $v.kind & " literal for a " & $t & " member (INTERFACE §3.5)",
        )
      )
    return ok(literalNode(v))
  b.typeNode(t, stem, line)

proc fields(
    b: var Builder, ms: seq[RawMember], mode: Mode, stem: string
): Result[seq[EField], Rejection] =
  ## [SPEC INTERFACE §2.3, §2.4, §3.3, §3.4] Members or parameters back to map
  ## fields: presence flags, byte-string and list pairs, exact-size arrays,
  ## adjacent tuple positions, each field in canonical order.
  var res: seq[EField] = @[]
  var i = 0
  var prev = ""
  let boolT =
    (if mode == mOut: CType(base: "bool", pointers: 1)
    else: CType(base: "bool"))
  let sizeT =
    (if mode == mOut: CType(base: "size_t", pointers: 1)
    else: CType(base: "size_t"))
  while i < ms.len:
    var m = ms[i]
    var optional = false
    if m.name.startsWith("has_"):
      let f = m.name[4 ..^ 1]
      if checkFieldName(f).isErr:
        return err(
          fail(
            rkPresence,
            b.header,
            m.line,
            m.name &
              ": a presence flag for no field, or for one tuple position (INTERFACE §3.4)",
          )
        )
      if m.ctype != boolT:
        return err(
          fail(
            rkPresence,
            b.header,
            m.line,
            m.name & " is not the exact " & $boolT & " presence flag",
          )
        )
      if i + 1 >= ms.len or (ms[i + 1].name != f and ms[i + 1].name != f & "_0"):
        return err(
          fail(
            rkPresence,
            b.header,
            m.line,
            m.name & " has no adjacent field " & f & " (INTERFACE §3.4)",
          )
        )
      optional = true
      inc i
      m = ms[i]
    var name = m.name
    var node: ENode
    let next = (if i + 1 < ms.len: ms[i + 1].name else: "")
    let step = "_" & capitalize(name)
    if name.endsWith("_0") and checkFieldName(name[0 ..^ 3]).isOk:
      let f = name[0 ..^ 3]
      var items: seq[ENode] = @[]
      var k = 0
      while i < ms.len and ms[i].name == f & "_" & $k:
        let vt = ?b.valueType(ms[i].ctype, mode, ms[i].line)
        items.add(?b.position(vt, stem & "_" & capitalize(f) & "_TU" & $k, ms[i].line))
        inc k
        inc i
      name = f
      node = ENode(kind: enTuple, items: items)
    elif next == name & "_len":
      let l = ms[i + 1]
      if l.ctype != sizeT:
        return err(fail(rkMember, b.header, l.line, l.name & " is not " & $sizeT))
      var t = m.ctype
      if mode == mOut:
        if t.pointers == 0:
          return err(fail(rkMember, b.header, m.line, m.name & ": not an output"))
        dec t.pointers
      if t.isPtr("uint8_t", 1, true):
        node = prim("bstr")
      else:
        let size = sizeName(t.base, "bstr")
        if size.isNone or not t.isPlain(t.base) or size.get[0] == size.get[1]:
          return err(
            fail(rkMember, b.header, m.line, m.name & ": not a byte-string pointer")
          )
        node = ENode(kind: enSized, base: "bstr", lo: size.get[0], hi: size.get[1])
      i += 2
    elif next == name & "_count":
      let l = ms[i + 1]
      if l.ctype != sizeT:
        return err(fail(rkMember, b.header, l.line, l.name & " is not " & $sizeT))
      let t = m.ctype
      var e: CType
      if mode == mOut:
        if t.pointers < 2 or t.constPtr:
          return err(fail(rkMember, b.header, m.line, m.name & ": not a list output"))
        e = t
        e.pointers -= 2
      elif t.isConst and t.constPtr and t.pointers == 2 and t.base == "char":
        e = CType(isConst: true, base: "char", pointers: 1)
      elif t.isConst and t.pointers == 1 and not t.constPtr and t.arrayLen == 0:
        e = CType(base: t.base)
      else:
        return
          err(fail(rkMember, b.header, m.line, m.name & ": not a list element pointer"))
      let element = ?b.position(e, stem & step & "_LI", m.line)
      node = ENode(kind: enList, element: element)
      i += 2
    elif (
      mode == mStruct and m.ctype.base == "uint8_t" and m.ctype.arrayLen > 0 and
      not m.ctype.isConst and m.ctype.pointers == 0
    ) or (
      mode != mStruct and m.ctype.ptrToArray and m.ctype.base == "uint8_t" and
      m.ctype.isConst == (mode == mIn) and m.ctype.arrayLen > 0
    ):
      let n = uint64(m.ctype.arrayLen)
      node = ENode(kind: enSized, base: "bstr", lo: n, hi: n)
      inc i
    else:
      if m.ctype.arrayLen != 0:
        return err(fail(rkAggregate, b.header, m.line, m.name & ": not a byte array"))
      let fc = checkFieldName(name)
      if fc.isErr:
        return err(
          fail(
            rkMember,
            b.header,
            m.line,
            fc.error & ": not reconstructed as a field (INTERFACE §3.3, §3.4)",
          )
        )
      let vt = ?b.valueType(m.ctype, mode, m.line)
      node = ?b.position(vt, stem & step, m.line)
      inc i
    let fc = checkFieldName(name)
    if fc.isErr:
      return err(
        fail(
          rkMember,
          b.header,
          m.line,
          fc.error & ": not reconstructed as a field (INTERFACE §3.3, §3.4)",
        )
      )
    if prev.len > 0 and cmp(name, prev) <= 0:
      return err(
        fail(
          rkFieldOrder,
          b.header,
          m.line,
          name & " after " & prev & ": fields in canonical order (INTERFACE §2.1)",
        )
      )
    prev = name
    res.add(EField(name: name, optional: optional, node: node))
  ok(res)

proc structMembers(
    b: Builder, ms: seq[cparse.CMember], escaped: bool
): Result[seq[RawMember], Rejection] =
  var res: seq[RawMember] = @[]
  for m in ms:
    if m.isUnion:
      return err(fail(rkAggregate, b.header, m.line, "a union outside a choice"))
    if m.name == "_empty":
      return err(fail(rkAggregate, b.header, m.line, "_empty is the sole empty member"))
    let n = (if escaped: ?unescaped(m.name, b.header, m.line) else: m.name)
    res.add(RawMember(name: n, ctype: m.ctype, line: m.line))
  ok(res)

func isEmpty(ms: seq[cparse.CMember]): bool =
  ms.len == 1 and ms[0].name == "_empty" and ms[0].ctype.isPlain("uint8_t")

proc choice(b: var Builder, d: Def, stem: string): Result[ENode, Rejection] =
  ## [SPEC INTERFACE §2.3, §3.5 l.2518-2535] The `_KIND_t` discriminant, the
  ## complete arm constants and the arms' payloads, from which acceptance
  ## derives the labels; the comparison with `H'` checks the form.
  let ms = d.item.members
  let kindName = "logos_" & stem & "_KIND_t"
  let line = d.item.line
  if ms.len == 0 or ms[0].isUnion or ms[0].name != "kind" or
      not ms[0].ctype.isPlain(kindName):
    return err(fail(rkChoice, b.header, line, d.name & ": no " & kindName & " kind"))
  if kindName notin b.kinds:
    return err(fail(rkChoice, b.header, line, kindName & " is not declared"))
  let k = b.kinds.getOrDefault(kindName)
  if not k.ctype.isPlain("uint32_t"):
    return err(
      fail(
        rkChoice,
        b.header,
        k.line,
        kindName & " must be uint32_t, not " & $k.ctype & " (INTERFACE §2.3)",
      )
    )
  b.used.incl(kindName)
  var union: seq[cparse.CMember] = @[]
  if ms.len == 2:
    if not ms[1].isUnion or ms[1].name != "value":
      return err(fail(rkChoice, b.header, line, d.name & ": not the value union"))
    union = ms[1].unionMembers
  elif ms.len > 2:
    return err(fail(rkChoice, b.header, line, d.name & ": extra members"))
  let prefix = ArmPrefix & stem & "_CASE"
  var arms: seq[(uint64, string, bool)] = @[] # value, step, symbolic
  for name in toSeq(b.arms.keys).sorted:
    if not name.startsWith(prefix):
      continue
    let it = b.arms.getOrDefault(name)
    let suffix = name[prefix.len ..^ 1]
    var step = ""
    var symbolic = false
    if suffix.startsWith("_") and suffix.len > 1:
      step = suffix[1 ..^ 1]
      symbolic = true
    elif canonicalDigits(suffix).isSome:
      step = suffix
    else:
      return err(fail(rkChoice, b.header, it.line, name & ": not an arm constant"))
    let v = ?literalOf(it, b.header)
    if v.kind != cskInt or v.negative or v.magnitude > uint64(high(uint32)):
      return err(fail(rkChoice, b.header, it.line, name & ": not a uint32_t value"))
    b.used.incl(name)
    arms.add((v.magnitude, step, symbolic))
  if arms.len == 0:
    return err(fail(rkChoice, b.header, line, d.name & " has no arm constants"))
  arms.sort(
    proc(x, y: (uint64, string, bool)): int =
      cmp(x[0], y[0])
  )
  var matched: HashSet[string]
  var nodes: seq[ENode] = @[]
  for i, (value, step, symbolic) in arms:
    if symbolic != arms[0][2]:
      return err(fail(rkChoice, b.header, line, d.name & ": mixed arm forms"))
    if value != uint64(i):
      return err(
        fail(
          rkChoice, b.header, line, d.name & ": discriminants are not 0.." & $arms.high
        )
      )
    let pathStep = (if symbolic: "_AR_" & step else: "_AR" & step)
    var found = false
    for m in union:
      if m.name == "arm_" & step:
        if m.isUnion:
          return err(fail(rkChoice, b.header, m.line, "a nested union"))
        matched.incl(m.name)
        let vt = ?b.valueType(m.ctype, mStruct, m.line)
        nodes.add(?b.position(vt, stem & pathStep, m.line))
        found = true
    if not found:
      let lit = LiteralPrefix & stem & pathStep
      if lit notin b.literals:
        return err(
          fail(
            rkLiteralMissing,
            b.header,
            line,
            d.name & ": the arm " & step & " has neither a union member nor its " & lit &
              " literal macro (INTERFACE §3.5)",
          )
        )
      b.used.incl(lit)
      nodes.add(literalNode(?literalOf(b.literals.getOrDefault(lit), b.header)))
  for m in union:
    if m.name notin matched:
      return err(
        fail(rkChoice, b.header, m.line, m.name & " is the member of no arm constant")
      )
  ok(ENode(kind: enChoice, arms: nodes))

proc aggregate(
    b: var Builder, d: Def, stem: string
): Result[ENode, Rejection] {.gcsafe.} =
  ## [SPEC INTERFACE §3.4] An aggregate tag's family decides its construct.
  let ms = d.item.members
  let line = d.item.line
  if ms.len == 0:
    return err(
      fail(rkAggregate, b.header, line, d.name & ": an empty struct (INTERFACE §3.4)")
    )
  case d.family
  of "MAP", "EVENT":
    if ms.isEmpty:
      return ok(ENode(kind: enMap, fields: @[]))
    let raw = ?b.structMembers(ms, true)
    let fs = ?b.fields(raw, mStruct, stem)
    ok(ENode(kind: enMap, fields: fs))
  of "LIST":
    if ms.len != 2 or ms[0].name != "items" or ms[1].name != "count" or
        not ms[1].ctype.isPlain("size_t"):
      return err(fail(rkAggregate, b.header, line, d.name & ": not items and count"))
    let t = ms[0].ctype
    var e: CType
    if t.isConst and t.constPtr and t.pointers == 2 and t.base == "char":
      e = CType(isConst: true, base: "char", pointers: 1)
    elif t.isConst and t.pointers == 1 and not t.constPtr and t.arrayLen == 0:
      e = CType(base: t.base)
    else:
      return err(fail(rkAggregate, b.header, line, d.name & ": not an element pointer"))
    let element = ?b.position(e, stem & "_LI", ms[0].line)
    ok(ENode(kind: enList, element: element))
  of "TUPLE":
    if ms.isEmpty:
      return ok(ENode(kind: enTuple, items: @[]))
    var items: seq[ENode] = @[]
    for i, m in ms:
      if m.isUnion or m.name != "item_" & $i:
        return err(fail(rkAggregate, b.header, m.line, m.name & ": not item_" & $i))
      let vt = ?b.valueType(m.ctype, mStruct, m.line)
      items.add(?b.position(vt, stem & "_TU" & $i, m.line))
    ok(ENode(kind: enTuple, items: items))
  of "BSTR":
    if ms.isEmpty:
      return ok(ENode(kind: enSized, base: "bstr", lo: 0, hi: 0))
    if ms.len == 1 and ms[0].name == "data" and ms[0].ctype.base == "uint8_t" and
        ms[0].ctype.arrayLen > 0 and not ms[0].ctype.isConst and
        ms[0].ctype.pointers == 0:
      let n = uint64(ms[0].ctype.arrayLen)
      return ok(ENode(kind: enSized, base: "bstr", lo: n, hi: n))
    if ms.len == 2 and ms[0].name == "data" and ms[1].name == "len" and
        ms[1].ctype.isPlain("size_t"):
      let t = ms[0].ctype
      if t.isPtr("uint8_t", 1, true):
        return ok(prim("bstr"))
      let size = sizeName(t.base, "bstr")
      if size.isSome and t.isPlain(t.base) and size.get[0] != size.get[1]:
        return ok(ENode(kind: enSized, base: "bstr", lo: size.get[0], hi: size.get[1]))
    err(fail(rkAggregate, b.header, line, d.name & ": not a byte-string aggregate"))
  of "CHOICE":
    b.choice(d, stem)
  else:
    err(fail(rkPath, b.header, line, d.name & ": unknown family"))

proc params(
    b: Builder, it: CItem
): Result[(seq[RawMember], seq[RawMember]), Rejection] =
  ## [SPEC INTERFACE §3.3] The ABI state parameters, then inputs, then outputs:
  ## the escape reversed on the complete identifier, then one direction prefix.
  if not it.ctype.isPlain("logos_result_t") or it.voidParams or it.params.len < 2 or
      not it.params[0].ctype.isPtr("logos_module_context_t", 1) or
      it.params[0].name != "module" or
      not it.params[1].ctype.isPtr("logos_response_owner_t", 1) or
      it.params[1].name != "response_owner":
    return err(
      fail(
        rkFunction,
        b.header,
        it.line,
        it.name & ": not the method pattern of INTERFACE §3.3 l.2400-2405",
      )
    )
  var ins, outs: seq[RawMember]
  for p in it.params[2 ..^ 1]:
    let id = ?unescaped(p.name, b.header, p.line)
    if id.startsWith("in_") and id.len > 3:
      if outs.len > 0:
        return err(
          fail(rkParamOrder, b.header, p.line, p.name & " after an output parameter")
        )
      ins.add(RawMember(name: id[3 ..^ 1], ctype: p.ctype, line: p.line))
    elif id.startsWith("out_") and id.len > 4:
      outs.add(RawMember(name: id[4 ..^ 1], ctype: p.ctype, line: p.line))
    else:
      return
        err(fail(rkParamOrder, b.header, p.line, p.name & ": no in_ or out_ prefix"))
  ok((ins, outs))

proc half(
    b: var Builder, it: CItem, stem, which: string, ms: seq[RawMember], mode: Mode
): Result[ENode, Rejection] =
  ## [SPEC INTERFACE §2.4 rules 4-7, §3.3 l.2420-2433] A choice-valued half is
  ## exactly its wrapper over the named choice; a map-valued half is flattened.
  let choiceName = "logos_" & stem & "_" & which & "_t"
  let d = b.defs.getOrDefault(choiceName)
  let wrapper = (if mode == mIn: "request" else: "response")
  if d.family == "CHOICE":
    let want = CType(isConst: mode == mIn, base: choiceName, pointers: 1)
    if ms.len != 1 or ms[0].name != wrapper or ms[0].ctype != want:
      return err(
        fail(
          rkWrapper,
          b.header,
          it.line,
          it.name & ": a choice-valued " & which & " is exactly " & $want & " " &
            (if mode == mIn: "in_" else: "out_") & wrapper & " (INTERFACE §2.4)",
        )
      )
    b.used.incl(choiceName)
    return b.choice(d, stem & "_" & which)
  for m in ms:
    if m.name == wrapper and m.ctype.base == choiceName:
      return err(
        fail(
          rkWrapper,
          b.header,
          m.line,
          "the wrapper of a " & which & " that is no choice",
        )
      )
  let fs = ?b.fields(ms, mode, stem & "_" & which)
  ok(ENode(kind: enMap, fields: fs))

proc build(c: Common, o: Occ, header: string): Result[Builder, Rejection] =
  ## [SPEC INTERFACE §3.2-§3.6] One group's declarations, top-down from its
  ## named declarations and method typedefs.
  var b = Builder(c: c, header: header, cns: o.cns, ns: o.ns)
  var fwd: Table[string, string] # tag -> name
  var seenRender: Table[string, string]
  for it in o.items:
    if it.kind == ciForward:
      if it.tag in fwd and fwd.getOrDefault(it.tag) != it.name:
        return err(
          fail(rkConflictingDefinition, header, it.line, it.tag & " is forwarded twice")
        )
      fwd[it.tag] = it.name
  for it in o.items:
    # an identical repeat conflicts with nothing (INTERFACE §3.2 l.2376)
    var id = it.name
    if it.kind == ciStruct and id.len == 0:
      id = fwd.getOrDefault(it.tag)
      if id.len == 0:
        return err(
          fail(
            rkIncompleteGroup, header, it.line, "struct " & it.tag & " has no typedef"
          )
        )
    if it.kind == ciForward:
      continue
    let r = render(it)
    if id in seenRender:
      if seenRender.getOrDefault(id) == r:
        continue
      return err(
        fail(
          rkConflictingDefinition,
          header,
          it.line,
          id & " is defined twice differently (INTERFACE §3.2 l.2376)",
        )
      )
    seenRender[id] = r
    case it.kind
    of ciStruct:
      let stem = typeStem(id).get("")
      let (tstem, family) = tagFamily(it.tag)
      if family.len == 0 or tstem != stem:
        return err(
          fail(
            rkPath,
            header,
            it.line,
            "struct " & it.tag & " does not name " & id & " with a family suffix",
          )
        )
      b.defs[id] = Def(item: it, name: id, tag: it.tag, family: family)
    of ciAlias:
      if typeStem(it.name).get("").endsWith("_KIND"):
        b.kinds[it.name] = it
      else:
        b.aliases[it.name] = it
    of ciDefine:
      if it.name.startsWith(LiteralPrefix):
        b.literals[it.name] = it
      elif it.name.startsWith(ArmPrefix):
        b.arms[it.name] = it
      elif it.name.startsWith(SensitivePrefix):
        b.sensitive.add(it)
    of ciFnTypedef:
      b.fns.add(it)
    else:
      discard
  for tag, name in fwd:
    if name notin b.defs:
      return err(
        fail(
          rkIncompleteGroup,
          header,
          0,
          name & " is forward-declared and never defined (INTERFACE §3.2 l.2375)",
        )
      )
    if b.defs.getOrDefault(name).tag != tag:
      return err(fail(rkConflictingDefinition, header, 0, name & ": two struct tags"))
  # methods
  for it in b.fns:
    let st = ?splitStem(it.name[6 ..^ 6], header, it.line)
    if st.rest.len > 0:
      return
        err(fail(rkFunction, header, it.line, it.name & ": not <namespace>_<Method>"))
    let (ins, outs) = ?b.params(it)
    let stem = st.cns & "_" & st.owner
    let req = ?b.half(it, stem, "request", ins, mIn)
    let resp = ?b.half(it, stem, "response", outs, mOut)
    for (which, node) in [("request", req), ("response", resp)]:
      let q = st.ns & "." & st.local & "_" & which
      if q in b.names:
        return
          err(fail(rkConflictingDefinition, header, it.line, q & " is defined twice"))
      b.names.incl(q)
      b.halves.incl(q)
      b.decls.add(EDeclaration(name: q, node: node))
    b.callable = true
  # named declarations
  var named: seq[string] = toSeq(b.defs.keys) & toSeq(b.aliases.keys)
  named.sort()
  for name in named:
    let line =
      if name in b.defs:
        b.defs.getOrDefault(name).item.line
      else:
        b.aliases.getOrDefault(name).line
    let stem = typeStem(name).get("")
    let st = ?splitStem(stem, header, line)
    if st.rest.len > 0:
      continue # an inline aggregate, reached by containment
    let q = st.ns & "." & st.local
    if st.local.endsWith("_request") or st.local.endsWith("_response"):
      if name notin b.used:
        return err(
          fail(
            rkHalfMissing,
            header,
            line,
            q & " has no method typedef that consumes it (INTERFACE §3.2 l.2377)",
          )
        )
      continue
    let event = st.local.endsWith("_event")
    var node: ENode
    if name in b.defs:
      let d = b.defs.getOrDefault(name)
      if d.family == "EVENT" and not event:
        return err(
          fail(
            rkEvent,
            header,
            line,
            d.tag &
              ": an _EVENT tag whose owner does not end in _event (INTERFACE §3.6)",
          )
        )
      if event and d.family notin ["EVENT", "CHOICE"]:
        return
          err(fail(rkEvent, header, line, q & ": an event is an _EVENT or a _CHOICE"))
      b.used.incl(name)
      node = ?b.aggregate(d, stem)
    else:
      if event:
        return
          err(fail(rkEvent, header, line, q & ": an event is an _EVENT or a _CHOICE"))
      b.used.incl(name)
      node = ?b.single(b.aliases.getOrDefault(name).ctype, stem, line)
    if event:
      b.callable = true
    if q in b.names:
      return err(fail(rkConflictingDefinition, header, line, q & " is defined twice"))
    b.names.incl(q)
    b.decls.add(EDeclaration(name: q, node: node))
  # everything consumed
  for name, d in b.defs:
    if name notin b.used:
      return err(
        fail(
          rkPath,
          header,
          d.item.line,
          name & " is reached by no containment path (INTERFACE §3.5 l.2526)",
        )
      )
  for name, it in b.kinds:
    if name notin b.used:
      return err(fail(rkChoice, header, it.line, name & " belongs to no choice"))
  for name, it in b.arms:
    if name notin b.used:
      return err(fail(rkChoice, header, it.line, name & " belongs to no choice"))
  for name, it in b.literals:
    if name notin b.used:
      return err(
        fail(
          rkRestatedFact,
          header,
          it.line,
          name & " names no literal node (INTERFACE §2 l.636, §2.1 l.794)",
        )
      )
  for (q, line) in b.localRefs:
    if q notin b.names:
      return err(
        fail(
          rkIncompleteGroup,
          header,
          line,
          q & " is not declared in its group (INTERFACE §3.2 l.2375)",
        )
      )
  ok(b)

proc sensitiveNames(b: Builder): Result[seq[string], Rejection] =
  ## [SPEC INTERFACE §2.1, §3.2 l.2365-2367] `LOGOS_SENSITIVE_<ns>_INDEX<i>`:
  ## contiguous from 0, in ASCII order, each a local request or response.
  var byIndex: Table[uint64, (string, int)]
  for it in b.sensitive:
    let k = it.name.rfind("_INDEX")
    let idx = canonicalDigits(it.name[k + 6 ..^ 1])
    let v = ?literalOf(it, b.header)
    if idx.isNone or v.kind != cskText:
      return
        err(fail(rkSensitive, b.header, it.line, it.name & ": not an index and a name"))
    if idx.get in byIndex and byIndex.getOrDefault(idx.get)[0] != v.text:
      return err(fail(rkSensitive, b.header, it.line, it.name & " is defined twice"))
    byIndex[idx.get] = (v.text, it.line)
  var names: seq[string] = @[]
  for i in 0 ..< byIndex.len:
    if uint64(i) notin byIndex:
      return
        err(fail(rkSensitive, b.header, 0, "sensitivity indices are not contiguous"))
    let (n, line) = byIndex.getOrDefault(uint64(i))
    if n notin b.halves:
      return
        err(fail(rkSensitive, b.header, line, n & " is no local request or response"))
    if names.len > 0 and cmp(n, names[^1]) <= 0:
      return err(fail(rkSensitive, b.header, line, n & ": not in ASCII order"))
    names.add(n)
  ok(names)

# Comparison keys -------------------------------------------------------------------

func isRoleConstant(name: string): bool =
  name.startsWith(PrimaryPrefix) or name.startsWith(InterfacePrefix) or
    name.startsWith(SupportingPrefix)

proc keyed(
    items: seq[CItem], header: string
): Result[Table[string, HashSet[string]], Rejection] =
  ## [IMPL-DECISION G319] Each item's identifier and normalized spelling: macros
  ## by decoded value, a forward typedef folded into its definition, module
  ## symbols without parameter names; role constants, constraint typedefs and
  ## frame items left out.
  var fwd: Table[string, string]
  for it in items:
    if it.kind == ciForward:
      fwd[it.tag] = it.name
  var res: Table[string, HashSet[string]]
  for it in items:
    var id = it.name
    var key = ""
    case it.kind
    of ciDefine:
      if isRoleConstant(it.name):
        continue
      let v = literalOf(it, header)
      key = it.name & " = " & (if v.isOk: $v.get else: spelled(it.tokens))
    of ciAlias:
      if sizeName(it.name, "tstr").isSome or sizeName(it.name, "bstr").isSome:
        continue
      key = render(it)
    of ciStruct:
      if id.len == 0:
        id = fwd.getOrDefault(it.tag, it.tag)
      var ms: seq[string] = @[]
      for m in it.members:
        ms.add(render(m))
      key = "typedef struct " & it.tag & " { " & ms.join("; ") & " } " & id
    of ciFnTypedef:
      key = render(it)
    of ciFunction:
      key =
        if "_MODULE_" in it.name:
          it.name & " " & signature(it)
        else:
          render(it)
    else:
      continue
    res.mgetOrPut(id, initHashSet[string]()).incl(key)
  ok(res)

func structMembersOf(key: string): seq[string] =
  let a = key.find("{ ")
  let z = key.rfind(" }")
  if a < 0 or z <= a:
    return @[]
  key[a + 2 ..< z].split("; ")

func diffReason(id, mine, theirs: string): RejectReason =
  ## The specific reason for one differing item, when there is one.
  if id.startsWith(ArmPrefix) or id.endsWith("_KIND_t") or mine.contains("_CHOICE {") or
      theirs.contains("_CHOICE {"):
    return rkChoice
  if mine.startsWith("typedef struct ") and theirs.startsWith("typedef struct "):
    let a = structMembersOf(mine)
    let b = structMembersOf(theirs)
    if a.len == b.len:
      for i in 0 ..< a.len:
        if a[i] != b[i]:
          let (an, bn) = (a[i].rsplit(' ', 1), b[i].rsplit(' ', 1))
          if an.len == 2 and bn.len == 2 and an[1] == bn[1]:
            if "const " & an[0] & "*" == bn[0]:
              return rkRecursiveEmbedded
            if an[0] == "const " & bn[0] & "*":
              return rkRecursivePointer
          break
  rkNotCanonical

# The main entry -------------------------------------------------------------------

proc accepted[T](r: Result[T, string], header, what: string): Result[T, Rejection] =
  if r.isErr:
    return
      err(fail(rkSchema, header, 0, what & ": " & r.error & " (INTERFACE §1, §3.8)"))
  ok(r.get)

func hexRoot(d: Digest): string =
  var s = ""
  for x in d:
    s.add(toHex(int(x), 2).toLowerAscii)
  s

proc rootLiteral(s: string): Opt[string] =
  ## `0x<16 hex digits>ULL` (any case) -> the 16 lowercase digits.
  var t = s.toLowerAscii
  if not t.startsWith("0x") or not t.endsWith("ull") or t.len != 21:
    return Opt.none(string)
  t = t[2 ..< 18]
  for ch in t:
    if ch notin HexDigits:
      return Opt.none(string)
  Opt.some(t)

proc reconstruct*(
    hs: HeaderSet, opts = RmapOptions()
): Result[Reconstruction, Rejection] {.gcsafe.} =
  ## [SPEC INTERFACE §3] The subject document or module a header set
  ## reconstructs, with its dependencies, binding and canonical header `H'`.
  let c = commonEnv()
  let aopts = AcceptOptions(system: opts.system)
  var views: seq[HeaderView] = @[]
  var allCns: OrderedSet[string]
  var allModules: OrderedSet[string]
  for i, h in hs.headers:
    ?checkFrame(h)
    let v = ?view(c, h, i)
    for k in v.occs.keys:
      allCns.incl(k)
    for k in v.modules.keys:
      allModules.incl(k)
    views.add(v)

  # Selection (INTERFACE §3.2 l.2282-2286; IMPL-DECISION G318)
  var moduleC = ""
  var subjectCns = ""
  var subjectHeader = -1
  if opts.module.len > 0:
    moduleC = projectModule(opts.module)
  elif opts.subject.len > 0:
    subjectCns = projectNamespace(opts.subject)
  elif allModules.len == 1:
    for m in allModules:
      moduleC = m
  elif allModules.len == 0 and allCns.len == 1:
    for k in allCns:
      subjectCns = k
  else:
    # the more specific reason first: several families in one body are one
    # inconsistent module reconstruction (l.2380); several groups without
    # role constants cannot be inferred (l.2349-2351)
    for i, v in views:
      if v.modules.len > 1:
        return err(
          fail(
            rkModuleName,
            hs.headers[i].name,
            0,
            "module families " & toSeq(v.modules.keys).join(", ") &
              " in one header (INTERFACE §3.2 l.2380)",
          )
        )
    if allModules.len == 0:
      for i, v in views:
        for cns, o in v.occs:
          if not o.items.anyIt(it.kind == ciDefine and isRoleConstant(it.name)):
            return err(
              fail(
                rkRoleConstant,
                hs.headers[i].name,
                0,
                o.ns &
                  " needs its document-role constant: the set has more than one group (INTERFACE §3.2 l.2349-2351)",
              )
            )
    return err(
      fail(
        rkSelection,
        "",
        0,
        "the set holds " & $allCns.len & " groups and " & $allModules.len &
          " module families: select one with --module or --subject",
      )
    )
  for i, v in views:
    if subjectHeader < 0:
      if moduleC.len > 0 and moduleC in v.modules:
        subjectHeader = i
      elif subjectCns.len > 0 and subjectCns in v.occs:
        subjectHeader = i
  if subjectHeader < 0:
    return err(
      fail(
        rkSelection,
        "",
        0,
        "no supplied header declares " &
          (if moduleC.len > 0: "module " & opts.module
          else: "namespace " & subjectCns),
      )
    )
  let closure = hs.closure(subjectHeader)
  let subjectName = hs.headers[subjectHeader].name

  # Groups of the reconstruction input; a repeat must agree (l.2300-2303)
  var groups: OrderedTable[string, Group]
  var modItems: seq[(int, CItem)] = @[]
  var families: OrderedSet[string]
  for h in closure:
    let v = views[h]
    for cns, o in v.occs:
      if cns in groups:
        let first = groups.getOrDefault(cns).occ
        let a = ?keyed(first.items, hs.headers[first.header].name)
        let b = ?keyed(o.items, hs.headers[h].name)
        if a != b:
          return err(
            fail(
              rkConflictingGroup,
              hs.headers[h].name,
              0,
              "the group " & o.ns & " differs from its repeat in " &
                hs.headers[first.header].name & " (INTERFACE §3.2 l.2303)",
            )
          )
        groups.mgetOrPut(cns, Group()).occ.guards.add(o.guards)
      else:
        groups[cns] = Group(occ: o)
    for m, items in v.modules:
      families.incl(m)
      for it in items:
        modItems.add((h, it))
  if families.len > 1:
    return err(
      fail(
        rkModuleName,
        subjectName,
        0,
        "module families " & toSeq(families).join(", ") &
          " in one reconstruction (INTERFACE §3.2 l.2380)",
      )
    )
  if moduleC.len == 0 and families.len == 1:
    for m in families:
      # a primary constant naming the subject makes it a module reconstruction
      for (h, it) in modItems:
        if it.name.startsWith(PrimaryPrefix):
          let v = ?literalOf(it, hs.headers[h].name)
          if v.kind == cskText and projectNamespace(v.text) == subjectCns:
            moduleC = m
  if moduleC.len > 0 and moduleC notin families:
    return err(fail(rkSelection, subjectName, 0, "no module family " & moduleC))

  # Roles (l.2337-2354)
  var primaryCns = ""
  var implemented: seq[(uint64, string, int, int)] = @[] # index, cns, header, line
  for (h, it) in modItems:
    let hn = hs.headers[h].name
    if it.kind != ciDefine:
      continue
    let v = ?literalOf(it, hn)
    if v.kind != cskText:
      return err(fail(rkLiteralKind, hn, it.line, it.name & " is a text literal"))
    let ns = checkNamespace(v.text)
    if ns.isErr:
      return err(fail(rkRoleMismatch, hn, it.line, ns.error))
    let cns = projectNamespace(v.text)
    if it.name.startsWith(PrimaryPrefix):
      if cns notin groups:
        return err(
          fail(
            rkRoleMismatch,
            hn,
            it.line,
            it.name & ": " & v.text & " projects to " & cns &
              ", which matches no declaration group (INTERFACE §3.2 l.2379)",
          )
        )
      if primaryCns.len > 0 and primaryCns != cns:
        return err(fail(rkRoleConstant, hn, it.line, "two primary documents"))
      primaryCns = cns
    else:
      let k = it.name.rfind("_INDEX")
      let idx = canonicalDigits(it.name[k + 6 ..^ 1])
      if idx.isNone:
        return err(fail(rkImplementsIndex, hn, it.line, it.name & ": not an index"))
      implemented.add((idx.get, cns, h, it.line))
  for cns, g in groups.mpairs:
    let hn = hs.headers[g.occ.header].name
    var roles: HashSet[Role]
    for it in g.occ.items:
      if it.kind != ciDefine or not isRoleConstant(it.name):
        continue
      let v = ?literalOf(it, hn)
      if v.kind != cskText or projectNamespace(v.text) != cns or v.text != g.occ.ns:
        return err(
          fail(
            rkRoleMismatch,
            hn,
            it.line,
            it.name &
              ": its value does not project to its own name (INTERFACE §3.2 l.2379)",
          )
        )
      roles.incl(
        if it.name.startsWith(InterfacePrefix): roleInterface else: roleSupporting
      )
    if cns == primaryCns:
      roles.incl(roleModule)
    if roles.len > 1:
      return err(
        fail(
          rkRoleConstant,
          hn,
          0,
          g.occ.ns & " has conflicting document-role constants (INTERFACE §3.2 l.2378)",
        )
      )
    for r in roles:
      g.role = r
  for cns, g in groups.mpairs:
    if g.role != roleNone:
      continue
    if allCns.len != 1:
      return err(
        fail(
          rkRoleConstant,
          hs.headers[g.occ.header].name,
          0,
          g.occ.ns &
            " needs its document-role constant: the set has more than one group (INTERFACE §3.2 l.2349-2351)",
        )
      )
  # Reconstruct every group of the input (structure first)
  for cns, g in groups.mpairs:
    let hn = hs.headers[g.occ.header].name
    var b = ?build(c, g.occ, hn)
    g.refs = b.refs
    g.callable = b.callable
    if g.role == roleNone:
      g.role =
        if moduleC.len > 0:
          roleModule
        elif b.callable:
          roleInterface
        else:
          roleSupporting
      if g.role == roleModule:
        primaryCns = cns
    if g.role == roleSupporting and b.callable:
      return err(
        fail(
          rkSupportingCallable,
          hn,
          0,
          g.occ.ns &
            " is a supporting schema with method or event declarations (INTERFACE §3.2 l.2384)",
        )
      )
    g.doc = EDocument(declarations: b.decls)
    g.doc.sensitive = ?b.sensitiveNames()
    if g.role == roleInterface:
      g.doc.iface = g.occ.ns
    if g.role == roleSupporting and g.doc.sensitive.len > 0:
      return
        err(fail(rkSensitive, hn, 0, "a supporting schema declares no sensitivity"))
  if moduleC.len > 0 and primaryCns.len > 0 and primaryCns notin groups:
    return err(fail(rkRoleMismatch, subjectName, 0, "no primary group"))

  # The module family (§3.7; IMPLEMENTS l.2356-2363)
  var moduleName = ""
  var implNs: seq[string] = @[]
  var provider = false
  var symbols: Table[string, CItem]
  if moduleC.len > 0:
    let dm = decodeModule(moduleC)
    if dm.isErr:
      return err(fail(rkName, subjectName, 0, dm.error & " (INTERFACE §2.1)"))
    moduleName = dm.get
    implemented.sort(
      proc(x, y: (uint64, string, int, int)): int =
        cmp(x[0], y[0])
    )
    var seenNs: HashSet[string]
    var seenIdx: Table[uint64, string]
    for (idx, cns, h, line) in implemented:
      let hn = hs.headers[h].name
      if idx in seenIdx:
        if seenIdx.getOrDefault(idx) == cns:
          continue
        return err(fail(rkImplementsIndex, hn, line, "an implements index used twice"))
      seenIdx[idx] = cns
      if cns in seenNs:
        return err(
          fail(
            rkDuplicateImplements, hn, line,
            "an interface implemented twice (INTERFACE §3.2 l.2382)",
          )
        )
      seenNs.incl(cns)
      if cns notin groups or groups.getOrDefault(cns).role != roleInterface:
        return err(
          fail(
            rkImplements,
            hn,
            line,
            cns & ": no complete interface group (INTERFACE §3.2 l.2381)",
          )
        )
      implNs.add(cns)
    for i in 0 ..< implNs.len:
      if uint64(i) notin seenIdx:
        return err(
          fail(
            rkImplementsIndex, subjectName, 0, "implements indices are not contiguous"
          )
        )
    if primaryCns.len > 0 and groups.getOrDefault(primaryCns).callable:
      provider = true
    for cns in implNs:
      if groups.getOrDefault(cns).callable:
        provider = true
    # lifecycle symbols (G322)
    for (h, it) in modItems:
      let hn = hs.headers[h].name
      if it.kind != ciFunction:
        continue
      let p = "logos_" & moduleC & "_MODULE_"
      if it.name.startsWith(p):
        let op = it.name[p.len ..^ 1]
        if op notin c.lifecycle:
          return err(fail(rkLifecycle, hn, it.line, it.name & " is no module symbol"))
        if signature(it) != c.lifecycle.getOrDefault(op):
          return err(
            fail(
              rkLifecycle,
              hn,
              it.line,
              it.name & ": not the INTERFACE §2.6 signature " &
                c.lifecycle.getOrDefault(op),
            )
          )
        symbols[op] = it
        continue
      # a provider function (§3.3)
      let callP = "logos_" & moduleC & "_CALL_"
      if not it.name.startsWith(callP):
        return err(fail(rkModuleName, hn, it.line, it.name & ": another module"))
      let st = ?splitStem(it.name[callP.len ..^ 1], hn, it.line)
      if st.rest.len > 0:
        return err(fail(rkFunction, hn, it.line, it.name & ": not a provider function"))
      if st.cns != primaryCns and st.cns notin implNs:
        return err(
          fail(
            rkMissingImplements,
            hn,
            it.line,
            it.name & ": a provider function of " & st.ns &
              ", which is neither the primary document nor implemented (INTERFACE §3.2 l.2383)",
          )
        )
      let fnName = "logos_" & st.cns & "_" & st.owner & "_FN_t"
      var found = false
      for gi in groups.getOrDefault(st.cns).occ.items:
        if gi.kind == ciFnTypedef and gi.name == fnName:
          found = true
          var a = gi
          a.name = ""
          var bb = it
          bb.name = ""
          if render(
            CItem(
              kind: ciFunction,
              ctype: a.ctype,
              params: a.params,
              voidParams: a.voidParams,
            )
          ) !=
              render(
                CItem(
                  kind: ciFunction,
                  ctype: bb.ctype,
                  params: bb.params,
                  voidParams: bb.voidParams,
                )
              ):
            return err(
              fail(
                rkProviderMismatch,
                hn,
                it.line,
                it.name & " differs from " & fnName & " (INTERFACE §3.3)",
              )
            )
      if not found:
        return err(
          fail(rkProviderMismatch, hn, it.line, it.name & ": no " & fnName & " typedef")
        )
    for op in RequiredOps:
      if op notin symbols:
        return err(
          fail(
            rkLifecycle,
            subjectName,
            0,
            "logos_" & moduleC & "_MODULE_" & op & " is missing (INTERFACE §2.6)",
          )
        )
    if provider:
      for op in ProviderOps:
        if op notin symbols:
          return err(
            fail(
              rkLifecycle,
              subjectName,
              0,
              "the provider's logos_" & moduleC & "_MODULE_" & op &
                " is missing (INTERFACE §2.6 l.1547)",
            )
          )
    elif "async_api" in symbols:
      return err(
        fail(
          rkLifecycle, subjectName, 0,
          "_MODULE_async_api on a module that provides nothing",
        )
      )

  # Acceptance: supporting groups, then interfaces, then the primary document
  var texts: Table[string, string]
  for cns, g in groups.mpairs:
    if g.role != roleSupporting:
      continue
    let hn = hs.headers[g.occ.header].name
    if g.refs.len > 0:
      return err(
        fail(
          rkSchema,
          hn,
          0,
          g.occ.ns & ": a supporting schema references no other document",
        )
      )
    g.text = emit(g.doc)
    let s = ?accepted(acceptContractSet(g.text, [], [], aopts), hn, g.occ.ns)
    g.contract = Opt.some(s.primary)
    texts[g.occ.ns] = g.text

  proc supportingTexts(
      groups: OrderedTable[string, Group], refs: HashSet[string], hn: string
  ): Result[seq[string], Rejection] =
    var res: seq[string] = @[]
    for ns in toSeq(refs).sorted:
      let cns = projectNamespace(ns)
      let g = groups.getOrDefault(cns)
      if cns notin groups or g.role != roleSupporting:
        return err(
          fail(
            rkIncompleteGroup,
            hn,
            0,
            "the declarations of " & ns & " are not in the reconstruction input",
          )
        )
      res.add(g.text)
    ok(res)

  for cns, g in groups.mpairs:
    if g.role != roleInterface:
      continue
    let hn = hs.headers[g.occ.header].name
    g.text = emit(g.doc)
    let supp = ?supportingTexts(groups, g.refs, hn)
    let s = ?accepted(acceptContractSet(g.text, [], supp, aopts), hn, g.occ.ns)
    g.contract = Opt.some(s.primary)

  var res = Reconstruction()
  var schemaSet: CSchemaSet
  var selected: seq[string] = @[] # the documents of H'
  var referenced: HashSet[string]
  if moduleC.len > 0:
    res.module = Opt.some(moduleName)
    var ifaces: seq[(Digest, string)] = @[]
    for cns in implNs:
      ifaces.add((groups.getOrDefault(cns).contract.get.root, cns))
    var sortedIfaces = ifaces
    sortedIfaces.sort(
      proc(x, y: (Digest, string)): int =
        cmpBytes(x[0], y[0])
    )
    if sortedIfaces != ifaces:
      return err(
        fail(
          rkImplementsIndex, subjectName, 0,
          "implements constants not in ascending raw root order (INTERFACE §3.2 l.2358)",
        )
      )
    var refs: HashSet[string]
    for cns in implNs:
      refs.incl(groups.getOrDefault(cns).refs)
      selected.add(cns)
    let ifaceTexts = implNs.mapIt(groups.getOrDefault(it).text)
    if primaryCns.len > 0:
      block:
        var g = addr groups.mgetOrPut(primaryCns, Group())
        g.doc.module = moduleName
        g.doc.implements = ifaces.mapIt(hexRoot(it[0]))
        g.text = emit(g.doc)
        for ns in g.refs:
          if projectNamespace(ns) notin implNs:
            refs.incl(ns)
      selected.add(primaryCns)
      let pg = groups.getOrDefault(primaryCns)
      let supp = ?supportingTexts(groups, refs, subjectName)
      let s = ?accepted(
        acceptContractSet(pg.text, ifaceTexts, supp, aopts), subjectName, pg.occ.ns
      )
      groups.mgetOrPut(primaryCns, Group()).contract = Opt.some(s.primary)
      let bnd = ?accepted(s.binding, subjectName, "the module binding")
      schemaSet = bnd.cSchemaSet
      for x in s.supporting:
        selected.add(projectNamespace(x.model.namespace))
    else:
      let supp = ?supportingTexts(groups, refs, subjectName)
      let bnd = ?accepted(
        acceptBinding(moduleName, Opt.none(string), ifaceTexts, supp, aopts),
        subjectName,
        "the module binding",
      )
      schemaSet = bnd.cSchemaSet
      for x in bnd.supporting:
        selected.add(projectNamespace(x.model.namespace))
    referenced = refs
  else:
    if subjectCns notin groups:
      return err(fail(rkSelection, subjectName, 0, "no group " & subjectCns))
    let g = groups.getOrDefault(subjectCns)
    if g.role == roleModule:
      return err(fail(rkSelection, subjectName, 0, g.occ.ns & " is a module document"))
    let s =
      if g.role == roleSupporting:
        ?accepted(acceptContractSet(g.text, [], [], aopts), subjectName, g.occ.ns)
      else:
        let supp = ?supportingTexts(groups, g.refs, subjectName)
        ?accepted(acceptContractSet(g.text, [], supp, aopts), subjectName, g.occ.ns)
    schemaSet = s.cSchemaSet
    selected.add(subjectCns)
    for x in s.supporting:
      selected.add(projectNamespace(x.model.namespace))
    referenced = g.refs

  # Dependencies (l.2385): a supporting group reached through an include
  for cns, g in groups:
    if g.occ.header != subjectHeader and g.role == roleSupporting and
        g.occ.ns notin referenced:
      # [IMPL-DECISION G318] Say which document needs it: selecting that document,
      # or the module, is the way to reconstruct this header.
      var users: seq[string] = @[]
      for _, other in groups:
        if g.occ.ns in other.refs:
          users.add(other.occ.ns)
      users.sort()
      let hint =
        if users.len > 0:
          "; " & users.join(", ") & " references it: select that document or its module"
        else:
          ""
      return err(
        fail(
          rkUnreferencedDependency,
          hs.headers[g.occ.header].name,
          0,
          g.occ.ns & " is supplied as a dependency of " & subjectName &
            " and not referenced (INTERFACE §3.2 l.2385)" & hint,
        )
      )

  # The documents
  proc rdoc(g: Group): RDocument =
    RDocument(
      namespace: g.occ.ns,
      role: g.contract.get.model.role,
      cddl: g.text,
      contract: g.contract.get,
    )

  if schemaSet.primary.isSome:
    let ns = schemaSet.primary.get.model.namespace
    res.primary = Opt.some(rdoc(groups.getOrDefault(projectNamespace(ns))))
  for d in schemaSet.interfaces:
    res.interfaces.add(rdoc(groups.getOrDefault(projectNamespace(d.model.namespace))))
  for d in schemaSet.supporting:
    res.supporting.add(rdoc(groups.getOrDefault(projectNamespace(d.model.namespace))))
  res.schemaSet = schemaSet

  # Regenerate and compare (§3.8, G319)
  let header = ?accepted(contractHeader(schemaSet), subjectName, "the canonical header")
  res.header = header
  let hp = parseHeader("H'", header)
  if hp.isErr:
    return err(fail(rkSchema, subjectName, 0, "H' does not parse: " & $hp.error))
  let hv = ?view(c, hp.get, -1)
  var mine, theirs: seq[CItem]
  for cns in selected:
    mine.add(groups.getOrDefault(cns).occ.items)
    theirs.add(hv.occs.getOrDefault(cns).items)
  if moduleC.len > 0:
    for (_, it) in modItems:
      mine.add(it)
  for _, items in hv.modules:
    theirs.add(items)
  let a = ?keyed(mine, subjectName)
  let b = ?keyed(theirs, "H'")
  var firstReason = rkNotCanonical
  var firstMsg = ""
  template note(reason: RejectReason, msg: string) =
    if firstMsg.len == 0 or (firstReason == rkNotCanonical and reason != rkNotCanonical):
      firstReason = reason
      firstMsg = msg

  for id, keys in a:
    if id notin b:
      if "_MODULE_" in id:
        let op = id[id.find("_MODULE_") + 8 ..^ 1]
        if op in ["apply_configuration", "async_api"] or
            (not provider and op in ProviderOps):
          continue # G319, G322
      let reason =
        if id.startsWith(ArmPrefix):
          rkChoice
        elif id.startsWith("LOGOS_"):
          rkRestatedFact
        else:
          rkNotCanonical
      note(reason, id & " is not in the canonical header H'")
    elif keys != b.getOrDefault(id):
      let mk = toSeq(keys).sorted.join(" | ")
      let tk = toSeq(b.getOrDefault(id)).sorted.join(" | ")
      note(diffReason(id, mk, tk), "the input has " & mk & ", H' has " & tk)
  for id in b.keys:
    if id notin a:
      note(
        (if id.startsWith(ArmPrefix): rkChoice else: rkNotCanonical),
        "the canonical header H' has " & id & ", which the input lacks",
      )
  if firstMsg.len > 0:
    return err(fail(firstReason, subjectName, 0, firstMsg & " (INTERFACE §3.8; G319)"))

  # Identity checks (l.2306-2311): every guard of an accepted group
  for cns, g in groups:
    if g.contract.isNone:
      continue
    let want = hexRoot(g.contract.get.root)
    for gd in g.occ.guards:
      for r in 0 .. 3:
        for lit in [gd.roots[r], gd.defined[r]]:
          let got = rootLiteral(lit)
          if got.isNone or got.get != want[16 * r ..< 16 * r + 16]:
            return err(
              fail(
                rkIdentity,
                hs.headers[g.occ.header].name,
                gd.line,
                "the identity of " & g.occ.ns & " disagrees with its reconstructed root " &
                  "(INTERFACE §3.2 l.2309)",
              )
            )

  # Declare before use (G319, l.891-892), in the subject's translation order
  var declared = c.predeclared
  var complete = c.predeclared
  var structNames: HashSet[string]
  var order: seq[CItem] = @[]
  for r in hs.order[subjectHeader]:
    let it = hs.headers[r.header].items[r.item]
    if it.kind == ciDocumentGuard:
      order.add(it.children)
    else:
      order.add(it)
  var fwd: Table[string, string]
  for it in order:
    if it.kind == ciForward:
      fwd[it.tag] = it.name
  proc use(
      t: CType, byValue: bool, declared, complete, structNames: HashSet[string]
  ): bool =
    if not t.base.startsWith("logos_"):
      return true
    if t.base notin declared:
      return false
    if byValue and t.pointers == 0 and not t.ptrToArray and t.base in structNames:
      return t.base in complete
    true

  for it in order:
    var ok1 = true
    case it.kind
    of ciAlias:
      ok1 = use(it.ctype, false, declared, complete, structNames)
      declared.incl(it.name)
      complete.incl(it.name)
    of ciForward:
      declared.incl(it.name)
      structNames.incl(it.name)
    of ciStruct:
      for m in it.members:
        if m.isUnion:
          for u in m.unionMembers:
            ok1 = ok1 and use(u.ctype, true, declared, complete, structNames)
        else:
          ok1 = ok1 and use(m.ctype, true, declared, complete, structNames)
      let n = (if it.name.len > 0: it.name else: fwd.getOrDefault(it.tag))
      declared.incl(n)
      complete.incl(n)
      structNames.incl(n)
    of ciFnTypedef, ciFunction:
      ok1 = use(it.ctype, false, declared, complete, structNames)
      for p in it.params:
        ok1 = ok1 and use(p.ctype, false, declared, complete, structNames)
    else:
      discard
    if not ok1:
      return err(
        fail(
          rkDeclareOrder,
          subjectName,
          it.line,
          render(it) &
            " uses a type before its declaration (INTERFACE §2.1 l.891; G319)",
        )
      )
  ok(res)

proc reconstruct*(
    sources: openArray[HeaderSource], opts = RmapOptions()
): Result[Reconstruction, Rejection] {.gcsafe.} =
  ## [SPEC INTERFACE §3] `readSet`, then `reconstruct`.
  let hs = ?readSet(sources)
  reconstruct(hs, opts)
