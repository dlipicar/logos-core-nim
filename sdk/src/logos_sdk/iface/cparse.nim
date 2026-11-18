## INTERFACE §2, §3.1: the declaration forms the reverse mapper reads.
##
## [SPEC INTERFACE §3.1] The reverse mapper accepts the canonical declaration
## forms of §2 and rejects anything outside that subset rather than treating it as
## a helper (l.2223-2224). This module reads one header body's tokens (`clex`) as
## a sequence of items: includes, object-like macros, the C mapping revision and
## commitment-context checks (§2 l.656-678), document guard blocks with their
## identity checks (§3.2 l.2306-2322), typedefs, struct definitions, method
## typedefs and function prototypes. The conditional C++ linkage wrapper (§2
## l.612-629) is accepted as non-schema syntax and recorded (l.2255).
##
## It checks shape only. Which types, names and values are allowed, and what they
## mean, is `rmap`'s work. Nothing is evaluated: a directive is recognized by its
## token shape, and any other conditional, function-like macro or directive is
## rejected (l.2270-2273, l.2567-2569).
##
## [IMPL-DECISION G317] A file-level include guard (`#ifndef G` / `#define G` ...
## `#endif`, with `G` not a `LOGOS_` name) may differ (IF l.642). It may enclose
## declarations, the fixed `logos_types.h` include and the standard headers, but
## no contract-header dependency include, no mapping or context check and no
## document guard with its identity check (l.2325).

{.push raises: [].}

import std/strutils
import results
import ./[clex, cliteral, creject]

export results, creject, clex

type
  CType* = object
    ## A normalized declaration type: `const`, one base identifier, the pointer
    ## depth and, for an array declarator, its bound.
    isConst*: bool
    base*: string ## an identifier, or `struct <tag>`
    pointers*: int
    constPtr*: bool
      ## `T* const*`: the first pointer is const (a list of text strings, §2.3)
    arrayLen*: int ## 0 when not an array; `[0]` is kept as -1
    ptrToArray*: bool
      ## a parameter `T (*name)[N]`: a pointer to an exact-size byte array (§2.4)

  CMember* = object ## A struct member, union member or parameter.
    ctype*: CType
    name*: string
    line*: int
    isUnion*: bool ## `union { ... } <name>;`
    unionMembers*: seq[CMember]

  CItemKind* = enum
    ciInclude ## `#include "name"` or `#include <name>`
    ciDefine ## an object-like macro
    ciRevisionCheck ## §2 l.660-664
    ciContextCheck ## §2 l.668-678
    ciDocumentGuard ## §3.2 l.2313-2322, with its group as `children`
    ciAlias ## `typedef T name;`
    ciForward ## `typedef struct tag name;`
    ciStruct ## `typedef struct tag { ... } name;` or `struct tag { ... };`
    ciFnTypedef ## `typedef logos_result_t (*name)(params);`
    ciFunction ## `T name(params);`

  CItem* = object
    kind*: CItemKind
    line*: int
    name*: string
      ## include target, macro name, check marker, guard namespace component,
      ## typedef or function name ("" for a struct completing a forward typedef)
    angle*: bool ## an angle include
    tokens*: seq[Token] ## a macro's replacement or a check's compared value
    ctype*: CType ## alias target or function return type
    tag*: string ## struct tag
    members*: seq[CMember]
    params*: seq[CMember]
    voidParams*: bool ## `(void)`
    roots*: array[4, string] ## a guard's checked root literals
    defined*: array[4, string] ## a guard's defined root literals
    children*: seq[CItem] ## a guard's declaration group

  ParsedHeader* = object
    name*: string ## the logical name
    items*: seq[CItem]
    linkage*: bool ## the conditional C++ linkage wrapper is present
    includeGuard*: string ## the file-level include guard macro, or ""

  UnitKind = enum
    ukDirective
    ukDeclaration
    ukExternOpen ## `extern "C" {`
    ukCloseBrace ## `}`

  Unit = object
    kind: UnitKind
    toks: seq[Token]
    line: int

const NeverAllowed = [
  "float", "double", "long", "short", "int", "unsigned", "signed", "enum", "static",
  "extern", "inline", "volatile", "register", "restrict", "auto", "_Atomic", "_Bool",
  "_Complex", "_Imaginary", "_Alignas", "_Thread_local", "_Noreturn", "_Static_assert",
  "_Generic", "__attribute__", "__declspec", "alignas", "static_assert", "thread_local",
  "char8_t", "wchar_t", "char16_t", "char32_t", "goto", "return", "sizeof", "typeof",
] ## [SPEC INTERFACE §3.1 l.2261-2268] never part of an accepted declaration

func isP(t: Token, p: string): bool =
  t.kind == tkPunct and t.text == p

func isId(t: Token, s: string): bool =
  t.kind == tkIdent and t.text == s

func `$`*(t: CType): string =
  ## The normalized spelling, as in `const logos_x_t*`, `const char* const*`,
  ## `uint8_t[16]` or `const uint8_t (*)[16]`.
  result = (if t.isConst: "const " else: "") & t.base
  if t.ptrToArray:
    # Not `return result & …`: that leaks `result`'s old value (upstream draft 180).
    result.add(" (*)[" & $max(t.arrayLen, 0) & "]")
    return
  if t.constPtr and t.pointers > 0:
    result.add("* const" & repeat('*', t.pointers - 1))
  else:
    result.add(repeat('*', t.pointers))
  if t.arrayLen != 0:
    result.add("[" & $max(t.arrayLen, 0) & "]")

func spelled*(toks: openArray[Token]): string =
  ## Tokens joined by single spaces (diagnostics and comparison keys).
  var parts: seq[string] = @[]
  for t in toks:
    parts.add(t.text)
  parts.join(" ")

proc units(header: string, toks: seq[Token]): Result[seq[Unit], Rejection] =
  ## Directive lines, declarations up to their `;`, and the linkage wrapper's
  ## `extern "C" {` and `}`.
  var us: seq[Unit] = @[]
  var i = 0
  while i < toks.len:
    let t = toks[i]
    if t.lineStart and t.isP("#"):
      var u = Unit(kind: ukDirective, line: t.line, toks: @[])
      inc i
      while i < toks.len and not toks[i].lineStart:
        u.toks.add(toks[i])
        inc i
      us.add(u)
      continue
    if t.isId("extern") and i + 2 < toks.len and toks[i + 1].kind == tkString and
        toks[i + 1].text == "\"C\"" and toks[i + 2].isP("{"):
      us.add(Unit(kind: ukExternOpen, line: t.line, toks: toks[i .. i + 2]))
      i += 3
      continue
    if t.isP("}"):
      us.add(Unit(kind: ukCloseBrace, line: t.line, toks: @[t]))
      inc i
      continue
    var u = Unit(kind: ukDeclaration, line: t.line, toks: @[])
    var depth = 0
    var done = false
    while i < toks.len and not done:
      let c = toks[i]
      if c.lineStart and c.isP("#"):
        return err(
          reject(
            rkConditional,
            header,
            c.line,
            "a directive inside a declaration that begins at line " & $u.line,
          )
        )
      u.toks.add(c)
      if c.isP("{") or c.isP("("):
        inc depth
      elif c.isP("}") or c.isP(")"):
        dec depth
      elif c.isP(";") and depth == 0:
        done = true
      inc i
    if not done:
      return err(reject(rkOutsideSubset, header, u.line, "a declaration without its ;"))
    us.add(u)
  ok(us)

proc directiveName(u: Unit): string =
  if u.toks.len > 0 and u.toks[0].kind == tkIdent:
    u.toks[0].text
  else:
    ""

type Parser = object
  header: string
  us: seq[Unit]
  i: int
  linkage: int ## open linkage wrappers
  sawLinkage: bool

proc outside(p: Parser, line: int, msg: string): Rejection =
  reject(rkOutsideSubset, p.header, line, msg)

proc parseType(
    p: Parser, toks: openArray[Token], i: var int, allowStruct: bool
): Result[CType, Rejection] =
  ## `[const] base` where base is one identifier or `struct tag`.
  var t = CType()
  if i < toks.len and toks[i].isId("const"):
    t.isConst = true
    inc i
  if i >= toks.len or toks[i].kind != tkIdent:
    let line =
      if i < toks.len:
        toks[i].line
      else:
        toks[^1].line
    return err(p.outside(line, "a declaration without its type name"))
  let b = toks[i]
  if b.text in NeverAllowed:
    return err(p.outside(b.line, b.text & " is outside the C subset (INTERFACE §3.1)"))
  if b.text == "union":
    return err(p.outside(b.line, "a union outside a canonical choice"))
  if b.text == "struct":
    if not allowStruct or i + 1 >= toks.len or toks[i + 1].kind != tkIdent:
      return err(p.outside(b.line, "a struct type outside a typedef"))
    t.base = "struct " & toks[i + 1].text
    i += 2
  else:
    t.base = b.text
    inc i
  if i < toks.len and toks[i].isId("const"):
    return err(p.outside(toks[i].line, "const after the type name"))
  ok(t)

proc parseDeclarator(
    p: Parser, toks: openArray[Token], i: var int, t: var CType
): Result[string, Rejection] =
  ## `*`... name [`[N]`]; one `* const *` is allowed (`const char* const*`).
  while i < toks.len and toks[i].isP("*"):
    inc t.pointers
    inc i
    if i < toks.len and toks[i].isId("const") and t.pointers == 1 and not t.constPtr and
        i + 1 < toks.len and toks[i + 1].isP("*"):
      t.constPtr = true
      inc i
    elif i < toks.len and (toks[i].isId("const") or toks[i].isId("restrict")):
      return err(p.outside(toks[i].line, "a qualified pointer"))
  if i >= toks.len or toks[i].kind != tkIdent:
    let line =
      if i < toks.len:
        toks[i].line
      else:
        toks[^1].line
    return err(p.outside(line, "a declarator without a name"))
  let name = toks[i].text
  if name in NeverAllowed:
    return err(p.outside(toks[i].line, name & " is outside the C subset"))
  inc i
  if i < toks.len and toks[i].isP("["):
    if i + 2 >= toks.len or toks[i + 1].kind != tkNumber or not toks[i + 2].isP("]"):
      return
        err(p.outside(toks[i].line, "an array bound that is not one decimal constant"))
    let n = toks[i + 1].text
    for c in n:
      if c notin {'0' .. '9'} or (n.len > 1 and n[0] == '0'):
        return err(
          p.outside(toks[i].line, "an array bound that is not one decimal constant")
        )
    if n.len > 9:
      return
        err(reject(rkLimit, p.header, toks[i].line, "an array bound above 999999999"))
    t.arrayLen =
      try:
        parseInt(n)
      except ValueError:
        0
    if t.arrayLen == 0:
      t.arrayLen = -1
    i += 3
  ok(name)

proc arrayBound(p: Parser, toks: openArray[Token], i: var int): Result[int, Rejection] =
  ## `[N]` with one decimal constant; -1 for `[0]`.
  if i + 2 >= toks.len or toks[i + 1].kind != tkNumber or not toks[i + 2].isP("]"):
    return
      err(p.outside(toks[i].line, "an array bound that is not one decimal constant"))
  let n = toks[i + 1].text
  for c in n:
    if c notin {'0' .. '9'} or (n.len > 1 and n[0] == '0'):
      return
        err(p.outside(toks[i].line, "an array bound that is not one decimal constant"))
  if n.len > 9:
    return
      err(reject(rkLimit, p.header, toks[i].line, "an array bound above 999999999"))
  var v =
    try:
      parseInt(n)
    except ValueError:
      0
  if v == 0:
    v = -1
  i += 3
  ok(v)

proc parseMembers(
    p: Parser, toks: openArray[Token], i: var int, inUnion: bool
): Result[seq[CMember], Rejection] =
  ## Members between `{` (already consumed) and the matching `}` (consumed).
  var ms: seq[CMember] = @[]
  while true:
    if i >= toks.len:
      return err(p.outside(toks[^1].line, "a struct without its closing brace"))
    if toks[i].isP("}"):
      inc i
      return ok(ms)
    let line = toks[i].line
    if toks[i].isId("union"):
      if inUnion or i + 1 >= toks.len or not toks[i + 1].isP("{"):
        return err(p.outside(line, "a union outside the choice value form"))
      i += 2
      let arms = ?p.parseMembers(toks, i, true)
      if i + 1 >= toks.len or toks[i].kind != tkIdent or not toks[i + 1].isP(";"):
        return err(p.outside(line, "a union without one member name"))
      ms.add(
        CMember(
          name: toks[i].text,
          line: line,
          isUnion: true,
          unionMembers: arms,
          ctype: CType(),
        )
      )
      i += 2
      continue
    var t = ?p.parseType(toks, i, false)
    let name = ?p.parseDeclarator(toks, i, t)
    if i >= toks.len or not toks[i].isP(";"):
      let at =
        if i < toks.len:
          toks[i].line
        else:
          line
      return err(
        p.outside(at, "member " & name & ": one declarator per member, no bit-field")
      )
    inc i
    ms.add(CMember(ctype: t, name: name, line: line, unionMembers: @[]))

proc parseParams(
    p: Parser, toks: openArray[Token], i: var int
): Result[(seq[CMember], bool), Rejection] =
  ## `(void)` or `(T a, T b, ...)`; `(` already consumed, `)` consumed here.
  var ps: seq[CMember] = @[]
  if i + 1 < toks.len and toks[i].isId("void") and toks[i + 1].isP(")"):
    i += 2
    return ok((ps, true))
  if i < toks.len and toks[i].isP(")"):
    return err(p.outside(toks[i].line, "an empty parameter list: write (void)"))
  while true:
    let line =
      if i < toks.len:
        toks[i].line
      else:
        toks[^1].line
    var t = ?p.parseType(toks, i, false)
    var name = ""
    if i + 4 < toks.len and toks[i].isP("(") and toks[i + 1].isP("*") and
        toks[i + 2].kind == tkIdent and toks[i + 3].isP(")") and toks[i + 4].isP("["):
      # [SPEC INTERFACE §2.4] an exact-size byte string: `T (*name)[N]`
      name = toks[i + 2].text
      i += 4
      t.arrayLen = ?p.arrayBound(toks, i)
      t.ptrToArray = true
    else:
      name = ?p.parseDeclarator(toks, i, t)
      if t.arrayLen != 0:
        return err(p.outside(line, "an array parameter"))
    ps.add(CMember(ctype: t, name: name, line: line, unionMembers: @[]))
    if i < toks.len and toks[i].isP(","):
      inc i
      continue
    if i < toks.len and toks[i].isP(")"):
      inc i
      return ok((ps, false))
    return err(p.outside(line, "a parameter list outside the subset"))

proc parseDeclaration(p: Parser, u: Unit): Result[CItem, Rejection] =
  let toks = u.toks
  var i = 0
  var item = CItem(line: u.line, tokens: @[], members: @[], params: @[], children: @[])
  if toks[0].isId("typedef"):
    i = 1
    # A method typedef: typedef T (*name)(params);
    var probe = i
    let ret = ?p.parseType(toks, probe, true)
    var ptrs = 0
    while probe < toks.len and toks[probe].isP("*"):
      inc ptrs
      inc probe
    if probe < toks.len and toks[probe].isP("("):
      if probe + 3 >= toks.len or not toks[probe + 1].isP("*") or
          toks[probe + 2].kind != tkIdent or not toks[probe + 3].isP(")") or
          probe + 4 >= toks.len or not toks[probe + 4].isP("("):
        return
          err(p.outside(u.line, "a function pointer outside the method typedef form"))
      item.kind = ciFnTypedef
      item.ctype = ret
      item.ctype.pointers = ptrs
      item.name = toks[probe + 2].text
      i = probe + 5
      let (ps, isVoid) = ?p.parseParams(toks, i)
      item.params = ps
      item.voidParams = isVoid
    elif ret.base.startsWith("struct ") and probe < toks.len and toks[probe].isP("{"):
      item.kind = ciStruct
      item.tag = ret.base[7 .. ^1]
      if ret.isConst or ptrs > 0:
        return err(p.outside(u.line, "a qualified struct definition"))
      i = probe + 1
      item.members = ?p.parseMembers(toks, i, false)
      if i >= toks.len or toks[i].kind != tkIdent:
        return err(p.outside(u.line, "a struct typedef without its name"))
      item.name = toks[i].text
      inc i
    else:
      var t = ret
      i = probe - ptrs
      t.pointers = 0
      let name = ?p.parseDeclarator(toks, i, t)
      item.name = name
      if t.base.startsWith("struct "):
        if t.isConst or t.pointers > 0 or t.arrayLen != 0:
          return err(p.outside(u.line, "a struct typedef that is not a plain forward"))
        item.kind = ciForward
        item.tag = t.base[7 .. ^1]
      else:
        item.kind = ciAlias
        item.ctype = t
  elif toks[0].isId("struct"):
    if toks.len < 3 or toks[1].kind != tkIdent or not toks[2].isP("{"):
      return err(p.outside(u.line, "a struct declaration outside the subset"))
    item.kind = ciStruct
    item.tag = toks[1].text
    i = 3
    item.members = ?p.parseMembers(toks, i, false)
  else:
    var t = ?p.parseType(toks, i, false)
    let name = ?p.parseDeclarator(toks, i, t)
    if t.arrayLen != 0 or i >= toks.len or not toks[i].isP("("):
      return err(
        p.outside(
          u.line, "a declaration outside the subset (a variable or object): " & name
        )
      )
    inc i
    let (ps, isVoid) = ?p.parseParams(toks, i)
    item.kind = ciFunction
    item.ctype = t
    item.name = name
    item.params = ps
    item.voidParams = isVoid
  if i != toks.len - 1 or not toks[i].isP(";"):
    let at =
      if i < toks.len:
        toks[i].line
      else:
        u.line
    return err(p.outside(at, "unexpected tokens before the end of the declaration"))
  ok(item)

proc definedTerm(toks: openArray[Token], i: var int, name: var string): bool =
  ## `! defined ( X )` or `! defined X`
  if i + 1 >= toks.len or not toks[i].isP("!") or not toks[i + 1].isId("defined"):
    return false
  i += 2
  if i + 2 < toks.len and toks[i].isP("(") and toks[i + 1].kind == tkIdent and
      toks[i + 2].isP(")"):
    name = toks[i + 1].text
    i += 3
    return true
  if i < toks.len and toks[i].kind == tkIdent:
    name = toks[i].text
    inc i
    return true
  false

proc checkTerm(
    toks: openArray[Token],
    i: var int,
    name: var string,
    value: var seq[Token],
    last: bool,
): bool =
  ## `!defined(X) || X != <value>`, then `||` unless `last`.
  if not definedTerm(toks, i, name):
    return false
  if i + 2 >= toks.len or not toks[i].isP("||") or not toks[i + 1].isId(name) or
      not toks[i + 2].isP("!="):
    return false
  i += 3
  value = @[]
  while i < toks.len and not toks[i].isP("||"):
    value.add(toks[i])
    inc i
  if value.len == 0:
    return false
  if last:
    return i == toks.len
  if i < toks.len and toks[i].isP("||"):
    inc i
    return true
  false

proc expectDirective(p: var Parser, name: string): Result[Unit, Rejection] =
  if p.i >= p.us.len or p.us[p.i].kind != ukDirective or p.us[p.i].directiveName != name:
    let line =
      if p.i < p.us.len:
        p.us[p.i].line
      else:
        p.us[^1].line
    return err(reject(rkConditional, p.header, line, "#" & name & " expected here"))
  let u = p.us[p.i]
  inc p.i
  ok(u)

proc parseBlock(
    p: var Parser, items: var seq[CItem], inGuard: bool
): Result[string, Rejection] =
  ## Items until `#endif` or `#else` (returned, not consumed) or the end ("").
  while p.i < p.us.len:
    let u = p.us[p.i]
    case u.kind
    of ukDeclaration:
      items.add(?p.parseDeclaration(u))
      inc p.i
    of ukExternOpen, ukCloseBrace:
      return err(
        reject(
          rkConditional, p.header, u.line,
          "extern \"C\" and its closing brace only inside #ifdef __cplusplus",
        )
      )
    of ukDirective:
      let d = u.directiveName
      let t = u.toks
      case d
      of "endif", "else":
        return ok(d)
      of "include":
        if inGuard:
          return err(
            reject(
              rkConditional, p.header, u.line,
              "an include inside a document guard (INTERFACE §3.2 l.2325)",
            )
          )
        var item = CItem(kind: ciInclude, line: u.line)
        if t.len == 2 and t[1].kind == tkString and t[1].text.startsWith("\""):
          item.name = t[1].text[1 .. ^2]
        elif t.len >= 3 and t[1].isP("<") and t[^1].isP(">"):
          item.angle = true
          for k in 2 ..< t.len - 1:
            if t[k].spaceBefore:
              return err(
                reject(rkIncludeForm, p.header, u.line, "a space in an angle include")
              )
            item.name.add(t[k].text)
        else:
          return err(
            reject(
              rkIncludeForm, p.header, u.line,
              "an include that is not one literal quoted or angle header name",
            )
          )
        items.add(item)
        inc p.i
      of "define":
        if t.len < 2 or t[1].kind != tkIdent:
          return err(p.outside(u.line, "#define without a name"))
        if t[1].text in StandardMacros:
          return err(
            reject(
              rkStandardMacro,
              p.header,
              u.line,
              "a header must not redefine " & t[1].text & " (INTERFACE §3.5 l.2569)",
            )
          )
        if t.len > 2 and t[2].isP("(") and not t[2].spaceBefore:
          return err(p.outside(u.line, "a function-like macro " & t[1].text))
        items.add(
          CItem(kind: ciDefine, line: u.line, name: t[1].text, tokens: t[2 .. ^1])
        )
        inc p.i
      of "if":
        if inGuard:
          return err(
            reject(rkConditional, p.header, u.line, "a check inside a document guard")
          )
        var k = 1
        var name = ""
        var value: seq[Token] = @[]
        if not checkTerm(t, k, name, value, true):
          return err(
            reject(
              rkConditional,
              p.header,
              u.line,
              "a conditional outside the subset: #" & spelled(t),
            )
          )
        inc p.i
        discard ?p.expectDirective("error")
        discard ?p.expectDirective("endif")
        if name == "LOGOS_C_MAPPING_REVISION":
          items.add(
            CItem(kind: ciRevisionCheck, line: u.line, name: name, tokens: value)
          )
        elif name.startsWith("LOGOS_C_CONTEXT_"):
          items.add(
            CItem(kind: ciContextCheck, line: u.line, name: name, tokens: value)
          )
        else:
          return err(
            reject(
              rkConditional, p.header, u.line, "a check of an unknown macro " & name
            )
          )
      of "ifdef":
        if t.len != 2 or t[1].kind != tkIdent:
          return err(reject(rkConditional, p.header, u.line, "#ifdef without one name"))
        let m = t[1].text
        if m == "__cplusplus":
          inc p.i
          if p.i >= p.us.len:
            return err(
              reject(rkConditional, p.header, u.line, "#ifdef __cplusplus at the end")
            )
          let body = p.us[p.i]
          if body.kind == ukExternOpen:
            if inGuard:
              return err(
                reject(
                  rkConditional, p.header, u.line, "the linkage wrapper inside a guard"
                )
              )
            inc p.i
            discard ?p.expectDirective("endif")
            inc p.linkage
            p.sawLinkage = true
          elif body.kind == ukCloseBrace:
            if p.linkage == 0:
              return err(
                reject(
                  rkConditional, p.header, u.line, "a linkage close without its open"
                )
              )
            inc p.i
            discard ?p.expectDirective("endif")
            dec p.linkage
          else:
            return err(
              reject(
                rkConditional, p.header, body.line,
                "declarations that vary with the language (INTERFACE §3.1 l.2272)",
              )
            )
        elif m.startsWith("LOGOS_DOCUMENT_") and m.endsWith("_DEFINED"):
          if inGuard:
            return
              err(reject(rkConditional, p.header, u.line, "a nested document guard"))
          let c = m["LOGOS_DOCUMENT_".len .. m.len - 1 - "_DEFINED".len]
          inc p.i
          var item = CItem(kind: ciDocumentGuard, line: u.line, name: c, children: @[])
          let chk = ?p.expectDirective("if")
          var k = 1
          for r in 0 .. 3:
            var name = ""
            var value: seq[Token] = @[]
            if not checkTerm(chk.toks, k, name, value, r == 3) or
                name != "LOGOS_DOCUMENT_" & c & "_ROOT_" & $r or value.len != 1:
              return err(
                reject(
                  rkIdentity,
                  p.header,
                  chk.line,
                  "the identity check of " & c &
                    " is not the four-root form (INTERFACE §3.2 l.2319-2321)",
                )
              )
            item.roots[r] = value[0].text
          discard ?p.expectDirective("error")
          discard ?p.expectDirective("endif")
          discard ?p.expectDirective("else")
          let def = ?p.expectDirective("define")
          if def.toks.len != 3 or not def.toks[1].isId(m) or def.toks[2].text != "1":
            return err(
              reject(
                rkIdentity, p.header, def.line, m & " must be defined as 1 (l.2321)"
              )
            )
          for r in 0 .. 3:
            let rd = ?p.expectDirective("define")
            if rd.toks.len != 3 or
                not rd.toks[1].isId("LOGOS_DOCUMENT_" & c & "_ROOT_" & $r):
              return err(
                reject(
                  rkIdentity,
                  p.header,
                  rd.line,
                  "root macro " & $r & " of " & c & " expected (l.2321)",
                )
              )
            item.defined[r] = rd.toks[2].text
          let stop = ?p.parseBlock(item.children, true)
          if stop != "endif":
            return err(
              reject(
                rkConditional, p.header, u.line, "a document guard without its #endif"
              )
            )
          inc p.i
          items.add(item)
        else:
          return err(
            reject(
              rkConditional,
              p.header,
              u.line,
              "a conditional outside the subset: #ifdef " & m,
            )
          )
      else:
        return err(
          reject(
            rkConditional,
            p.header,
            u.line,
            "a directive outside the subset: #" & spelled(t),
          )
        )
  ok("")

proc guardedFrameItem(items: seq[CItem]): int =
  ## [SPEC INTERFACE §3.2 l.2325] The first item a file-level include guard must
  ## not enclose: a contract-header dependency include, or a mapping, context or
  ## document identity check. The fixed `logos_types.h` include and the standard
  ## headers are not contract-header includes (l.2298). -1 when there is none.
  for k, it in items:
    case it.kind
    of ciInclude:
      if not it.angle and it.name != "logos_types.h":
        return k
    of ciRevisionCheck, ciContextCheck, ciDocumentGuard:
      return k
    else:
      discard
  -1

proc parseHeader*(name, source: string): Result[ParsedHeader, Rejection] =
  ## [SPEC INTERFACE §3.1] One header body's items, or the reason it is outside
  ## the accepted C subset.
  let toks = ?lex(name, source)
  var us = ?units(name, toks)
  var guard = ""
  # [IMPL-DECISION G317] a file-level include guard
  if us.len >= 3 and us[0].kind == ukDirective and us[0].directiveName == "ifndef" and
      us[0].toks.len == 2 and us[0].toks[1].kind == tkIdent and us[1].kind == ukDirective and
      us[1].directiveName == "define" and us[1].toks.len == 2 and
      us[1].toks[1].isId(us[0].toks[1].text) and us[^1].kind == ukDirective and
      us[^1].directiveName == "endif" and us[^1].toks.len == 1:
    guard = us[0].toks[1].text
    if guard.startsWith("LOGOS_"):
      return err(
        reject(
          rkConditional, name, us[0].line, "a LOGOS_ name as a file-level include guard"
        )
      )
    us = us[2 ..^ 2]
  var p = Parser(header: name, us: us, i: 0)
  var items: seq[CItem] = @[]
  let stop = ?p.parseBlock(items, false)
  if stop.len > 0:
    return
      err(reject(rkConditional, name, p.us[p.i].line, "#" & stop & " without its #if"))
  if p.linkage != 0:
    return err(reject(rkConditional, name, 0, "the linkage wrapper is not closed"))
  if guard.len > 0:
    let k = guardedFrameItem(items)
    if k >= 0:
      return err(
        reject(
          rkConditional,
          name,
          items[k].line,
          "a file-level include guard around a contract-header include or a check " &
            "(INTERFACE §3.2 l.2325)",
        )
      )
  ok(ParsedHeader(name: name, items: items, linkage: p.sawLinkage, includeGuard: guard))

func render*(m: CMember): string =
  ## A member or parameter without its line: `ctype name` or `union {…} name`.
  if m.isUnion:
    var arms: seq[string] = @[]
    for a in m.unionMembers:
      arms.add(render(a))
    "union { " & arms.join("; ") & " } " & m.name
  else:
    $m.ctype & " " & m.name

func render*(it: CItem): string =
  ## [IMPL-DECISION G319] An item's normalized spelling, independent of lines,
  ## whitespace and comments.
  case it.kind
  of ciInclude:
    "#include " & (if it.angle: "<" & it.name & ">" else: "\"" & it.name & "\"")
  of ciDefine:
    "#define " & it.name & (if it.tokens.len > 0: " " & spelled(it.tokens)
    else: "")
  of ciRevisionCheck, ciContextCheck:
    "#check " & it.name & " != " & spelled(it.tokens)
  of ciDocumentGuard:
    var kids: seq[string] = @[]
    for c in it.children:
      kids.add(render(c))
    "#guard " & it.name & " [" & it.roots.join(" ") & "] [" & it.defined.join(" ") &
      "] { " & kids.join(" | ") & " }"
  of ciAlias:
    "typedef " & $it.ctype & " " & it.name
  of ciForward:
    "typedef struct " & it.tag & " " & it.name
  of ciStruct:
    var ms: seq[string] = @[]
    for m in it.members:
      ms.add(render(m))
    "struct " & it.tag & " { " & ms.join("; ") & " }" &
      (if it.name.len > 0: " " & it.name else: "")
  of ciFnTypedef, ciFunction:
    var ps: seq[string] = @[]
    for p in it.params:
      ps.add(render(p))
    (if it.kind == ciFnTypedef: "typedef " else: "") & $it.ctype & " " &
      (if it.kind == ciFnTypedef: "(*" & it.name & ")"
      else: it.name) & "(" & (if it.voidParams: "void" else: ps.join(", ")) & ")"

func `$`*(h: ParsedHeader): string =
  ## The header's logical name and its items, one per line.
  var s = h.name & ":"
  for it in h.items:
    s.add("\n  " & render(it))
  s
