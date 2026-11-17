## INTERFACE §3 (Canonical C-to-CDDL Mapping): the reverse mapper. The input set
## and its includes (§3, §3.2), the accepted C subset and header frame (§2, §3.1),
## literal recognition (§3.5, §3.9), CDDL emission (§1.3, §3), and the
## reconstruction: groups, roles and binding (§3.2, §3.7), functions (§3.3),
## structs, choices, events and paths (§3.4-§3.6), the round trips (§3.8) and
## the required rejections (§3.9.5). Test ids (T1.1 ...) are those of the 5-1
## plan's §5.

import std/[algorithm, os, sequtils, strutils]
import unittest2
import ../src/logos_core/iface/[accept, cinput, cliteral, rmap]
import ../src/logos_core/iface/payload
import ../src/logos_core/cddl/emit
import ../src/logos_core/base/hex
import ../src/logos_core/hash/hashinput
import ../src/logos_core/cbor
import ./support/[ccompile, specdata]

const outDir = "build/rmap"

# Helpers ---------------------------------------------------------------------------

proc src(name, text: string): HeaderSource =
  HeaderSource(name: name, text: text)

proc readOk(sources: varargs[HeaderSource]): HeaderSet =
  let r = readSet(sources)
  if r.isErr:
    checkpoint $r.error
  r.get

proc refused(sources: varargs[HeaderSource]): RejectReason =
  ## The reason the set is rejected; fails the test when it is accepted.
  let r = readSet(sources)
  if r.isOk:
    checkpoint "accepted: " & sources.mapIt(it.name).join(", ")
    fail()
    return rkLimit
  checkpoint $r.error
  r.error.reason

proc parsedOk(text: string, name = "h.h"): ParsedHeader =
  let r = parseHeader(name, text)
  if r.isErr:
    checkpoint $r.error
  r.get

proc parseRefused(text: string, name = "h.h"): RejectReason =
  let r = parseHeader(name, text)
  if r.isOk:
    checkpoint "accepted:\n" & text
    fail()
    return rkLimit
  checkpoint $r.error
  r.error.reason

proc literal(spelling: string): Result[CScalar, Rejection] =
  let toks = lex("lit.h", spelling)
  if toks.isErr:
    return err(toks.error)
  recognizeLiteral(toks.get, "lit.h", 1)

func iv(v: int64): CScalar =
  if v < 0:
    CScalar(kind: cskInt, negative: true, magnitude: uint64(-(v + 1)) + 1)
  else:
    CScalar(kind: cskInt, negative: false, magnitude: uint64(v))

func uv(v: uint64): CScalar =
  CScalar(kind: cskInt, negative: false, magnitude: v)

func tv(s: string): CScalar =
  CScalar(kind: cskText, text: s)

func kinds(h: ParsedHeader): seq[CItemKind] =
  h.items.mapIt(it.kind)

proc generated(
    primary: string, ifaces: openArray[string] = [], supp: openArray[string] = []
): string =
  let s = acceptContractSet(primary, ifaces, supp)
  if s.isErr:
    checkpoint s.error
  let h = contractHeader(s.get.cSchemaSet)
  if h.isErr:
    checkpoint h.error
  h.get

let
  ifc392 = mirror("IFC/3.9.2.interface.cddl")
  mod392 = mirror("IFC/3.9.2.module.cddl")
  sup392 = mirror("IFC/3.9.2.supporting.cddl")

# A document guard for namespace `x` with all-zero roots around `BODY`.
const guarded =
  "#ifdef LOGOS_DOCUMENT_x_DEFINED\n" &
  "#if !defined(LOGOS_DOCUMENT_x_ROOT_0) || LOGOS_DOCUMENT_x_ROOT_0 != 0x0000000000000000ULL || \\\n" &
  "    !defined(LOGOS_DOCUMENT_x_ROOT_1) || LOGOS_DOCUMENT_x_ROOT_1 != 0x0000000000000000ULL || \\\n" &
  "    !defined(LOGOS_DOCUMENT_x_ROOT_2) || LOGOS_DOCUMENT_x_ROOT_2 != 0x0000000000000000ULL || \\\n" &
  "    !defined(LOGOS_DOCUMENT_x_ROOT_3) || LOGOS_DOCUMENT_x_ROOT_3 != 0x0000000000000000ULL\n" &
  "#error \"Conflicting Logos schema document x\"\n#endif\n#else\n" &
  "#define LOGOS_DOCUMENT_x_DEFINED 1\n" &
  "#define LOGOS_DOCUMENT_x_ROOT_0 0x0000000000000000ULL\n" &
  "#define LOGOS_DOCUMENT_x_ROOT_1 0x0000000000000000ULL\n" &
  "#define LOGOS_DOCUMENT_x_ROOT_2 0x0000000000000000ULL\n" &
  "#define LOGOS_DOCUMENT_x_ROOT_3 0x0000000000000000ULL\n" & "BODY" & "#endif\n"

# Tests -----------------------------------------------------------------------------

suite "ifc.c-reverse: the input set and its includes (INTERFACE §3, §3.2)":
  const v = "typedef uint64_t logos_x_V_t;\n"

  test "T1.1 [IFC-0791] logical names are unique, nonempty, relative paths without empty, . or .. components or backslashes":
    for bad in ["", "/a.h", "a//b.h", "./a.h", "a/../b.h", "a\\b.h", "a/", "."]:
      check refused(src(bad, v)) == rkLogicalName
    check refused(src("a.h", v), src("a.h", v)) == rkDuplicateName
    # case-sensitive: two names
    discard readOk(src("a.h", v), src("A.h", v), src("sub/dir/a.h", v))

  test "T1.2 [IFC-0792] [IFC-0793] contract includes are literal quoted names, nonempty and relative":
    check refused(src("a.h", "#define B \"b.h\"\n#include B\n"), src("b.h", v)) ==
      rkIncludeForm
    check refused(src("a.h", "#include u8\"b.h\"\n"), src("b.h", v)) == rkIncludeForm
    check refused(src("a.h", "#include <foo.h>\n")) == rkIncludeForm
    check refused(src("a.h", "#include \"\"\n")) == rkIncludeName
    check refused(src("a.h", "#include \"/b.h\"\n"), src("b.h", v)) == rkIncludeName
    check refused(src("a.h", "#include \"sub//b.h\"\n"), src("sub/b.h", v)) ==
      rkIncludeName
    check refused(src("a.h", "#include \"sub\\\\b.h\"\n"), src("sub/b.h", v)) ==
      rkIncludeName
    # [IMPL-DECISION G317] the allowed standard headers and the fixed common header
    discard readOk(
      src(
        "a.h",
        "#include <stdbool.h>\n#include <stddef.h>\n#include <stdint.h>\n" &
          "#include \"logos_types.h\"\n" & v,
      )
    )

  test "T1.3 [IFC-0794] [IFC-0795] [IFC-0797] includes resolve from the includer's directory, never above the root, to exactly one supplied name":
    let hs = readOk(
      src("sub/a.h", "#include \"../b.h\"\n#include \"./c/../d.h\"\n"),
      src("b.h", v),
      src("sub/d.h", v),
    )
    check hs.includes[0] == @[1, 2]
    check refused(src("a.h", "#include \"../b.h\"\n"), src("b.h", v)) ==
      rkIncludeAboveRoot
    check refused(src("sub/a.h", "#include \"../../b.h\"\n"), src("b.h", v)) ==
      rkIncludeAboveRoot
    # byte for byte: no case folding, no search of other directories
    check refused(src("a.h", "#include \"b.h\"\n"), src("B.h", v)) == rkIncludeMissing
    check refused(src("sub/a.h", "#include \"b.h\"\n"), src("b.h", v)) ==
      rkIncludeMissing
    check refused(src("a.h", "#include \"missing.h\"\n")) == rkIncludeMissing

  test "T1.4 [IFC-0796] the mapper never consults the filesystem":
    let dir = outDir / "fs"
    createDir(dir)
    writeFile(dir / "ondisk.h", v)
    let here = getCurrentDir()
    setCurrentDir(dir)
    defer:
      setCurrentDir(here)
    check fileExists("ondisk.h")
    check refused(src("user.h", "#include \"ondisk.h\"\n")) == rkIncludeMissing

  test "T1.5 [IFC-0783] [IFC-0798] every supplied body is parsed and kept with its macros, whether included once, twice or never":
    let hs = readOk(
      src("a.h", "#include \"b.h\"\n#include \"b.h\"\n#define LOGOS_X 1\n" & v),
      src("b.h", "#define LOGOS_B 2\n"),
      src("c.h", "#define LOGOS_C 3\n"),
    )
    check hs.headers.len == 3
    check hs.includes[0] == @[1, 1]
    check hs.headers[2].items[0].name == "LOGOS_C"
    # a's translation order splices b once, at its first inclusion
    check hs.order[0].mapIt(it.header) == @[1, 0, 0]
    # a body is validated whether or not anything includes it
    check refused(
      src("a.h", "#include \"b.h\"\n#include \"b.h\"\n"), src("b.h", "double d;\n")
    ) == rkOutsideSubset
    check refused(src("a.h", v), src("c.h", "typedef float logos_x_F_t;\n")) ==
      rkOutsideSubset
    # nor do declared identity constants: a repeated document guard's body is
    # parsed although the guard is already defined when it is reached
    check refused(
      src("a.h", guarded.replace("BODY", v)),
      src("b.h", "#include \"a.h\"\n" & guarded.replace("BODY", "double d;\n")),
    ) == rkOutsideSubset

  test "[IMPL-DECISION G317] logos_types.h is predefined, not supplied; an include cycle is rejected":
    check refused(src("logos_types.h", v)) == rkLogicalName
    check refused(src("a.h", "#include \"b.h\"\n"), src("b.h", "#include \"a.h\"\n")) ==
      rkIncludeCycle
    check refused(src("a.h", "#include \"a.h\"\n")) == rkIncludeCycle

  test "[IMPL-DECISION G321] the input limits: 1 MiB a header, 8 MiB a set, 1,024 headers, includes 64 deep":
    check refused(src("a.h", repeat(' ', MaxHeaderBytes + 1))) == rkLimit
    var many: seq[HeaderSource] = @[]
    for i in 0 .. MaxHeaders:
      many.add(src("h" & $i & ".h", ""))
    check refused(many) == rkLimit
    var big: seq[HeaderSource] = @[]
    for i in 0 .. 8:
      big.add(src("b" & $i & ".h", repeat(' ', MaxHeaderBytes)))
    check refused(big) == rkLimit
    var chain: seq[HeaderSource] = @[]
    for i in 0 .. MaxIncludeDepth + 1:
      chain.add(src("c" & $i & ".h", "#include \"c" & $(i + 1) & ".h\"\n"))
    chain.add(src("c" & $(MaxIncludeDepth + 2) & ".h", v))
    check refused(chain) == rkLimit

suite "ifc.c-reverse: the C subset and the header frame (INTERFACE §2, §3.1)":
  test "T2.1 [IFC-0784] declarations outside the subset are rejected, not treated as helpers":
    for bad in [
      "typedef double logos_x_T_t;\n", "typedef float logos_x_T_t;\n", "int x;\n",
      "uint64_t logos_x_value;\n", "static uint64_t f(void);\n",
      "typedef enum logos_x_E { A } logos_x_E_t;\n",
      "typedef struct logos_x_S_MAP {\n    uint32_t a : 3;\n} logos_x_S_t;\n",
      "typedef struct logos_x_S_MAP {\n    uint64_t a, b;\n} logos_x_S_t;\n",
      "union logos_x_U {\n    uint64_t a;\n};\n", "extern \"C\" uint64_t f(void);\n",
      "typedef unsigned long logos_x_T_t;\n", "typedef uint64_t (logos_x_T_t);\n",
      "typedef const char* const logos_x_T_t;\n", "typedef char const* logos_x_T_t;\n",
      "uint64_t f();\n", "__attribute__((unused)) typedef uint64_t logos_x_T_t;\n",
      "_Static_assert(1, \"x\");\n", "#define LOGOS_F(x) x\n",
      "typedef uint64_t logos_x_T_t\n",
    ]:
      check parseRefused(bad) == rkOutsideSubset

  test "T2.2 [IFC-0295] declarations that vary with the language or sit under another condition are rejected":
    for bad in [
      "#ifdef __cplusplus\ntypedef uint64_t logos_x_V_t;\n#endif\n",
      "#ifdef LOGOS_X\ntypedef uint64_t logos_x_V_t;\n#endif\n",
      "#ifndef LOGOS_X\n#define LOGOS_X 1\n#include \"b.h\"\n#endif\n",
      "#if 1\ntypedef uint64_t logos_x_V_t;\n#endif\n",
      "#if defined(X)\n#elif 1\n#endif\n", "#pragma once\n", "#undef LOGOS_X\n",
      "#line 7\n", "#error \"x\"\n", "#\n",
      "typedef struct logos_x_S_MAP {\n#ifdef __cplusplus\n    bool a;\n#endif\n} logos_x_S_t;\n",
      "#ifdef __cplusplus\nextern \"C\" {\n#endif\n", "}\n",
    ]:
      check parseRefused(bad) == rkConditional

  test "T2.3 [IFC-0785] [IFC-0591] the conditional linkage wrapper is non-schema syntax, and hand-written input may omit it":
    let h = generated(mirror("IFC/3.9.1.module.cddl"))
    let wrapped = parsedOk(h)
    check wrapped.linkage
    let bare = h.replace("#ifdef __cplusplus\nextern \"C\" {\n#endif\n", "").replace(
        "#ifdef __cplusplus\n}\n#endif\n", ""
      )
    check bare != h
    let plain = parsedOk(bare)
    check not plain.linkage
    check plain.items.mapIt(render(it)) == wrapped.items.mapIt(render(it))

  test "T2.4 [IMPL-DECISION G317] the generated frame: revision, context and identity checks, and document guards":
    let h = parsedOk(generated(mod392, [ifc392], [sup392]))
    check h.kinds.count(ciInclude) == 1
    check h.kinds.count(ciRevisionCheck) == 1
    check h.kinds.count(ciContextCheck) == 3
    check h.kinds.count(ciDocumentGuard) == 3
    for it in h.items:
      if it.kind == ciDocumentGuard:
        check it.roots == it.defined
        check it.children.len > 0
        for r in it.roots:
          check r.len == 21 and r.startsWith("0x") and r.endsWith("ULL")
    # checks and includes stay outside every guard (INTERFACE §3.2 l.2325)
    let ok1 = parsedOk(guarded.replace("BODY", "typedef uint64_t logos_x_V_t;\n"))
    check ok1.items[0].name == "x"
    check parseRefused(guarded.replace("BODY", "#include \"b.h\"\n")) == rkConditional
    check parseRefused(
      guarded.replace(
        "BODY",
        "#if !defined(LOGOS_C_MAPPING_REVISION) || LOGOS_C_MAPPING_REVISION != 3u\n" &
          "#error \"x\"\n#endif\n",
      )
    ) == rkConditional
    let threeRoots = guarded.replace(
      " || \\\n    !defined(LOGOS_DOCUMENT_x_ROOT_3) || LOGOS_DOCUMENT_x_ROOT_3 != 0x0000000000000000ULL\n",
      "\n",
    )
    check threeRoots != guarded
    check parseRefused(threeRoots.replace("BODY", "")) == rkIdentity

  test "T2.5 [IMPL-DECISION G317] a file-level include guard may enclose declarations and the fixed and standard includes, never a contract include or a check":
    let g = "#ifndef DEMO_H\n#define DEMO_H\nBODY#endif\n"
    let ok1 = parsedOk(g.replace("BODY", "typedef uint64_t logos_x_V_t;\n"))
    check ok1.includeGuard == "DEMO_H"
    check ok1.items.len == 1
    # the usual hand-written shape (INTERFACE §3.2 l.2298, l.2325)
    let ok2 = parsedOk(
      g.replace(
        "BODY",
        "#include <stdint.h>\n#include \"logos_types.h\"\n" &
          "#ifdef __cplusplus\nextern \"C\" {\n#endif\n" &
          "typedef uint64_t logos_x_V_t;\n#ifdef __cplusplus\n}\n#endif\n",
      )
    )
    check ok2.includeGuard == "DEMO_H"
    check ok2.linkage
    check ok2.items.mapIt(it.kind) == @[ciInclude, ciInclude, ciAlias]
    discard readOk(src("a.h", g.replace("BODY", "#include \"logos_types.h\"\n")))
    check parseRefused(g.replace("BODY", "#include \"b.h\"\n")) == rkConditional
    check parseRefused(
      g.replace(
        "BODY",
        "#if !defined(LOGOS_C_MAPPING_REVISION) || LOGOS_C_MAPPING_REVISION != 3u\n" &
          "#error \"x\"\n#endif\n",
      )
    ) == rkConditional
    check parseRefused(g.replace("BODY", guarded.replace("BODY", ""))) == rkConditional
    check parseRefused(
      "#ifndef LOGOS_DEMO_H\n#define LOGOS_DEMO_H\ntypedef uint64_t logos_x_V_t;\n#endif\n"
    ) == rkConditional

  test "T2.9 [IFC-0855] a header must not redefine the standard literal macros":
    for m in ["INT8_C", "UINT64_C", "INT64_MIN", "true", "false"]:
      check parseRefused("#define " & m & " 1\n") == rkStandardMacro
    check parseRefused("#define UINT64_C(x) x\n") == rkStandardMacro

  test "T2.10 [IFC-0852] the source is UTF-8, and headers compile with UTF-8 source and string literal encodings":
    check parseRefused("typedef uint64_t logos_x_V_t; /* \xff */\n") == rkSourceEncoding
    check parseRefused("typedef uint64_t logos_x_\xc3\xa9_t;\n") == rkSourceEncoding
    check parseRefused("#define LOGOS_LITERAL_x_V \"a??/\"\n") == rkSourceEncoding
    check parseRefused("typedef uint64_t logos_x_V_t;\0\n") == rkSourceEncoding
    let h =
      "#define LOGOS_LITERAL_x_A \"\xc3\xa9\"\n#define LOGOS_LITERAL_x_B \"\\u00e9\"\n" &
      "#define LOGOS_LITERAL_x_C \"\\303\\251\"\n"
    discard parsedOk(h)
    checkCompiles compileUnitIn(
      outDir,
      "utf8",
      h & staticAssert & "CHECK(sizeof(LOGOS_LITERAL_x_A) == 3);\n" &
        "CHECK(sizeof(LOGOS_LITERAL_x_B) == 3);\nCHECK(sizeof(LOGOS_LITERAL_x_C) == 3);\n",
    )

suite "ifc.c-reverse: literal recognition (INTERFACE §3.5, §3.9)":
  test "T3.1 [IFC-0844] [IFC-0846] [IFC-0847] [IFC-0848] [IFC-0849] [IFC-0869] the generated and handwritten integer and Boolean forms":
    let cases: seq[(string, CScalar)] = @[
      # zero, in every base and with suffixes
      ("0", uv(0)),
      ("0u", uv(0)),
      ("00", uv(0)),
      ("0x0", uv(0)),
      ("0X0ULL", uv(0)),
      ("0l", uv(0)),
      ("-0", uv(0)),
      ("UINT64_C(0)", uv(0)),
      ("+0", uv(0)),
      # the uint64 maximum
      ("18446744073709551615u", uv(high(uint64))),
      ("18446744073709551615ULL", uv(high(uint64))),
      ("0xFFFFFFFFFFFFFFFF", uv(high(uint64))),
      ("0xffffffffffffffffull", uv(high(uint64))),
      ("01777777777777777777777", uv(high(uint64))),
      ("UINT64_C(18446744073709551615)", uv(high(uint64))),
      ("UINT64_C(0xFFFFFFFFFFFFFFFF)", uv(high(uint64))),
      # negative one
      ("-1", iv(-1)),
      ("-1l", iv(-1)),
      ("-1LL", iv(-1)),
      ("-INT8_C(1)", iv(-1)),
      ("-INT64_C(1)", iv(-1)),
      ("(-INT64_C(1))", iv(-1)),
      ("(-(1))", iv(-1)),
      ("((-1))", iv(-1)),
      ("-(INT8_C(1))", iv(-1)),
      # the int64 minimum and maximum
      ("INT64_MIN", iv(low(int64))),
      ("(INT64_MIN)", iv(low(int64))),
      ("(-INT64_C(9223372036854775807) - INT64_C(1))", iv(low(int64))),
      ("((-INT64_C(9223372036854775807) - INT64_C(1)))", iv(low(int64))),
      ("-9223372036854775807", iv(low(int64) + 1)),
      ("9223372036854775807", iv(high(int64))),
      ("INT64_C(9223372036854775807)", iv(high(int64))),
      # equivalent bases and suffixes
      ("42", uv(42)),
      ("052", uv(42)),
      ("0x2a", uv(42)),
      ("0X2A", uv(42)),
      ("42u", uv(42)),
      ("42U", uv(42)),
      ("42l", uv(42)),
      ("42LL", uv(42)),
      ("42ul", uv(42)),
      ("42LU", uv(42)),
      ("42uLL", uv(42)),
      ("42llU", uv(42)),
      ("+42", uv(42)),
      ("+0x2Au", uv(42)),
      ("UINT8_C(42)", uv(42)),
      ("UINT16_C(052)", uv(42)),
      ("INT32_C(0x2a)", uv(42)),
      ("+INT16_C(42)", uv(42)),
      ("UINT64_C ( 42 )", uv(42)),
      ("/* c */ ( 42 /* d */ )", uv(42)),
      ("UINT8_C(255)", uv(255)),
      ("INT8_C(127)", uv(127)),
      ("UINT32_C(4294967295)", uv(4294967295'u64)),
      # Booleans
      ("true", CScalar(kind: cskBool, boolean: true)),
      ("false", CScalar(kind: cskBool, boolean: false)),
      ("(true)", CScalar(kind: cskBool, boolean: true)),
    ]
    for (spelling, want) in cases:
      let got = literal(spelling)
      checkpoint spelling
      check got.isOk
      if got.isOk:
        check got.get == want

  test "T3.2 [IFC-0844] [IFC-0850] [IFC-0851] [IFC-0869] text: concatenated UTF-8 strings with equivalent escapes":
    let cases: seq[(string, string)] = @[
      ("\"\"", ""),
      ("\"abc\"", "abc"),
      ("\"a\" \"b\" \"c\"", "abc"),
      ("(\"ab\" \"c\")", "abc"),
      ("\"\\\"\\\\\\?\\'\"", "\"\\?'"),
      ("\"\\a\\b\\f\\n\\r\\t\\v\"", "\a\b\f\n\r\t\v"),
      ("\"\\101\\102\"", "AB"),
      ("\"\\x41\\x42\"", "AB"),
      ("\"\\x041\"", "A"),
      ("\"\\x000041\"", "A"),
      # an escaped byte immediately followed by a digit or hexadecimal letter
      ("\"\\x41\" \"1\"", "A1"),
      ("\"\\x41\" \"B\"", "AB"),
      ("\"\\1011\"", "A1"),
      ("\"\\0101\"", "\x081"),
      ("\"\\7\" \"7\"", "\x077"),
      # UTF-8: source bytes, octal and hexadecimal bytes, universal character names
      ("\"\xc3\xa9\"", "\xc3\xa9"),
      ("\"\\303\\251\"", "\xc3\xa9"),
      ("\"\\xc3\\xa9\"", "\xc3\xa9"),
      ("\"\\xc3\" \"\\xa9\"", "\xc3\xa9"),
      ("\"\\u00e9\"", "\xc3\xa9"),
      ("\"\\U000000E9\"", "\xc3\xa9"),
      ("\"\\U0001F600\"", "\xf0\x9f\x98\x80"),
      ("\"\\u0024\\u0040\\u0060\"", "$@`"),
      ("\"\\uFFFF\"", "\xef\xbf\xbf"),
      ("\"\\U0010FFFF\"", "\xf4\x8f\xbf\xbf"),
    ]
    for (spelling, want) in cases:
      let got = literal(spelling)
      checkpoint spelling
      check got.isOk
      if got.isOk:
        check got.get == tv(want)

  test "T3.3 [IFC-0846] [IFC-0847] [IFC-0848] [IFC-0849] [IFC-0850] [IFC-0851] [IFC-0853] [IFC-0854] [IFC-0870] rejected: unsigned negation, malformed suffixes, out-of-range values, NUL, invalid UTF-8, other expressions":
    let cases: seq[(string, RejectReason)] = @[
      # unsigned negation and the other minus rules
      ("-1u", rkLiteralForm),
      ("-1U", rkLiteralForm),
      ("-1ull", rkLiteralForm),
      ("-0x1", rkLiteralForm),
      ("-01", rkLiteralForm),
      ("-UINT8_C(1)", rkLiteralForm),
      ("-UINT64_C(1)", rkLiteralForm),
      ("--1", rkLiteralForm),
      ("-+1", rkLiteralForm),
      ("+-1", rkLiteralForm),
      ("-(-1)", rkLiteralForm),
      ("-INT64_MIN", rkLiteralForm),
      ("+true", rkLiteralForm),
      ("-9223372036854775808", rkLiteralRange),
      ("-18446744073709551615", rkLiteralRange),
      # malformed suffixes, separators, floats, characters
      ("1uu", rkLiteralForm),
      ("1lul", rkLiteralForm),
      ("1LLL", rkLiteralForm),
      ("1lL", rkLiteralForm),
      ("1Ll", rkLiteralForm),
      ("1z", rkLiteralForm),
      ("1'000", rkLiteralForm),
      ("0b101", rkLiteralForm),
      ("08", rkLiteralForm),
      ("0x", rkLiteralForm),
      ("1.0", rkLiteralForm),
      ("1e3", rkLiteralForm),
      ("'a'", rkLiteralForm),
      # ranges
      ("9223372036854775808", rkLiteralRange),
      ("18446744073709551615", rkLiteralRange),
      ("18446744073709551616u", rkLiteralRange),
      ("0x10000000000000000", rkLiteralRange),
      ("INT8_C(128)", rkLiteralRange),
      ("UINT8_C(256)", rkLiteralRange),
      ("INT16_C(32768)", rkLiteralRange),
      ("UINT16_C(65536)", rkLiteralRange),
      ("INT32_C(2147483648)", rkLiteralRange),
      ("UINT32_C(4294967296)", rkLiteralRange),
      ("INT64_C(9223372036854775808)", rkLiteralRange),
      # macro arguments are single unsuffixed constant tokens
      ("UINT8_C(1u)", rkLiteralForm),
      ("INT8_C(-1)", rkLiteralForm),
      ("INT8_C((1))", rkLiteralForm),
      ("UINT64_C(1)(2)", rkLiteralForm),
      ("UINT64_C", rkLiteralForm),
      # text: escapes, NUL, UTF-8, prefixes
      ("\"a\\0b\"", rkLiteralText),
      ("\"a\" \"\\0\"", rkLiteralText),
      ("\"\\x00\"", rkLiteralText),
      ("\"\\xff\"", rkLiteralText),
      ("\"\\xc3\"", rkLiteralText),
      ("\"\\x100\"", rkLiteralText),
      ("\"\\400\"", rkLiteralText),
      ("\"\\x\"", rkLiteralText),
      ("\"\\q\"", rkLiteralText),
      ("\"\\uD800\"", rkLiteralText),
      ("\"\\U00110000\"", rkLiteralText),
      ("\"\\u0041\"", rkLiteralText),
      ("\"\\u009F\"", rkLiteralText),
      ("\"\\u00e\"", rkLiteralText),
      ("u8\"a\"", rkLiteralForm),
      ("L\"a\"", rkLiteralForm),
      ("\"a\" 1", rkLiteralForm),
      # expressions outside §3.5: casts, other identifiers and macros, arithmetic
      ("(uint64_t)1", rkLiteralForm),
      ("(uint64_t)(1)", rkLiteralForm),
      ("ONE", rkLiteralForm),
      ("UINT64_MAX", rkLiteralForm),
      ("INT64_MAX", rkLiteralForm),
      ("TRUE", rkLiteralForm),
      ("LOGOS_LITERAL_x_V", rkLiteralForm),
      ("1+1", rkLiteralForm),
      ("1 + 1", rkLiteralForm),
      ("-INT64_C(9223372036854775807) - INT64_C(1)", rkLiteralForm),
      ("(-INT64_C(9223372036854775807) - 1)", rkLiteralForm),
      ("(-9223372036854775807 - 1)", rkLiteralForm),
      ("1 ? 2 : 3", rkLiteralForm),
      ("!0", rkLiteralForm),
      ("~0", rkLiteralForm),
      ("sizeof(int)", rkLiteralForm),
      ("()", rkLiteralForm),
      ("", rkLiteralForm),
    ]
    for (spelling, want) in cases:
      let got = literal(spelling)
      checkpoint spelling
      check got.isErr
      if got.isErr:
        check got.error.reason == want

  test "[IMPL-DECISION G321] at most 64 nested parentheses in one literal":
    check literal(repeat('(', 64) & "1" & repeat(')', 64)).isOk
    check literal(repeat('(', 65) & "1" & repeat(')', 65)).error.reason == rkLimit

# CDDL emission -----------------------------------------------------------------------

func prim(name: string): ENode =
  ENode(kind: enPrim, prim: name)

func fld(name: string, n: ENode, optional = false): EField =
  EField(name: name, optional: optional, node: n)

func emap(fs: varargs[EField]): ENode =
  ENode(kind: enMap, fields: @fs)

func decl(name: string, n: ENode): EDeclaration =
  EDeclaration(name: name, node: n)

proc acceptedOne(source: string): Contract =
  let r = acceptContractSet(source)
  if r.isErr:
    checkpoint source
    checkpoint r.error
  r.get.primary

proc literalOf(c: Contract, name: string): ScalarData =
  for d in c.model.declarations:
    if d.name == name and d.kind == dkType and d.body.kind == snLiteral:
      return d.body.literal
  checkpoint "no literal declaration " & name
  fail()

suite "ifc.c-reverse: CDDL emission (INTERFACE §1.3, §3; G320)":
  test "[IMPL-DECISION G320] the §3.9.1 module, emitted, accepts to the mirror's root":
    let d = EDocument(
      module: "meter_module",
      declarations: @[
        decl("meter.changed_event", emap(fld("value", prim("uint64")))),
        decl(
          "meter.reading",
          emap(
            fld("label", prim("tstr"), optional = true), fld("value", prim("uint64"))
          ),
        ),
        decl("meter.read_request", emap(fld("channel", prim("uint32")))),
        decl(
          "meter.read_response",
          emap(
            fld("label", ENode(kind: enSized, base: "tstr", lo: 1, hi: 64)),
            fld("reading", ENode(kind: enRef, target: "meter.reading")),
          ),
        ),
      ],
    )
    let text = emit(d)
    check text.startsWith("; -- metadata --\n_module = \"meter_module\"\n")
    let got = acceptedOne(text)
    let want = acceptedOne(mirror("IFC/3.9.1.module.cddl"))
    check got.root == want.root
    check got.model.moduleName == want.model.moduleName

  test "[IMPL-DECISION G320] every node form, and literals with every escaped character":
    let tricky =
      "q\"b\\c\x01\x1f\x7f\xc2\x85\xc3\xa9\xf4\x8f\xbf\xbe\xf4\x8f\xbf\xbf\xf0\x9f\x98\x80"
    let d = EDocument(
      declarations: @[
        decl("k.text", ENode(kind: enText, text: tricky)),
        decl("k.yes", ENode(kind: enBool, boolean: true)),
        decl("k.big", ENode(kind: enInt, magnitude: high(uint64))),
        decl(
          "k.low",
          ENode(kind: enInt, negative: true, magnitude: 9223372036854775808'u64),
        ),
        decl(
          "k.all",
          emap(
            fld("a", ENode(kind: enSized, base: "bstr", lo: 16, hi: 16)),
            fld("b", ENode(kind: enSized, base: "bstr", lo: 0, hi: 8)),
            fld("c", ENode(kind: enList, element: prim("int8"))),
            fld("d", ENode(kind: enTuple, items: @[prim("bool"), prim("tstr")])),
            fld("e", ENode(kind: enTuple, items: @[])),
            fld("f", emap(), optional = true),
            fld(
              "g",
              ENode(
                kind: enChoice,
                arms:
                  @[ENode(kind: enText, text: "x"), ENode(kind: enRef, target: "k.yes")],
              ),
            ),
            fld(
              "h",
              ENode(
                kind: enList,
                element: ENode(
                  kind: enChoice, arms: @[prim("uint16"), emap(fld("z", prim("bstr")))]
                ),
              ),
            ),
          ),
        ),
      ]
    )
    let text = emit(d)
    check not text.contains("metadata")
    let c = acceptedOne(text)
    let lit = c.literalOf("k.text")
    check lit.kind == skTstr
    if lit.kind == skTstr:
      check lit.text == tricky
    let big = c.literalOf("k.big")
    check big.kind == skUint64
    if big.kind == skUint64:
      check big.unsigned == high(uint64)
    let low = c.literalOf("k.low")
    check low.kind == skInt64
    if low.kind == skInt64:
      check low.signed == low(int64)
    # deterministic: printing the same document twice gives the same text
    check emit(d) == text

  test "[IMPL-DECISION G320] [IFC-0569] a field name a reader could take for a type or a value is a quoted text key, with the same field identity":
    for name in QuotedKeys:
      let d = EDocument(declarations: @[decl("k.m", emap(fld(name, prim("uint8"))))])
      let quoted = emit(d)
      checkpoint quoted
      check ("\"" & name & "\": uint8") in quoted
      let a = acceptedOne(quoted)
      check a.model.declarations[0].body.fields[0].name == name
      # RFC 8610 §3.5.1: the bare spelling is the same text key
      let bare = quoted.replace("\"" & name & "\":", name & ":")
      let b = acceptedOne(bare)
      check a.root == b.root
    # other names, keywords included, stay bare
    for name in ["class", "value", "has", "type", "map"]:
      let quoted =
        emit(EDocument(declarations: @[decl("k.m", emap(fld(name, prim("uint8"))))]))
      check ("  " & name & ": uint8") in quoted

# Reconstruction ------------------------------------------------------------------------

proc one(text: string, name = "h.h"): seq[HeaderSource] =
  @[src(name, text)]

proc accepted(
    primary: string, ifaces: openArray[string] = [], supp: openArray[string] = []
): ContractSet =
  let r = acceptContractSet(primary, ifaces, supp)
  if r.isErr:
    checkpoint r.error
  r.get

proc rebuilt(sources: openArray[HeaderSource], opts = RmapOptions()): Reconstruction =
  let r = reconstruct(sources, opts)
  if r.isErr:
    checkpoint $r.error
    fail()
    return Reconstruction()
  r.get

proc refusal(sources: openArray[HeaderSource], opts = RmapOptions()): RejectReason =
  ## The reason the set is rejected: no document comes back (INTERFACE §3.9.5
  ## l.2941).
  let r = reconstruct(sources, opts)
  if r.isOk:
    checkpoint "reconstructed: " & sources.mapIt(it.name).join(", ")
    fail()
    return rkLimit
  checkpoint $r.error
  r.error.reason

func roots(r: Reconstruction): seq[Digest] =
  if r.primary.isSome:
    result.add(r.primary.get.contract.root)
  for d in r.interfaces:
    result.add(d.contract.root)
  for d in r.supporting:
    result.add(d.contract.root)

proc swapped(text, a, b: string): string =
  ## `text` with every `a` replaced by `b`; `a` must occur.
  doAssert a in text, "no " & a & " in:\n" & text
  text.replace(a, b)

proc cutBlock(h, ns: string): string =
  ## A generated header without the guarded group of document `ns`.
  let cns = projectNamespace(ns)
  let a = h.find("#ifdef LOGOS_DOCUMENT_" & cns & "_DEFINED\n")
  let z = "#endif /* LOGOS_DOCUMENT_" & cns & "_DEFINED */\n"
  let b = h.find(z)
  doAssert a >= 0 and b > a, "no group " & ns
  h[0 ..< a] & h[b + z.len .. ^1]

proc withIncludes(h: string, names: openArray[string]): string =
  swapped(
    h,
    "#include \"logos_types.h\"\n",
    "#include \"logos_types.h\"\n" & names.mapIt("#include \"" & it & "\"\n").join(""),
  )

proc withoutChecks(h: string): string =
  ## The header without its mapping-revision and commitment-context checks.
  let lines = h.splitLines(keepEol = true)
  var i = 0
  while i < lines.len:
    if lines[i].startsWith("#if !defined(LOGOS_C_"):
      i += 3
    else:
      result.add(lines[i])
      inc i

proc inBlock(h, start, stop, a, b: string): string =
  ## `h` with `a` replaced by `b` only between `start` and the next `stop`.
  let i = h.find(start)
  doAssert i >= 0, "no " & start
  let j = h.find(stop, i)
  h[0 ..< i] & h[i ..< j].replace(a, b) & h[j .. ^1]

proc dropped(h, start: string): string =
  ## `h` without the declaration that begins with `start` and ends at `);\n`.
  let a = h.find(start)
  doAssert a >= 0, "no " & start
  let b = h.find(");\n", a)
  h[0 ..< a] & h[b + 3 .. ^1]

proc boundHeader(
    module: string, ifaces: openArray[string] = [], supp: openArray[string] = []
): (ModuleBinding, string) =
  let b = acceptBinding(module, Opt.none(string), ifaces, supp)
  if b.isErr:
    checkpoint b.error
  (b.get, contractHeader(b.get.cSchemaSet).get)

proc roundTrip(
    primary: string,
    ifaces: openArray[string] = [],
    supp: openArray[string] = [],
    system = false,
): bool =
  ## [SPEC INTERFACE §3.8] S -> C -> S′: the same roots and binding, and `H′`
  ## equal to the header S generated.
  let s = acceptContractSet(primary, ifaces, supp, AcceptOptions(system: system))
  if s.isErr:
    checkpoint s.error
    return false
  let cs = s.get.cSchemaSet
  let h = contractHeader(cs).get
  var o = RmapOptions(system: system)
  if cs.module.isNone:
    o.subject = s.get.primary.model.namespace
  let r = reconstruct(one(h), o)
  if r.isErr:
    checkpoint $r.error
    checkpoint h
    return false
  let want =
    @[s.get.primary.root] & s.get.interfaces.mapIt(it.root) &
    s.get.supporting.mapIt(it.root)
  result = r.get.roots == want and r.get.module == cs.module and r.get.header == h
  if not result:
    checkpoint "H:\n" & h & "\nH′:\n" & r.get.header

proc compilesFiles(
    name: string, files: openArray[(string, string)], main: string
): string =
  ## The header `main` of `files`, after `logos_types.h`, in the five modes.
  let dir = outDir / name
  for (n, t) in files:
    createDir(parentDir(dir / n))
    writeFile(dir / n, t)
  compileUnitIn(dir, name, "#include \"logos_types.h\"\n#include \"" & main & "\"\n")

const
  ping = "demo.ping_request = {}\ndemo.ping_response = {}\n"
  allFields = """{
  a: uint32, ? b: tstr, c: tstr .size (1..64), d: bstr, e: bstr .size (1..4096),
  f: bstr .size 32, g: bstr .size 0, h: [* uint64], i: [* tstr], j: [* demo.rec],
  k: demo.rec, l: { x: uint64 }, m: demo.mode, ? n: [uint64, [tstr, bool]], o: [],
  ? p: [], q: logos.error_code, r: "lit", class: uint8,
}
"""
  kitchen = """demo.k = {
  a: 7, b: -9223372036854775808, c: "é1",
  d: bstr .size 32, e: [* bstr .size 4], f: [* [uint64, tstr]],
  g: demo.v / [uint64] / [uint64, uint64], ? h: [uint64, bstr],
  i: logos.schema_commitment, j: [], l: bstr .size 0,
  m: "on" / "off" / demo.v, n: [* demo.mode],
}
demo.v = { x: uint64 }
demo.mode = "a" / "b"
demo.tree = { ? left: demo.tree, kids: [* demo.tree], t: [demo.tree / uint64] }
"""
  choices =
    "demo.num = int16 / tstr\n" & "demo.mode = \"on\" / \"off-line\" / 7 / -2 / true\n" &
    "demo.shape = { w: uint64, h: uint64 } / { r: uint64, ? z: bool }\n" &
    "demo.seqs = [* uint64] / tstr\ndemo.tup = [uint64, tstr] / uint64\n" &
    "demo.v = { x: uint64 }\n" & "demo.r = demo.v / ext.types.w\n"
  paths =
    "demo.left = { right: { v: \"l\" } }\ndemo.left_right = { v: \"r\" }\n" &
    "demo.deep = { a: [* [uint64, [* { k: \"z\" }]]] }\n" &
    "demo.two = { a: { x: uint64 }, b: { x: uint64 } }\n"
  getNode =
    "#define LOGOS_INTERFACE_NAMESPACE_x \"x\"\nINCLUDES" &
    "typedef logos_result_t (*logos_x_Get_FN_t)(\n    logos_module_context_t* module,\n" &
    "    logos_response_owner_t* response_owner,\n    logos_recursive_Node_t* out_node\n);\n"

proc module(body: string, name = "demo_module"): string =
  "_module = \"" & name & "\"\n" & body

let
  h391 = mirror("IFC/3.9.1.module.h")
  h392 = mirror("IFC/3.9.2.module.h")
  h393 = mirror("IFC/3.9.3.module.h")
  h395 = mirror("IFC/3.9.5.rejection.h")
  cddl391 = mirror("IFC/3.9.1.module.cddl")
  cddl393 = mirror("IFC/3.9.3.module.cddl")
  halves = module(
    mirror("IFC/2.4.resolve.cddl") & "storage.report_request = { id: uint64 }\n" &
      "storage.report_response = { kind: \"found\", size: uint64 } / { kind: \"missing\" }\n",
    "storage_module",
  )
  allForms = module(
    "demo.rec = { v: uint64 }\ndemo.mode = \"a\" / \"b\"\ndemo.all_request = " &
      allFields & "demo.all_response = " & allFields
  )
  types393 = generated(cddl393)

suite "ifc.c-reverse: validation, repeats and packaging (INTERFACE §3.2)":
  test "T1.6 [IFC-0799] [IFC-0800] every body is validated before a repeat is suppressed, behind an include guard or a declared identity":
    let s = getNode.replace("INCLUDES", "#include \"types.h\"\n#include \"types.h\"\n")
    let r =
      rebuilt([src("s.h", s), src("types.h", types393)], RmapOptions(subject: "x"))
    check r.supporting.mapIt(it.contract.root) == @[accepted(cddl393).primary.root]
    # a body behind its document guard, which declares its identity, is still
    # reconstructed: a wrong identity and a broken member are found
    let r0 = types393.split("ROOT_0 0x")[1][0 ..< 16]
    let wrongRoot = swapped(types393, r0, "0123456789abcdef")
    check refusal([src("s.h", s), src("types.h", wrongRoot)], RmapOptions(subject: "x")) ==
      rkIdentity
    let broken = swapped(types393, "bool has_next;", "uint32_t has_next;")
    check refusal([src("s.h", s), src("types.h", broken)], RmapOptions(subject: "x")) ==
      rkPresence
    # included zero times: still parsed and validated
    check refusal(
      [
        src("s.h", s),
        src("types.h", types393),
        src("never.h", "typedef double logos_y_D_t;\n"),
      ],
      RmapOptions(subject: "x"),
    ) == rkOutsideSubset
    # included once, through a file-level include guard
    let once = getNode.replace("INCLUDES", "#include \"types.h\"\n")
    check rebuilt(
      [src("s.h", once), src("types.h", types393)], RmapOptions(subject: "x")
    ).roots == r.roots

  test "T1.7 [IFC-0801] [IFC-0802] a repeated group is reused only when it agrees, within one reconstruction input":
    let s = getNode.replace("INCLUDES", "#include \"a.h\"\n#include \"b.h\"\n")
    let r = rebuilt(
      [src("s.h", s), src("a.h", types393), src("b.h", types393)],
      RmapOptions(subject: "x"),
    )
    check r.supporting.len == 1
    let other = generated(swapped(cddl393, "value: uint64", "value: uint32"))
    check refusal(
      [src("s.h", s), src("a.h", types393), src("b.h", other)],
      RmapOptions(subject: "x"),
    ) == rkConflictingGroup
    # another provider's conflicting copy, outside this reconstruction input
    let s1 = getNode.replace("INCLUDES", "#include \"a.h\"\n")
    check rebuilt(
      [src("s.h", s1), src("a.h", types393), src("other.h", other)],
      RmapOptions(subject: "x"),
    ).roots == r.roots

  test "T1.8 [IFC-0786] [IFC-0787] [IFC-0819] one header, reusable headers included by two providers, any logical prefix: the same documents":
    let whole = generated(mod392, [ifc392], [sup392])
    let single = rebuilt(one(whole))
    let supH = generated(sup392)
    let ifaceH = generated(ifc392)
    let provider = whole
      .cutBlock("metrics_types")
      .cutBlock("metrics_provider")
      .withIncludes(["sup.h", "iface.h"])
    let (_, otherWhole) = boundHeader("other_module", [ifc392])
    let other = otherWhole.cutBlock("metrics_provider").withIncludes(["iface.h"])
    let files = @[
      ("provider.h", provider), ("other.h", other), ("sup.h", supH), ("iface.h", ifaceH)
    ]
    let set = files.mapIt(src(it[0], it[1]))
    let a = rebuilt(set, RmapOptions(module: "sensor_module"))
    check a.roots == single.roots
    check a.module == single.module
    let b = rebuilt(set, RmapOptions(module: "other_module"))
    check b.primary.isNone
    check b.interfaces.mapIt(it.contract.root) ==
      single.interfaces.mapIt(it.contract.root)
    # under another logical prefix: nothing depends on an installed location
    let prefixed = files.mapIt(src("vendor/pkg/" & it[0], it[1]))
    check rebuilt(prefixed, RmapOptions(module: "sensor_module")).roots == single.roots
    checkCompiles compilesFiles("packaging", files, "provider.h")

suite "ifc.c-reverse: checks in the frame (INTERFACE §2, §3.2)":
  test "T2.6 [IFC-0601] the revision check may be omitted; a supplied one must agree":
    let h = generated(cddl391)
    let want = rebuilt(one(h391)).roots
    check rebuilt(one(h)).roots == want
    check rebuilt(
      one(swapped(h, "LOGOS_C_MAPPING_REVISION != 3u", "LOGOS_C_MAPPING_REVISION != 3"))
    ).roots == want
    check refusal(
      one(
        swapped(h, "LOGOS_C_MAPPING_REVISION != 3u", "LOGOS_C_MAPPING_REVISION != 4u")
      )
    ) == rkRevisionCheck

  test "T2.7 [IFC-0607] the context checks may be omitted; supplied ones must name the pinned context and compare with 1":
    let h = generated(cddl391)
    let marker = contextMarkers()[0]
    check refusal(one(swapped(h, marker, marker[0 ..^ 2] & "1"))) == rkContextCheck
    check refusal(one(swapped(h, marker & " != 1", marker & " != 2"))) == rkContextCheck

  test "T2.8 [IFC-0608] [IFC-0804] [IFC-0805] [IFC-0806] checks never change identity; a disagreeing identity is rejected":
    let h = generated(cddl391)
    check rebuilt(one(withoutChecks(h))).roots == rebuilt(one(h)).roots
    check rebuilt(one(h391)).roots == rebuilt(one(h)).roots # no checks, no guards
    let r2 = h.split("ROOT_2 0x")[1][0 ..< 16]
    check refusal(one(swapped(h, r2, "fedcba9876543210"))) == rkIdentity
    # the checked and the defined literals must agree too
    let checked = "ROOT_2 != 0x" & r2
    check refusal(one(swapped(h, checked, "ROOT_2 != 0xfedcba9876543210"))) == rkIdentity

  test "T2.11 [IFC-0893] [IFC-0785] declaration placement and the linkage wrapper do not matter":
    let event =
      "typedef struct logos_meter_Changed_event_EVENT {\n    uint64_t value;\n} logos_meter_Changed_event_t;\n"
    let name = "const char* logos_meter_module_MODULE_name(void);\n"
    let moved = swapped(swapped(h391, event, ""), name, "") & event
    let reordered = name & moved
    check rebuilt(one(reordered)).roots == rebuilt(one(h391)).roots
    let h = generated(cddl391)
    let bare = swapped(
      swapped(h, "#ifdef __cplusplus\nextern \"C\" {\n#endif\n", ""),
      "#ifdef __cplusplus\n}\n#endif\n",
      "",
    )
    let a = rebuilt(one(h))
    let b = rebuilt(one(bare))
    check a.roots == b.roots
    check a.module == b.module
    check a.header == b.header

suite "ifc.c-reverse: literals in headers (INTERFACE §3.5)":
  test "T3.4 [IFC-0845] [IFC-0871] equivalent literal spellings keep the scalar, the model and the identity":
    let want = rebuilt(one(h392)).roots
    for spelling in [
      "\"sen\" \"sor\"", "\"\\163ensor\"", "\"\\x73\" \"ensor\"", "(\"sensor\")",
      "/* c */ \"sensor\"",
    ]:
      checkpoint spelling
      check rebuilt(one(swapped(h392, "\"sensor\"", spelling))).roots == want
    let ints = generated("demo.k = { a: 7, b: -2, c: true }\n")
    let base = rebuilt(one(ints)).roots
    for (field, generatedForm, spelling) in [
      ("A", "UINT64_C(7)", "7"),
      ("A", "UINT64_C(7)", "07"),
      ("A", "UINT64_C(7)", "0x7"),
      ("A", "UINT64_C(7)", "7u"),
      ("A", "UINT64_C(7)", "7ULL"),
      ("A", "UINT64_C(7)", "UINT8_C(7)"),
      ("A", "UINT64_C(7)", "(+7)"),
      ("B", "(-INT64_C(2))", "-2"),
      ("B", "(-INT64_C(2))", "(-2)"),
      ("B", "(-INT64_C(2))", "-INT8_C(2)"),
      ("B", "(-INT64_C(2))", "-2ll"),
      ("C", "true", "(true)"),
    ]:
      let m = "#define LOGOS_LITERAL_demo_K_" & field & " "
      checkpoint m & spelling
      check rebuilt(one(swapped(ints, m & generatedForm, m & spelling))).roots == base

  test "T3.4 [IFC-0347] a missing literal macro, one of the wrong scalar type, one naming another arm":
    let flag = generated("demo.flag = \"on\" / \"off\"\n")
    check refusal(
      one(swapped(flag, "#define LOGOS_LITERAL_demo_Flag_AR_On \"on\"\n", ""))
    ) == rkLiteralMissing
    check refusal(
      one(
        swapped(
          flag, "LOGOS_LITERAL_demo_Flag_AR_On ", "LOGOS_LITERAL_demo_Flag_AR_Of "
        )
      )
    ) == rkLiteralMissing
    let ints = generated("demo.k = { a: 7 }\n")
    check refusal(one(swapped(ints, "UINT64_C(7)", "\"7\""))) == rkLiteralKind

suite "ifc.c-reverse: groups, roles and the module binding (INTERFACE §3.2, §3.7)":
  test "T4.1 [IFC-0298] [IFC-0820] [IFC-0821] [IFC-0822] [IFC-0918] one group and no constant: the role and namespace are inferred":
    let m = rebuilt(one(h391))
    check m.module == Opt.some("meter_module")
    check m.primary.get.role == srModule
    let i = rebuilt(
      one(
        "typedef logos_result_t (*logos_a_NS_b_Ping_FN_t)(\n" &
          "    logos_module_context_t* module,\n    logos_response_owner_t* response_owner\n);\n"
      )
    )
    check i.module.isNone
    check i.primary.get.role == srInterface
    check i.primary.get.namespace == "a.b"
    let s = rebuilt(one("typedef uint64_t logos_a_b_Value_t;\n"))
    check s.primary.get.role == srSupporting
    check s.primary.get.namespace == "a_b"
    # a declaration of another namespace makes a second group: no inference
    check refusal(
      one("typedef uint64_t logos_a_b_Value_t;\ntypedef uint64_t logos_a_c_Value_t;\n")
    ) == rkRoleConstant

  test "T4.2 [IFC-0611] a constant may be left out only where inference applies; a types-only interface needs its own":
    let types = "typedef uint64_t logos_a_b_Value_t;\n"
    check rebuilt(one(types)).primary.get.role == srSupporting
    let i = rebuilt(one("#define LOGOS_INTERFACE_NAMESPACE_a_b \"a_b\"\n" & types))
    check i.primary.get.role == srInterface
    check refusal(
      one(swapped(h395, "#define LOGOS_INTERFACE_NAMESPACE_a_NS_b \"a.b\"\n", "")),
      RmapOptions(subject: "a.b"),
    ) == rkRoleConstant

  test "T4.3 [IFC-0302] [IFC-0303] [IFC-0304] [IFC-0823] [IFC-0824] [IFC-0859] explicit constants are accepted and checked; lifecycle symbols never override them":
    let explicit = "#define LOGOS_PRIMARY_NAMESPACE_meter_module \"meter\"\n" & h391
    check rebuilt(one(explicit)).roots == rebuilt(one(h391)).roots
    # the primary constant's module component is the family's
    check refusal(
      one("#define LOGOS_PRIMARY_NAMESPACE_other_module \"meter\"\n" & h391)
    ) == rkModuleName
    # an explicit interface role stays one beside a lifecycle family
    let iface =
      "#define LOGOS_INTERFACE_NAMESPACE_meter \"meter\"\n" &
      "#define LOGOS_IMPLEMENTS_meter_module_INDEX0 \"meter\"\n" & h391
    let r = rebuilt(one(iface))
    check r.primary.isNone
    check r.interfaces.len == 1 and r.interfaces[0].role == srInterface
    check refusal(one("#define LOGOS_INTERFACE_NAMESPACE_meter \"meter\"\n" & h391)) ==
      rkMissingImplements

  test "T4.4 [IFC-0306] [IFC-0307] an incomplete namespace group":
    check refusal(
      one(
        swapped(
          h393,
          "struct logos_recursive_Right_MAP {\n    bool                         has_left;\n    const logos_recursive_Left_t* left;\n};\n",
          "",
        )
      )
    ) == rkIncompleteGroup
    check refusal(one("typedef logos_x_Missing_t logos_x_V_t;\n")) == rkIncompleteGroup

  test "T4.5 [IFC-0306] [IFC-0308] two conflicting definitions of one qualified name; an identical repeat is no conflict":
    check refusal(one("typedef uint64_t logos_x_V_t;\ntypedef uint32_t logos_x_V_t;\n")) ==
      rkConflictingDefinition
    check rebuilt(one("typedef uint64_t logos_x_V_t;\ntypedef uint64_t logos_x_V_t;\n")).roots ==
      rebuilt(one("typedef uint64_t logos_x_V_t;\n")).roots
    check refusal(
      one(
        "#define LOGOS_LITERAL_x_V UINT64_C(1)\n#define LOGOS_LITERAL_x_V UINT64_C(2)\n" &
          "typedef uint64_t logos_x_V_t;\n"
      )
    ) == rkConflictingDefinition
    check refusal(
      one(
        "typedef struct logos_x_V_MAP {\n    uint64_t a;\n} logos_x_V_t;\n" &
          "typedef struct logos_x_V_LIST {\n    const uint64_t* items;\n    size_t count;\n} logos_x_V_t;\n"
      )
    ) == rkConflictingDefinition

  test "T4.6 [IFC-0306] [IFC-0309] a method half without its method":
    let h = generated(halves)
    let noFn = dropped(
      dropped(h, "typedef logos_result_t (*logos_storage_Resolve_FN_t)("),
      "logos_result_t logos_storage_module_CALL_storage_Resolve(",
    )
    check refusal(one(noFn)) == rkHalfMissing

  test "T4.7 [IFC-0306] [IFC-0310] a missing required or a conflicting role constant":
    check refusal(
      one(
        swapped(
          h392, "#define LOGOS_PRIMARY_NAMESPACE_sensor_module \"sensor.control\"\n", ""
        )
      )
    ) == rkRoleConstant
    check refusal(
      one(h395 & "#define LOGOS_SUPPORTING_NAMESPACE_a_NS_b \"a.b\"\n"),
      RmapOptions(subject: "a.b"),
    ) == rkRoleConstant

  test "T4.8 [IFC-0306] [IFC-0311] a role constant whose value, projection, prefix or role does not match its group":
    check refusal(one(swapped(h392, "\"sensor.control\"", "\"sensor.runtime\""))) ==
      rkRoleMismatch
    check refusal(
      one(
        swapped(
          h395, "LOGOS_INTERFACE_NAMESPACE_a_NS_b", "LOGOS_INTERFACE_NAMESPACE_a_b"
        )
      ),
      RmapOptions(subject: "a.b"),
    ) == rkRoleMismatch
    check refusal(
      one(
        swapped(
          h395, "LOGOS_SUPPORTING_NAMESPACE_a_b \"a_b\"",
          "LOGOS_SUPPORTING_NAMESPACE_a_b \"A_b\"",
        )
      ),
      RmapOptions(subject: "a_b"),
    ) == rkRoleMismatch

  test "T4.9 [IFC-0306] [IFC-0828] inconsistent runtime module names in one module reconstruction":
    check refusal(one(h391 & "const char* logos_other_module_MODULE_name(void);\n")) ==
      rkModuleName

  test "T4.10 [IFC-0306] [IFC-0312] an implements constant without one complete matching interface group":
    check refusal(
      one(swapped(h392, "INDEX0 \"metrics_provider\"", "INDEX0 \"metrics_types\""))
    ) == rkImplements
    check refusal(
      one(swapped(h392, "INDEX0 \"metrics_provider\"", "INDEX0 \"nothing\""))
    ) == rkImplements

  test "T4.11 [IFC-0306] [IFC-0829] a duplicate implemented interface":
    check refusal(
      one(h392 & "#define LOGOS_IMPLEMENTS_sensor_module_INDEX1 \"metrics_provider\"\n")
    ) == rkDuplicateImplements

  test "T4.12 [IFC-0306] [IFC-0313] a provider function of a non-primary contract without its implements constant":
    check refusal(
      one(
        swapped(
          h392, "#define LOGOS_IMPLEMENTS_sensor_module_INDEX0 \"metrics_provider\"\n",
          "",
        )
      )
    ) == rkMissingImplements

  test "T4.13 [IFC-0306] [IFC-0314] a supporting group with a method or an event":
    check refusal(one("#define LOGOS_SUPPORTING_NAMESPACE_meter \"meter\"\n" & h391)) ==
      rkSupportingCallable
    check refusal(
      one(
        "typedef struct logos_x_Done_event_EVENT {\n    uint64_t v;\n} logos_x_Done_event_t;\n#define LOGOS_SUPPORTING_NAMESPACE_x \"x\"\n"
      )
    ) == rkSupportingCallable

  test "T4.14 [IFC-0306] [IFC-0830] a supporting group supplied as a dependency and not referenced":
    let extra = generated("extra.v = uint64\n")
    let s = getNode.replace("INCLUDES", "#include \"types.h\"\n#include \"extra.h\"\n")
    check refusal(
      [src("s.h", s), src("types.h", types393), src("extra.h", extra)],
      RmapOptions(subject: "x"),
    ) == rkUnreferencedDependency
    # the same group in the subject's own body is another document (G318)
    let own =
      getNode.replace("INCLUDES", "#include \"types.h\"\n") &
      "#define LOGOS_SUPPORTING_NAMESPACE_extra \"extra\"\ntypedef uint64_t logos_extra_V_t;\n"
    let r =
      rebuilt([src("s.h", own), src("types.h", types393)], RmapOptions(subject: "x"))
    check r.supporting.len == 1 and r.supporting[0].namespace == "recursive"

  test "T4.15 [IFC-0306] [IFC-0305] [IFC-0316] implements indices: contiguous from 0, in ascending raw root order":
    check refusal(one(swapped(h392, "INDEX0", "INDEX1"))) == rkImplementsIndex
    let second =
      "_interface = \"other_iface\"\nother_iface.go_request = {}\nother_iface.go_response = {}\n"
    let (b, h) = boundHeader("two_module", [ifc392, second])
    check rebuilt(one(h)).interfaces.mapIt(it.contract.root) ==
      b.interfaces.mapIt(it.root)
    let n0 = "INDEX0 \"" & b.interfaces[0].model.namespace & "\""
    let n1 = "INDEX1 \"" & b.interfaces[1].model.namespace & "\""
    let swappedOrder = h
      .replace(n0, "@@")
      .replace(n1, n0.replace("INDEX0", "INDEX1"))
      .replace("@@", n1.replace("INDEX1", "INDEX0"))
    check swappedOrder != h
    check refusal(one(swappedOrder)) == rkImplementsIndex

  test "T4.16 [IFC-0306] [IFC-0317] look-alike names and the dotted and underscored namespaces never collide":
    # The §2.1 projections are injective and each inline stem is derived from one
    # path, so no conforming input reaches a collision; these names stay apart.
    check roundTrip(
      "demo.x_t = uint64\ndemo.x_kind = uint64\ndemo.x = uint64 / tstr\n" &
        "demo.a_b = { v: \"named\" }\ndemo.a = { b: { v: \"inline\" } }\n"
    )
    let a = rebuilt(one(h395), RmapOptions(subject: "a.b"))
    let b = rebuilt(one(h395), RmapOptions(subject: "a_b"))
    check a.roots != b.roots

  test "T4.17 [IFC-0825] [IFC-0826] [IFC-0827] implements module component, no synthesized primary, sensitivity constants":
    check refusal(
      one(
        swapped(
          h392, "LOGOS_IMPLEMENTS_sensor_module_INDEX0",
          "LOGOS_IMPLEMENTS_other_module_INDEX0",
        )
      )
    ) == rkModuleName
    let (b, h) = boundHeader("sensor_module", [ifc392])
    let r = rebuilt(one(h))
    check r.primary.isNone
    check r.interfaces.mapIt(it.contract.root) == b.interfaces.mapIt(it.root)
    check "_module" notin r.interfaces[0].cddl and
      "_implements" notin r.interfaces[0].cddl
    let vault =
      "_interface = \"vault\"\n_sensitive = [\"vault.get_response\", \"vault.store_request\"]\n" &
      "vault.get_request = {}\nvault.get_response = { secret: bstr }\n" &
      "vault.store_request = { secret: bstr }\nvault.store_response = {}\n"
    let vh = generated(vault)
    check rebuilt(one(vh), RmapOptions(subject: "vault")).primary.get.contract.root ==
      accepted(vault).primary.root
    let i0 = "#define LOGOS_SENSITIVE_vault_INDEX0 \"vault.get_response\"\n"
    let i1 = "#define LOGOS_SENSITIVE_vault_INDEX1 \"vault.store_request\"\n"
    for bad in [
      swapped(vh, i0, ""), # a missing index
      swapped(
        swapped(vh, "\"vault.get_response\"", "\"@@\""),
        "\"vault.store_request\"",
        "\"vault.get_response\"",
      )
        .replace("\"@@\"", "\"vault.store_request\""), # the wrong order
      swapped(vh, "INDEX1 \"vault.store_request\"", "INDEX1 \"vault.get_response\""),
        # a duplicate
      swapped(vh, "INDEX1 \"vault.store_request\"", "INDEX1 \"vault.missing_request\""),
        # no such declaration
    ]:
      check refusal(one(bad), RmapOptions(subject: "vault")) == rkSensitive
    discard i1

  test "T4.18 [IFC-0858] [IFC-0860] [IFC-0788] [IFC-0789] [IFC-0790] module names decoded, a lifecycle-only module, selection and the retained binding":
    for name in ["a__b", "a_", "a___b_"]:
      check roundTrip(module(ping, name))
      check rebuilt(one(generated(module(ping, name)))).module == Opt.some(name)
    let bare =
      "const char* logos_bare_module_MODULE_name(void);\n" &
      "logos_result_t logos_bare_module_MODULE_init(const logos_module_init_input_t* input, logos_module_context_t** out_context);\n" &
      "void logos_bare_module_MODULE_destroy(logos_module_context_t* module);\n"
    let r = rebuilt(one(bare))
    check r.module == Opt.some("bare_module")
    check r.primary.isNone and r.interfaces.len == 0 and r.supporting.len == 0
    # [IMPL-DECISION G322] provider symbols on a module that is not a provider
    let withProvider =
      bare & "const uint8_t* logos_bare_module_MODULE_call_surface(size_t* out_len);\n" &
      "void logos_bare_module_MODULE_free(logos_module_context_t* m, void* p);\n"
    check rebuilt(one(withProvider)).module == Opt.some("bare_module")
    check refusal(one(swapped(withProvider, "size_t* out_len", "size_t out_len"))) ==
      rkLifecycle
    # the 3.9.2 header: the module with its documents, or one document alone
    let m = rebuilt(one(h392))
    check m.module == Opt.some("sensor_module")
    check m.primary.get.namespace == "sensor.control"
    check m.interfaces.mapIt(it.namespace) == @["metrics_provider"]
    check m.supporting.mapIt(it.namespace) == @["metrics_types"]
    let i = rebuilt(one(h392), RmapOptions(subject: "metrics_provider"))
    check i.module.isNone and i.primary.get.namespace == "metrics_provider"
    check rebuilt(one(h392 & h395)).module == Opt.some("sensor_module")
    check rebuilt(one(h392 & h395), RmapOptions(subject: "a.b")).primary.get.namespace ==
      "a.b"
    check refusal(one(h395)) == rkSelection
    check refusal(one(h392), RmapOptions(module: "nothing_module")) == rkSelection

  test "T4.19 [IFC-0876] [IFC-0877] [IFC-0878] [IFC-0879] [IFC-0881] the §3.9.2 cases":
    let whole = rebuilt(one(h392))
    # each document alone, and as a dependency of the module
    check rebuilt(one(generated(sup392))).primary.get.contract.root ==
      whole.supporting[0].contract.root
    check rebuilt(one(generated(ifc392)), RmapOptions(subject: "metrics_provider")).primary.get.contract.root ==
      whole.interfaces[0].contract.root
    # the interface-only provider
    let (b, h) = boundHeader("sensor_module", [ifc392])
    let r = rebuilt(one(h))
    check r.primary.isNone
    check r.interfaces.mapIt(it.contract.root) == @[accepted(ifc392).primary.root]
    check r.header == h
    discard b
    # the interface constant and method typedef alone
    let alone =
      "#define LOGOS_INTERFACE_NAMESPACE_metrics_provider \"metrics_provider\"\n" &
      "typedef logos_result_t (*logos_metrics_provider_Snapshot_FN_t)(\n" &
      "    logos_module_context_t* module,\n    logos_response_owner_t* response_owner,\n" &
      "    uint64_t*               out_count\n);\n"
    let a = rebuilt(one(alone))
    check a.module.isNone
    check a.primary.get.contract.root == accepted(ifc392).primary.root
    # events only, a types-only primary with an implemented interface, lifecycle only
    let events = "_interface = \"ev\"\nev.ticked_event = { n: uint64 }\n"
    let (_, eh) = boundHeader("ev_module", [events])
    check rebuilt(one(eh)).interfaces.mapIt(it.contract.root) ==
      @[accepted(events).primary.root]
    let typesOnly = rebuilt(
      one(
        generated(
          "_module = \"t_module\"\n_implements = [h'" &
            toHex(accepted(ifc392).primary.root) & "']\n" & "t.v = uint64\n",
          [ifc392],
        )
      )
    )
    check typesOnly.primary.get.namespace == "t"
    check typesOnly.interfaces.len == 1
    let (_, lh) = boundHeader("bare_module")
    let l = rebuilt(one(lh))
    check l.primary.isNone and l.interfaces.len == 0

  test "T4.20 [IFC-0884] [IFC-0885] the §3.9.5 pair: either namespace as the subject; the renamed constant is rejected":
    let a = rebuilt(one(h395), RmapOptions(subject: "a.b"))
    check a.primary.get.namespace == "a.b" and a.primary.get.role == srInterface
    check a.supporting.len == 0
    let b = rebuilt(one(h395), RmapOptions(subject: "a_b"))
    check b.primary.get.namespace == "a_b" and b.primary.get.role == srSupporting
    check refusal(
      one(
        swapped(
          h395, "LOGOS_INTERFACE_NAMESPACE_a_NS_b", "LOGOS_INTERFACE_NAMESPACE_a_b"
        )
      ),
      RmapOptions(subject: "a_b"),
    ) == rkRoleMismatch

suite "ifc.c-reverse: method typedefs and provider functions (INTERFACE §3.3)":
  test "T5.1 [IFC-0327] [IFC-0328] [IFC-0329] the §3.3 provider prototype, completed, reconstructs the §3.3 request and response":
    let source = module(mirror("IFC/2.4.upload_url.cddl"), "storage_module")
    let h = generated(source)
    let fragment = mirror("IFC/3.3.upload_url.h")
    let call = parsedOk(fragment).items[0]
    var inH = ""
    for it in parsedOk(h).items:
      if it.kind == ciFunction and it.name == call.name:
        inH = render(it)
    check inH == render(call)
    # the fragment completes the header the same CDDL generates
    let completed = dropped(h, "logos_result_t " & call.name & "(") & fragment
    let r = rebuilt(one(completed))
    let spec = accepted(module(mirror("IFC/3.3.upload_url.cddl"), "storage_module"))
    check r.primary.get.contract.root == spec.primary.root

  test "T5.2 [IFC-0320] [IFC-0831] [IFC-0832] the method typedef and provider function patterns":
    let h = generated(module(mirror("IFC/2.4.upload_url.cddl"), "storage_module"))
    check rebuilt(one(h)).primary.isSome
    check refusal(
      one(
        swapped(
          h, "logos_response_owner_t* response_owner", "logos_response_owner_t* owner"
        )
      )
    ) == rkFunction
    check refusal(one(swapped(h, "logos_response_owner_t* response_owner,\n", ""))) ==
      rkFunction
    check refusal(
      one(
        swapped(
          h, "typedef logos_result_t (*logos_storage_Upload_url_FN_t)",
          "typedef int32_t (*logos_storage_Upload_url_FN_t)",
        )
      )
    ) == rkFunction

  test "T5.3 [IFC-0322] [IFC-0323] in_ and out_ prefixes, inputs before outputs":
    let h = generated(module(mirror("IFC/2.4.upload_url.cddl"), "storage_module"))
    let ordered = swapped(
      h,
      "    uint64_t in_chunk_size,\n    const char* in_url,\n    bool* out_accepted\n",
      "    uint64_t in_chunk_size,\n    bool* out_accepted,\n    const char* in_url\n",
    )
    check refusal(one(ordered)) == rkParamOrder
    check refusal(one(swapped(h, "in_url", "url"))) == rkParamOrder

  test "T5.4 [IFC-0324] [IFC-0325] a choice wrapper mixed with flattened parameters, or a choice no wrapper consumes":
    let h = generated(halves)
    check rebuilt(one(h)).primary.isSome
    check refusal(
      one(
        swapped(h, "const logos_storage_Resolve_request_t* in_request", "uint64_t in_x")
      )
    ) == rkWrapper
    check refusal(
      one(
        swapped(
          h, "const logos_storage_Resolve_request_t* in_request,",
          "const logos_storage_Resolve_request_t* in_request,\n    uint64_t in_zz,",
        )
      )
    ) == rkWrapper

  test "T5.5 [IFC-0326] a provider function that differs from its typedef":
    let h = generated(module(mirror("IFC/2.4.upload_url.cddl"), "storage_module"))
    let call = "logos_storage_module_CALL_storage_Upload_url("
    let a = h.find(call)
    let mutated = h[0 ..< a] & h[a .. ^1].replace("in_chunk_size", "in_chunk")
    check refusal(one(mutated)) == rkProviderMismatch

  test "T5.6 [IFC-0330] [IFC-0331] [IFC-0332] [IFC-0333] parameter order, unmatched members, the presence pairs":
    let h = generated(allForms)
    check rebuilt(one(h)).primary.isSome
    check refusal(
      one(
        swapped(
          h, "    uint32_t in_a,\n    bool in_has_b,\n    const char* in_b,\n",
          "    bool in_has_b,\n    const char* in_b,\n    uint32_t in_a,\n",
        )
      )
    ) == rkFieldOrder
    check refusal(one(swapped(h, "    size_t in_d_len,\n", ""))) == rkMember
    check refusal(one(swapped(h, "    size_t* out_h_count,\n", ""))) == rkMember
    check refusal(one(swapped(h, "uint32_t* out_a", "uint32_t out_a"))) == rkMember
    check refusal(one(swapped(h, "bool in_has_b", "uint32_t in_has_b"))) == rkPresence
    check refusal(one(swapped(h, "bool* out_has_b", "bool out_has_b"))) == rkPresence
    check refusal(
      one(
        swapped(h, "    bool in_has_b,\n", "    bool in_has_b,\n    bool in_has_zz,\n")
      )
    ) == rkPresence

  test "T5.7 [IFC-0833] [IFC-0834] [IFC-0902] module-C decoded (a_Ub rejected), in_class_ rejected, underscored module names kept":
    check refusal(one(swapped(h391, "meter_module", "a_Ub"))) == rkName
    let h = generated(allForms)
    check refusal(one(swapped(h, "uint8_t in_class,", "uint8_t in_class_,"))) == rkEscape
    for name in ["single_module", "a__b", "a_", "a___b_"]:
      check roundTrip(module(ping, name))

  test "T5.8 [IFC-0904] from generated C: methods init, destroy and upload_url stay apart from the lifecycle symbols":
    let source = module(
      "demo.init_request = {}\ndemo.init_response = {}\n" &
        "demo.destroy_request = {}\ndemo.destroy_response = {}\n" &
        "demo.upload_url_request = {}\ndemo.upload_url_response = {}\n",
      "x_module",
    )
    let h = generated(source)
    for m in ["Init", "Destroy", "Upload_url"]:
      check ("(*logos_demo_" & m & "_FN_t)") in h
      check ("logos_x_module_CALL_demo_" & m & "(") in h
    check "logos_x_module_MODULE_init(" in h and "logos_x_module_MODULE_destroy(" in h
    let r = rebuilt(one(h))
    check r.primary.get.contract.root == accepted(source).primary.root
    var methods: seq[string]
    for d in r.primary.get.contract.model.declarations:
      if d.kind == dkMethod:
        methods.add(d.name)
    check methods.sorted == @["demo.destroy", "demo.init", "demo.upload_url"]

suite "ifc.c-reverse: structs, choices, events and paths (INTERFACE §2.1, §3.4-§3.6, §3.9.9-§3.9.10)":
  test "T6.1 [IFC-0335] [IFC-0336] the §3.4 struct reconstructs the §3.4 map":
    let r = rebuilt(one(mirror("IFC/3.4.space_info.h")))
    check r.primary.get.contract.root ==
      accepted(mirror("IFC/3.4.space_info.cddl")).primary.root

  test "T6.2 [IFC-0349] [IFC-0350] the §3.6 event struct reconstructs the §3.6 event":
    let r = rebuilt(one(mirror("IFC/3.6.event.h")))
    check r.primary.get.role == srInterface
    check r.primary.get.contract.root ==
      accepted("_interface = \"storage\"\n" & mirror("IFC/3.6.event.cddl")).primary.root

  test "T6.3 [IFC-0337] [IFC-0838] [IFC-0339] [IFC-0839] [IFC-0840] [IFC-0865] member order and adjacency; tuple groups; optional tuples":
    let reading =
      "    bool        has_label;\n    const char* label;\n    uint64_t    value;\n"
    check refusal(
      one(
        swapped(
          h391, reading,
          "    uint64_t    value;\n    bool        has_label;\n    const char* label;\n",
        )
      )
    ) == rkFieldOrder
    check refusal(
      one(
        swapped(
          h391, reading,
          "    const char* label;\n    bool        has_label;\n    uint64_t    value;\n",
        )
      )
    ) == rkPresence
    for bad in ["uint64_t a_len;", "uint64_t a_count;", "uint64_t a_5;", "bool has_;"]:
      checkpoint bad
      check refusal(
        one("typedef struct logos_x_S_MAP {\n    " & bad & "\n} logos_x_S_t;\n")
      ) in {rkMember, rkPresence, rkEscape}
    let opt = "demo.x = { ? p: [uint64, tstr], ? e: [], n: [uint64, [uint64, bstr]] }\n"
    check roundTrip(opt)
    let h = generated(opt)
    check refusal(one(swapped(h, "    uint64_t n_0;\n", ""))) == rkMember
      # a missing position
    check refusal(
      one(
        swapped(
          h, "    logos_demo_X_N_TU1_t n_1;\n",
          "    bool has_n_1;\n    logos_demo_X_N_TU1_t n_1;\n",
        )
      )
    ) == rkPresence # a presence flag on a later position
    check refusal(
      one(swapped(h, "    uint64_t n_0;\n", "    uint64_t n_0;\n    uint64_t m;\n"))
    ) in {rkMember, rkFieldOrder} # an interleaved field
    check roundTrip(allForms) # optional tuples as parameters, every field form

  test "T6.4 [IFC-0340] [IFC-0341] aggregate tag members; empty structs, zero-length arrays, stray _empty":
    for bad in [
      "typedef struct logos_x_L_LIST {\n    const uint64_t* items;\n    size_t count;\n    uint64_t extra;\n} logos_x_L_t;\n",
      "typedef struct logos_x_T_TUPLE {\n    uint64_t item_1;\n} logos_x_T_t;\n",
      "typedef struct logos_x_B_BSTR {\n    const uint8_t* data;\n    size_t length;\n} logos_x_B_t;\n",
      "typedef struct logos_x_E_MAP {\n} logos_x_E_t;\n",
      "typedef struct logos_x_A_MAP {\n    uint8_t d[0];\n} logos_x_A_t;\n",
      "typedef struct logos_x_A_MAP {\n    uint8_t _empty;\n    uint64_t b;\n} logos_x_A_t;\n",
    ]:
      checkpoint bad
      check refusal(one(bad)) == rkAggregate
    check roundTrip(
      "demo.e = {}\ndemo.t = []\ndemo.b = bstr .size 0\ndemo.u = { a: {} }\n"
    )

  test "T6.5 [IFC-0835] [IFC-0837] [IFC-0887] every fixed escape spelling as a field and a parameter, CDDL to C to CDDL":
    var fields: seq[string]
    for kw in CEscapedIdentifiers:
      fields.add("  " & kw & ": uint64,")
    let body = "{\n" & fields.join("\n") & "\n}\n"
    check roundTrip("demo.kw = " & body)
    check roundTrip(module("demo.kw_request = " & body & "demo.kw_response = " & body))
    let k =
      "demo.k = { class: uint64, class0: uint64, ? for: bstr, ? int: [* uint64], " &
      "? do: [uint64, tstr], ordinary: bool }\n"
    check roundTrip(k)
    let r = rebuilt(one(generated(k)))
    check r.primary.get.contract.model.declarations[0].body.fields.mapIt(it.name) ==
      @["class", "class0", "do", "for", "int", "ordinary"]

  test "T6.6 [IFC-0836] [IFC-0890] unescaped keyword members and unnecessary escapes":
    for bad in [
      "uint64_t class;", "uint64_t ordinary_;", "bool has_class_;\n    uint64_t class_;"
    ]:
      checkpoint bad
      check refusal(
        one("typedef struct logos_x_S_MAP {\n    " & bad & "\n} logos_x_S_t;\n")
      ) == rkEscape

  test "T6.7 [IFC-0841] [IFC-0842] [IFC-0843] [IFC-0909] choices: forms, discriminants, constants, members, storage":
    let set = module(choices & ping)
    check roundTrip(set, [], ["ext.types.w = tstr\n"])
    check roundTrip(
      "demo.bad = { k: \"a b\", x: uint64 } / { k: \"c\" }\ndemo.dup = \"a-b\" / \"a_b\"\n"
    )
    check roundTrip(
      "demo.nest = { inner: \"x-y\" / \"x_y\" } / { k: \"p\", v: uint64 / tstr }\ndemo.order = { bb: \"x\", c: \"y\" } / { bb: \"z\" }\n"
    )
    check roundTrip(
      "demo.flag = \"on\" / \"off\"\ndemo.leaf = \"leaf\"\ndemo.mixed = \"none\" / uint64 / demo.leaf\n"
    )
    let h = generated(set, [], ["ext.types.w = tstr\n"])
    # indexed form where symbolic form is required
    let indexed = h
      .replace("LOGOS_ARM_demo_Num_CASE_Int16", "LOGOS_ARM_demo_Num_CASE0")
      .replace("LOGOS_ARM_demo_Num_CASE_Tstr", "LOGOS_ARM_demo_Num_CASE1")
      .inBlock(
        "typedef struct logos_demo_Num_CHOICE", "} logos_demo_Num_t;", "arm_Int16",
        "arm_0",
      )
      .inBlock(
        "typedef struct logos_demo_Num_CHOICE", "} logos_demo_Num_t;", "arm_Tstr",
        "arm_1",
      )
    check "arm_1" in indexed
    check refusal(one(indexed)) == rkChoice
    # symbolic form where indexed fallback is required
    let d = generated("demo.dup = \"a-b\" / \"a_b\"\n")
    let symbolic = d
      .replace("LOGOS_ARM_demo_Dup_CASE0", "LOGOS_ARM_demo_Dup_CASE_A_b")
      .replace("LOGOS_LITERAL_demo_Dup_AR0", "LOGOS_LITERAL_demo_Dup_AR_A_b")
    check refusal(one(symbolic)) == rkChoice
    check refusal(
      one(
        swapped(h, "LOGOS_ARM_demo_Num_CASE_Tstr 1u", "LOGOS_ARM_demo_Num_CASE_Tstr 2u")
      )
    ) == rkChoice # an out-of-range tag
    check refusal(
      one(
        swapped(h, "LOGOS_ARM_demo_Num_CASE_Tstr 1u", "LOGOS_ARM_demo_Num_CASE_Tstr 0u")
      )
    ) == rkChoice # a duplicate tag
    check refusal(one(swapped(h, "#define LOGOS_ARM_demo_Num_CASE_Tstr 1u\n", ""))) ==
      rkChoice # a missing tag
    check refusal(one(swapped(h, "\"off-line\"", "\"off-lime\""))) == rkChoice
      # a wrong literal
    check refusal(
      one(
        swapped(
          h, "typedef uint32_t logos_demo_Num_KIND_t;",
          "typedef uint16_t logos_demo_Num_KIND_t;",
        )
      )
    ) == rkChoice
    check refusal(
      one(
        swapped(
          h, "typedef uint32_t logos_demo_Num_KIND_t;",
          "typedef int logos_demo_Num_KIND_t;",
        )
      )
    ) == rkOutsideSubset
    # an inconsistent support path
    check refusal(
      one(h.replace("logos_demo_Shape_AR_Map_h_w_", "logos_demo_Shape_AR_Map_w_h_"))
    ) == rkPath
    # a union member a direct literal arm must omit
    let f = generated("demo.flag = \"on\" / \"off\"\n")
    check refusal(
      one(
        swapped(
          f, "    logos_demo_Flag_KIND_t kind;\n",
          "    logos_demo_Flag_KIND_t kind;\n    union {\n        const char* arm_On;\n    } value;\n",
        )
      )
    ) == rkChoice

  test "T6.8 [IFC-0344] [IFC-0345] [IFC-0346] [IFC-0614] [IFC-0615] [IFC-0616] [IFC-0917] [IFC-0318] paths from containment; recursion":
    check roundTrip(paths)
    let h = generated(paths)
    let r = rebuilt(one(h))
    check r.primary.get.contract.model.declarations.mapIt(it.name).sorted ==
      @["demo.deep", "demo.left", "demo.left_right", "demo.two"]
    # no path reaches an inline definition
    check refusal(
      one(
        h &
          "typedef struct logos_demo_Two_C_MAP {\n    uint64_t x;\n} logos_demo_Two_C_t;\n"
      )
    ) == rkPath
    # a member typed as another path's inline type
    check refusal(
      one(swapped(h, "    logos_demo_Two_B_t b;", "    logos_demo_Two_A_t b;"))
    ) == rkPath
    # omitted steps, altered capitalization, a noncanonical index, a wrong family
    check refusal(one(h.replace("logos_demo_Deep_A_LI_TU1_", "logos_demo_Deep_A_TU1_"))) ==
      rkPath
    check refusal(one(h.replace("logos_demo_Left_Right_", "logos_demo_Left_RIght_"))) ==
      rkPath
    let t = generated("demo.x = { n: [uint64, [uint64, bstr]] }\n")
    check refusal(one(t.replace("logos_demo_X_N_TU1_", "logos_demo_X_N_TU01_"))) ==
      rkPath
    check refusal(one(swapped(h, "logos_demo_Two_A_MAP", "logos_demo_Two_A_LIST"))) ==
      rkAggregate
    # recursion: a required recursive pointer adds no optionality
    check roundTrip(kitchen)
    let tree = rebuilt(one(generated(kitchen)))
    for d in tree.primary.get.contract.model.declarations:
      if d.name == "demo.tree":
        check d.body.fields.filterIt(it.name == "t")[0].optional == false

  test "T6.9 [IFC-0856] [IFC-0857] events: a non-map choice arm, _EVENT on another owner, another family":
    check refusal(
      one(
        "typedef uint32_t logos_demo_Changed_event_KIND_t;\n" &
          "#define LOGOS_ARM_demo_Changed_event_CASE_Uint64 0u\n" &
          "typedef struct logos_demo_Changed_event_CHOICE {\n    logos_demo_Changed_event_KIND_t kind;\n" &
          "    union {\n        uint64_t arm_Uint64;\n    } value;\n} logos_demo_Changed_event_t;\n"
      )
    ) == rkSchema
    check refusal(
      one(mirror("IFC/3.6.event.h").replace("Upload_progress_event", "Upload_progress"))
    ) == rkEvent
    check refusal(
      one(
        "typedef struct logos_demo_Changed_event_LIST {\n    const uint64_t* items;\n    size_t count;\n" &
          "} logos_demo_Changed_event_t;\n"
      )
    ) == rkEvent

suite "ifc.c-reverse: round trips (INTERFACE §3.8, §3.9; G158)":
  test "T7.1 [IFC-0356] [IFC-0357] [IFC-0368] [IFC-0381] [IFC-0389] [IFC-0393] [IMPL-DECISION G158] S -> C -> S′ over the forward corpus and the IFC mirrors":
    check roundTrip(cddl391)
    check roundTrip(mod392, [ifc392], [sup392])
    check roundTrip(ifc392)
    check roundTrip(sup392)
    check roundTrip(cddl393)
    check roundTrip(halves) # §3.9.4
    check roundTrip(kitchen)
    check roundTrip(allForms)
    check roundTrip(paths)
    check roundTrip(
      "demo.lits = { a: 0, b: 18446744073709551615, c: -1, d: -9223372036854775808, e: true, f: \"é1\", g: \"a??=b\" }\n"
    )
    check roundTrip(
      "demo.pair = [uint64] / [uint64, uint64]\ndemo.rows = { names: [* [* tstr]], blobs: [* bstr], cells: [* [uint64, tstr]], digests: [* bstr .size 32], empties: [* []] }\n"
    )
    check roundTrip("demo.node = { kids: [* demo.node], v: uint64 }\n")
    check roundTrip("demo.a = { bs: [* demo.b] }\ndemo.b = { a: demo.a }\n")
    check roundTrip(
      "demo.x = { code: logos.error_code, d: logos.error_detail, c: logos.schema_commitment }\n"
    )
    check roundTrip(
      "demo.s = { a: tstr .size 5, b: tstr .size (0..10), c: bstr .size (2..3) }\n"
    )
    for (src, wrap) in [
      ("1.6.types.cddl", ""),
      ("1.8.module.cddl", ""),
      ("1.8.interface.cddl", ""),
      ("2.3.entry.cddl", ""),
      ("2.3.peer_info.cddl", ""),
      ("2.3.record.cddl", ""),
      ("2.3.space_info.cddl", ""),
      ("2.3.value.cddl", ""),
      ("1.5.events.cddl", "storage_module"),
      ("2.5.event.cddl", "storage_module"),
      ("2.4.exists.cddl", "storage_module"),
      ("2.4.resolve.cddl", "storage_module"),
      ("2.4.upload_url.cddl", "storage_module"),
      ("3.3.upload_url.cddl", "storage_module"),
    ]:
      checkpoint src
      let text = mirror("IFC" / src)
      check roundTrip(
        if wrap.len > 0:
          module(text, wrap)
        else:
          text
      )

  test "T7.2 [IFC-0366] the spec's §3.9.1 C block reconstructs the spec's §3.9.1 schema":
    check rebuilt(one(h391)).primary.get.contract.root == accepted(cddl391).primary.root

  test "T7.3 [IFC-0355] [IFC-0861] [IFC-0862] [IFC-0863] H -> (S, binding) -> H′ -> S″":
    let completed = block:
      let h = generated(module(mirror("IFC/2.4.upload_url.cddl"), "storage_module"))
      dropped(h, "logos_result_t logos_storage_module_CALL_storage_Upload_url(") &
        mirror("IFC/3.3.upload_url.h")
    let (_, bound1) = boundHeader("sensor_module", [ifc392])
    for (h, o) in [
      (h391, RmapOptions()),
      (h392, RmapOptions()),
      (h393, RmapOptions()),
      (completed, RmapOptions()),
      (bound1, RmapOptions()),
      (h395, RmapOptions(subject: "a.b")),
    ]:
      let r = rebuilt(one(h), o)
      let again = rebuilt(one(r.header), o)
      check again.roots == r.roots
      check again.module == r.module
      check again.header == r.header
    # H′ is the metadata-extended form: it has the role constant the input left out
    let r391 = rebuilt(one(h391))
    check "LOGOS_PRIMARY_NAMESPACE_meter_module" notin h391
    check "#define LOGOS_PRIMARY_NAMESPACE_meter_module \"meter\"" in r391.header
    # and for §3.9.2 it holds the spec's block item by item
    var got: seq[string]
    for it in parsedOk(rebuilt(one(h392)).header).items:
      if it.kind == ciDocumentGuard:
        for c in it.children:
          got.add(render(c))
      else:
        got.add(render(it))
    for it in parsedOk(h392).items:
      checkpoint render(it)
      check render(it) in got

  test "T7.4 [IFC-0873] the §3.9.1 header with its primary constant":
    check rebuilt(
      one("#define LOGOS_PRIMARY_NAMESPACE_meter_module \"meter\"\n" & h391)
    ).roots == rebuilt(one(h391)).roots

  test "T7.5 [IFC-0868] an event with a choice body keeps its role, map arms and identity":
    let ev =
      "_interface = \"demo\"\ndemo.changed_event = { kind: \"a\", x: uint64 } / { kind: \"b\" }\n"
    check roundTrip(ev)
    let r = rebuilt(one(generated(ev)), RmapOptions(subject: "demo"))
    let d = r.primary.get.contract.model.declarations[0]
    check d.kind == dkEvent
    check d.body.kind == snChoice and d.body.arms.allIt(it.kind == snMap)

  test "T7.6 [IFC-0003] [IFC-0004] [IMPL-DECISION G158] from either side: the same model, the same canonical C, the same CBOR bytes":
    let s = accepted(cddl391)
    let fromCddl = contractHeader(s.cSchemaSet).get
    let r = rebuilt(one(h391)) # C first
    check r.primary.get.contract.root == s.primary.root
    check r.header == fromCddl
    let rs = rebuilt(one(fromCddl)) # CDDL first, then C
    check rs.roots == r.roots and rs.header == r.header
    # a schema-typed value validates and encodes the same under S and S′
    let again = accepted(r.primary.get.cddl)
    let good = @[0xA1'u8, 0x67] & "channel".toOpenArrayByte(0, 6).toSeq & @[0x07'u8]
    let bad =
      @[0xA1'u8, 0x67] & "channel".toOpenArrayByte(0, 6).toSeq & @[0x61'u8, 0x78]
    let a = validator(s).checkParams("read", good)
    let b = validator(again).checkParams("read", good)
    check a.isOk and b.isOk
    if a.isOk and b.isOk:
      check encodeCbor(a.get) == encodeCbor(b.get)
    check validator(s).checkParams("read", bad).isErr
    check validator(again).checkParams("read", bad).isErr

  test "T7.7 [IFC-0293] metadata only where the declarations cannot say it":
    check rebuilt(one(h391)).primary.isSome # no constant at all
    check refusal(
      one(h391 & "#define LOGOS_EVENT_NAME_meter_Changed \"meter.changed_event\"\n")
    ) == rkRestatedFact
    check refusal(one(h391 & "#define LOGOS_LITERAL_meter_Reading_Extra UINT64_C(1)\n")) ==
      rkRestatedFact

  test "[IMPL-DECISION G319] every name is declared, and every by-value type complete, before its use":
    let fwds =
      "typedef struct logos_recursive_Left_MAP logos_recursive_Left_t;\n" &
      "typedef struct logos_recursive_Node_MAP logos_recursive_Node_t;\n" &
      "typedef struct logos_recursive_Right_MAP logos_recursive_Right_t;\n"
    check refusal(one(swapped(h393, fwds, "") & fwds)) == rkDeclareOrder
    let branch =
      "typedef struct logos_recursive_Branch_MAP {\n    logos_recursive_Node_t node;\n} logos_recursive_Branch_t;\n"
    check refusal(one(fwds & branch & swapped(swapped(h393, fwds, ""), branch, ""))) ==
      rkDeclareOrder

  test "accepted inputs and every H′ compile as C17, C23, C++17, C++20 and C++23":
    var files: seq[(string, string)]
    var includes = ""
    for (n, h) in [
      ("m391.h", h391), ("m392.h", h392), ("m393.h", h393), ("m395.h", h395)
    ]:
      files.add((n, h))
      includes.add("#include \"" & n & "\"\n")
    let hp = rebuilt(one(generated(allForms))).header
    files.add(("forms.h", hp))
    includes.add("#include \"forms.h\"\n")
    files.add(("all.h", includes))
    checkCompiles compilesFiles("mirrors", files, "all.h")

suite "ifc.c-reverse: the §3.9.5 required rejections (INTERFACE §3.9.5)":
  # Every case starts from its input and applies only the table's mutation; the
  # result is the reason code and no document.
  let h394 = generated(halves)

  test "T8.1 [IFC-0395] [IFC-0306] [IFC-0838] C-DECL-WRONG-PRESENCE-TYPE":
    check refusal(one(swapped(h391, "bool        has_label", "uint32_t    has_label"))) ==
      rkPresence

  test "T8.2 [IFC-0395] [IFC-0306] [IFC-0838] C-DECL-UNMATCHED-PRESENCE-MEMBER":
    check refusal(one(swapped(h391, "    const char* label;\n", ""))) == rkPresence

  test "T8.3 [IFC-0395] [IFC-0306] [IFC-0314] C-DECL-CONFLICTING-ROLE":
    check refusal(one(h391 & "#define LOGOS_SUPPORTING_NAMESPACE_meter \"meter\"\n")) ==
      rkSupportingCallable

  test "T8.4 [IFC-0395] [IFC-0306] [IFC-0310] C-EXT-MISSING-PRIMARY":
    check refusal(
      one(
        swapped(
          h392, "#define LOGOS_PRIMARY_NAMESPACE_sensor_module \"sensor.control\"\n", ""
        )
      )
    ) == rkRoleConstant

  test "T8.5 [IFC-0395] [IFC-0306] [IFC-0311] C-EXT-BAD-PRIMARY-PROJECTION":
    check refusal(one(swapped(h392, "\"sensor.control\"", "\"sensor.runtime\""))) ==
      rkRoleMismatch

  test "T8.6 [IFC-0395] [IFC-0306] [IFC-0310] C-EXT-MISSING-INTERFACE-ROLE":
    check refusal(
      one(
        swapped(
          h392,
          "#define LOGOS_INTERFACE_NAMESPACE_metrics_provider \"metrics_provider\"\n",
          "",
        )
      )
    ) == rkRoleConstant

  test "T8.7 [IFC-0395] [IFC-0306] [IFC-0313] C-EXT-MISSING-IMPLEMENTS":
    check refusal(
      one(
        swapped(
          h392, "#define LOGOS_IMPLEMENTS_sensor_module_INDEX0 \"metrics_provider\"\n",
          "",
        )
      )
    ) == rkMissingImplements

  test "T8.8 [IFC-0395] [IFC-0306] [IFC-0347] C-EXT-WRONG-LITERAL-TYPE":
    check refusal(one(swapped(h392, "\"sensor\"", "7u"))) == rkLiteralKind

  test "T8.9 [IFC-0395] [IFC-0306] [IFC-0784] C-EXT-UNSUPPORTED-DOUBLE":
    check refusal(one(h392 & "typedef double logos_sensor_NS_control_Temperature_t;\n")) ==
      rkOutsideSubset

  test "T8.10 [IFC-0395] [IFC-0306] [IFC-0318] C-RECURSIVE-EMBEDDED-SELF":
    check refusal(
      one(
        swapped(
          h393, "const logos_recursive_Node_t* next;", "logos_recursive_Node_t next;"
        )
      )
    ) == rkRecursiveEmbedded

  test "T8.11 [IFC-0395] [IFC-0306] [IFC-0318] C-RECURSIVE-POINTER-NONRECURSIVE":
    check refusal(
      one(
        swapped(
          h393, "logos_recursive_Node_t node;", "const logos_recursive_Node_t* node;"
        )
      )
    ) == rkRecursivePointer

  test "T8.12 [IFC-0395] [IFC-0306] [IFC-0324] C-CHOICE-WRONG-WRAPPER-NAME (§3.9.4, generated)":
    check refusal(one(swapped(h394, "in_request", "in_value"))) == rkWrapper

  test "T8.13 [IFC-0395] [IFC-0306] [IFC-0324] C-CHOICE-MIXED-REQUEST-FORM (§3.9.4, generated)":
    check refusal(
      one(
        swapped(
          h394, "const logos_storage_Resolve_request_t* in_request,",
          "const logos_storage_Resolve_request_t* in_request,\n    uint64_t in_extra,",
        )
      )
    ) == rkWrapper
