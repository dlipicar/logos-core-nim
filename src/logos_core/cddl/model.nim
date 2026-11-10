## The canonical CDDL schema model of cdCDDLe §6-§8.

{.push raises: [].}

import results

export results

type
  CddlErrorClass* = enum
    ## G16 error classes.
    ecSyntax = "syntax" ## not CDDL (RFC 8610 Appendix B)
    ecUnsupported = "unsupported" ## CDDL outside the cdCDDLe §5.1 subset
    ecResolution = "resolution" ## undefined, duplicate or reserved names
    ecCanonical = "canonical" ## a rule of cdCDDLe §6-§8 is violated
    ecDecode = "decode" ## bytes that are not a canonical model (cdCDDLe §10)

  CddlError* = object
    class*: CddlErrorClass
    line*: int ## 1-based source line, 0 when not from source text
    col*: int
    msg*: string

  Primitive* = enum
    pUint = "uint"
    pBool = "bool"
    pTstr = "tstr"
    pBstr = "bstr"

  LiteralKind* = enum
    lkUint = "uint"
    lkNint = "nint"
    lkBool = "bool"
    lkTstr = "tstr"
    lkBstr = "bstr"

  Literal* = object
    case kind*: LiteralKind
    of lkUint:
      uint*: uint64
    of lkNint:
      nint*: uint64 ## the value is -1 - `nint`
    of lkBool:
      boolean*: bool
    of lkTstr:
      text*: string
    of lkBstr:
      bytes*: seq[byte]

  Occurrence* = enum
    occOne ## no occurrence node
    occOptional ## `?`: bounds 0 and 1
    occUnbounded ## `*`: bounds 0 and "unbounded"

  TypeKind* = enum
    tkReference
    tkPrimitive
    tkLiteral
    tkArray
    tkMap
    tkChoice
    tkRange
    tkSize

  CddlType* = ref object
    case kind*: TypeKind
    of tkReference:
      name*: string
    of tkPrimitive:
      primitive*: Primitive
    of tkLiteral:
      literal*: Literal
    of tkArray, tkMap:
      members*: seq[Member]
    of tkChoice:
      alternatives*: seq[CddlType]
    of tkRange:
      low*, high*: Literal ## integer literals, low < high
    of tkSize:
      target*: Primitive ## uint, tstr or bstr
      controller*: CddlType ## a uint literal, or a range with non-negative bounds

  Member* = object
    key*: Opt[string] ## present exactly for map members
    typ*: CddlType
    occurrence*: Occurrence

  Rule* = object
    name*: string
    typ*: CddlType

  CddlDocument* = object
    rules*: seq[Rule] ## sorted by name, at least one

const
  CanonicalModelId* = "cdcddle"
  PreludeNames* = [
    # RFC 8610 Appendix D. Only the four primitives and `true`/`false` are in the
    # cdCDDLe §5.1 subset; a document may not redefine any of them.
    "any", "uint", "nint", "int", "bstr", "bytes", "tstr", "text", "tdate", "time",
    "number", "biguint", "bignint", "bigint", "integer", "unsigned", "decfrac",
    "bigfloat", "eb64url", "eb64legacy", "eb16", "encoded-cbor", "uri", "b64url",
    "b64legacy", "regexp", "mime-message", "cbor-any", "float16", "float32", "float64",
    "float16-32", "float32-64", "float", "false", "true", "bool", "nil", "null",
    "undefined",
  ]

func parsePrimitive*(name: string): Opt[Primitive] =
  case name
  of "uint":
    Opt.some(pUint)
  of "bool":
    Opt.some(pBool)
  of "tstr":
    Opt.some(pTstr)
  of "bstr":
    Opt.some(pBstr)
  else:
    Opt.none(Primitive)

func isPreludeName*(name: string): bool =
  name in PreludeNames

func uintLiteral*(v: uint64): Literal =
  Literal(kind: lkUint, uint: v)

func nintLiteral*(n: uint64): Literal =
  Literal(kind: lkNint, nint: n)

func boolLiteral*(v: bool): Literal =
  Literal(kind: lkBool, boolean: v)

func textLiteral*(v: string): Literal =
  Literal(kind: lkTstr, text: v)

func bytesLiteral*(v: seq[byte]): Literal =
  Literal(kind: lkBstr, bytes: v)

func cddlError*(class: CddlErrorClass, msg: string, line = 0, col = 0): CddlError =
  CddlError(class: class, line: line, col: col, msg: msg)

func `$`*(e: CddlError): string =
  let at =
    if e.line > 0:
      " at " & $e.line & ":" & $e.col
    else:
      ""
  $e.class & at & ": " & e.msg

func isIntegerLiteral*(l: Literal): bool =
  l.kind in {lkUint, lkNint}

func cmpInteger*(a, b: Literal): int =
  ## Order of two integer literals by value.
  doAssert a.isIntegerLiteral and b.isIntegerLiteral
  if a.kind != b.kind:
    return (if a.kind == lkNint: -1 else: 1)
  if a.kind == lkUint:
    cmp(a.uint, b.uint)
  else:
    cmp(b.nint, a.nint)

func isIdentifier*(s: string): bool =
  ## RFC 8610 `id = EALPHA *(*("-" / ".") (EALPHA / DIGIT))`.
  const ealpha = {'A' .. 'Z', 'a' .. 'z', '@', '_', '$'}
  if s.len == 0 or s[0] notin ealpha:
    return false
  if s[^1] notin ealpha + {'0' .. '9'}:
    return false
  for c in s:
    if c notin ealpha + {'0' .. '9', '-', '.'}:
      return false
  true

func `==`*(a, b: Literal): bool =
  if a.kind != b.kind:
    return false
  case a.kind
  of lkUint:
    a.uint == b.uint
  of lkNint:
    a.nint == b.nint
  of lkBool:
    a.boolean == b.boolean
  of lkTstr:
    a.text == b.text
  of lkBstr:
    a.bytes == b.bytes
