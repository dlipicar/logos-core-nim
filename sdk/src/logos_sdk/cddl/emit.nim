## CDDL text for one reconstructed Logos schema document.
##
## [SPEC INTERFACE §3, §3.8] The reverse mapper (`iface/rmap`) reconstructs each
## schema document as this small syntax tree and prints it; acceptance then
## parses the text like any other construction input, so the printed document is
## exactly what is committed. Printing is deterministic: the metadata block,
## then the declarations in the order given. Layout, comments and declaration
## order are not schema identity inputs (IF §3.8 l.2633).
##
## [IMPL-DECISION G320] `compact` prints the same document with no layout, for a
## document whose ordinary layout would pass a §5.3 byte limit.
##
## [IMPL-DECISION G320] A map field name is written as a bare key, except a name
## that a CDDL reader could take for a type or a value: an RFC 8610 Appendix D or
## Logos prelude name, or `true`, `false`, `null`, `nil`, `undefined`. Those are
## written as text keys (`"uint": tstr`), which name the same member (RFC 8610
## §3.5.1; cdCDDLe §5.1, §7.4). Text literals escape `"`, `\`, controls, C1
## controls and U+10FFFE/U+10FFFF (RFC 9682 §2.1.1); every other character is
## written as UTF-8.

{.push raises: [].}

import std/strutils

type
  ENodeKind* = enum
    enPrim ## a prelude name: `bool`, `uint8` ... `int64`, `tstr`, `bstr`
    enSized ## `tstr .size …` or `bstr .size …`
    enBool
    enInt
    enText
    enMap
    enList ## `[* T]`
    enTuple ## `[a, b]`, `[]`
    enChoice
    enRef ## a qualified declaration name

  EField* = object
    name*: string
    optional*: bool
    node*: ENode

  ENode* = ref object
    case kind*: ENodeKind
    of enPrim:
      prim*: string
    of enSized:
      base*: string ## `tstr` or `bstr`
      lo*, hi*: uint64
    of enBool:
      boolean*: bool
    of enInt:
      negative*: bool
      magnitude*: uint64 ## the absolute value
    of enText:
      text*: string
    of enMap:
      fields*: seq[EField]
    of enList:
      element*: ENode
    of enTuple:
      items*: seq[ENode]
    of enChoice:
      arms*: seq[ENode]
    of enRef:
      target*: string

  EDeclaration* = object
    name*: string ## qualified
    node*: ENode

  EDocument* = object
    module*: string ## `_module`, "" when absent
    iface*: string ## `_interface`, "" when absent
    implements*: seq[string] ## 64 lowercase hex digits each, in `_implements` order
    sensitive*: seq[string] ## `_sensitive`, in order
    declarations*: seq[EDeclaration]

const QuotedKeys* = [
  # RFC 8610 Appendix D names a field name can spell
  "any",
  "uint",
  "nint",
  "int",
  "bstr",
  "bytes",
  "tstr",
  "text",
  "tdate",
  "time",
  "number",
  "biguint",
  "bignint",
  "bigint",
  "integer",
  "unsigned",
  "decfrac",
  "bigfloat",
  "eb64url",
  "eb64legacy",
  "eb16",
  "uri",
  "b64url",
  "b64legacy",
  "regexp",
  "float16",
  "float32",
  "float64",
  "float",
  "bool",
  # value keywords
  "true",
  "false",
  "null",
  "nil",
  "undefined",
  # the Logos prelude (INTERFACE §1.3)
  "uint8",
  "uint16",
  "uint32",
  "uint64",
  "int8",
  "int16",
  "int32",
  "int64",
] ## [IMPL-DECISION G320]

func cddlText*(s: string): string =
  ## A CDDL text literal with exactly the bytes of `s` (valid UTF-8).
  var o = "\""
  var i = 0
  while i < s.len:
    let c = s[i]
    case c
    of '"':
      o.add("\\\"")
    of '\\':
      o.add("\\\\")
    of '\0' .. '\x1F', '\x7F':
      o.add("\\u" & toHex(ord(c), 4).toLowerAscii)
    of '\xC2':
      if i + 1 < s.len and s[i + 1] in {'\x80' .. '\x9F'}:
        o.add("\\u" & toHex(ord(s[i + 1]), 4).toLowerAscii)
        inc i
      else:
        o.add(c)
    of '\xF4':
      if i + 3 < s.len and s[i + 1] == '\x8F' and s[i + 2] == '\xBF' and
          s[i + 3] in {'\xBE', '\xBF'}:
        o.add(if s[i + 3] == '\xBE': "\\u{10fffe}" else: "\\u{10ffff}")
        i += 3
      else:
        o.add(c)
    else:
      o.add(c)
    inc i
  o & "\""

func key(name: string): string =
  if name in QuotedKeys:
    cddlText(name)
  else:
    name

func emitNode(n: ENode, indent: int, compact: bool, inChoice = false): string

func emitFields(fs: seq[EField], indent: int, compact: bool): string =
  if fs.len == 0:
    return "{}"
  if compact:
    var parts: seq[string] = @[]
    for f in fs:
      parts.add(
        (if f.optional: "?" else: "") & key(f.name) & ":" &
          emitNode(f.node, indent, compact)
      )
    return "{" & parts.join(",") & "}"
  let pad = repeat(' ', indent + 2)
  var s = "{\n"
  for f in fs:
    s.add(
      pad & (if f.optional: "? " else: "") & key(f.name) & ": " &
        emitNode(f.node, indent + 2, compact) & ",\n"
    )
  s & repeat(' ', indent) & "}"

func emitNode(n: ENode, indent: int, compact: bool, inChoice = false): string =
  case n.kind
  of enPrim:
    n.prim
  of enSized:
    if n.lo == n.hi:
      n.base & " .size " & $n.lo
    else:
      n.base & " .size (" & $n.lo & ".." & $n.hi & ")"
  of enBool:
    if n.boolean: "true" else: "false"
  of enInt:
    (if n.negative: "-" else: "") & $n.magnitude
  of enText:
    cddlText(n.text)
  of enMap:
    emitFields(n.fields, indent, compact)
  of enList:
    (if compact: "[*" else: "[* ") & emitNode(n.element, indent, compact) & "]"
  of enTuple:
    var parts: seq[string] = @[]
    for x in n.items:
      parts.add(emitNode(x, indent, compact))
    "[" & parts.join(if compact: "," else: ", ") & "]"
  of enChoice:
    var parts: seq[string] = @[]
    for a in n.arms:
      parts.add(emitNode(a, indent, compact, true))
    let s = parts.join(if compact: "/" else: " / ")
    if inChoice:
      "(" & s & ")"
    else:
      s
  of enRef:
    n.target

func emit*(d: EDocument, compact = false): string =
  ## The document's CDDL source: its metadata block, then its declarations.
  let eq = if compact: "=" else: " = "
  var s = ""
  if not compact and (
    d.module.len > 0 or d.iface.len > 0 or d.implements.len > 0 or d.sensitive.len > 0
  ):
    s.add("; -- metadata --\n")
  if d.module.len > 0:
    s.add("_module" & eq & cddlText(d.module) & "\n")
  if d.iface.len > 0:
    s.add("_interface" & eq & cddlText(d.iface) & "\n")
  if d.implements.len > 0:
    if compact:
      var roots: seq[string] = @[]
      for r in d.implements:
        roots.add("h'" & r & "'")
      s.add("_implements=[" & roots.join(",") & "]\n")
    else:
      s.add("_implements = [\n")
      for r in d.implements:
        s.add("  h'" & r & "',\n")
      s.add("]\n")
  if d.sensitive.len > 0:
    var names: seq[string] = @[]
    for n in d.sensitive:
      names.add(cddlText(n))
    s.add("_sensitive" & eq & "[" & names.join(if compact: "," else: ", ") & "]\n")
  for decl in d.declarations:
    if s.len > 0 and not compact:
      s.add("\n")
    s.add(decl.name & eq & emitNode(decl.node, 0, compact) & "\n")
  s
