## INTERFACE §3 (Canonical C-to-CDDL Mapping): the reverse mapper. The input set
## and its includes (§3, §3.2), the accepted C subset and header frame (§2, §3.1),
## literal recognition (§3.5, §3.9).

import std/[os, sequtils, strutils]
import unittest2
import ../src/logos_core/iface/[accept, cinput, cliteral]
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

# Tests -----------------------------------------------------------------------------

suite "ifc.c-reverse: the input set and its includes (INTERFACE §3, §3.2)":
  const v = "typedef uint64_t logos_x_V_t;\n"

  test "[IFC-0791] logical names are unique, nonempty, relative paths without empty, . or .. components or backslashes":
    for bad in ["", "/a.h", "a//b.h", "./a.h", "a/../b.h", "a\\b.h", "a/", "."]:
      check refused(src(bad, v)) == rkLogicalName
    check refused(src("a.h", v), src("a.h", v)) == rkDuplicateName
    # case-sensitive: two names
    discard readOk(src("a.h", v), src("A.h", v), src("sub/dir/a.h", v))

  test "[IFC-0792] [IFC-0793] contract includes are literal quoted names, nonempty and relative":
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

  test "[IFC-0794] [IFC-0795] [IFC-0797] includes resolve from the includer's directory, never above the root, to exactly one supplied name":
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

  test "[IFC-0796] the mapper never consults the filesystem":
    let dir = outDir / "fs"
    createDir(dir)
    writeFile(dir / "ondisk.h", v)
    let here = getCurrentDir()
    setCurrentDir(dir)
    defer:
      setCurrentDir(here)
    check fileExists("ondisk.h")
    check refused(src("user.h", "#include \"ondisk.h\"\n")) == rkIncludeMissing

  test "[IFC-0783] [IFC-0798] every supplied body is parsed and kept with its macros, whether included once, twice or never":
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
  test "[IFC-0784] declarations outside the subset are rejected, not treated as helpers":
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

  test "[IFC-0295] declarations that vary with the language or sit under another condition are rejected":
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

  test "[IFC-0785] [IFC-0591] the conditional linkage wrapper is non-schema syntax, and hand-written input may omit it":
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

  test "[IMPL-DECISION G317] the generated frame: revision, context and identity checks, and document guards":
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
    let guarded =
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

  test "[IMPL-DECISION G317] a file-level include guard is accepted only around declarations":
    let g = "#ifndef DEMO_H\n#define DEMO_H\nBODY#endif\n"
    let ok1 = parsedOk(g.replace("BODY", "typedef uint64_t logos_x_V_t;\n"))
    check ok1.includeGuard == "DEMO_H"
    check ok1.items.len == 1
    check parseRefused(g.replace("BODY", "#include <stdint.h>\n")) == rkConditional
    check parseRefused(
      g.replace(
        "BODY",
        "#if !defined(LOGOS_C_MAPPING_REVISION) || LOGOS_C_MAPPING_REVISION != 3u\n" &
          "#error \"x\"\n#endif\n",
      )
    ) == rkConditional
    check parseRefused(
      "#ifndef LOGOS_DEMO_H\n#define LOGOS_DEMO_H\ntypedef uint64_t logos_x_V_t;\n#endif\n"
    ) == rkConditional

  test "[IFC-0855] a header must not redefine the standard literal macros":
    for m in ["INT8_C", "UINT64_C", "INT64_MIN", "true", "false"]:
      check parseRefused("#define " & m & " 1\n") == rkStandardMacro
    check parseRefused("#define UINT64_C(x) x\n") == rkStandardMacro

  test "[IFC-0852] the source is UTF-8, and headers compile with UTF-8 source and string literal encodings":
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
  test "[IFC-0844] [IFC-0846] [IFC-0847] [IFC-0848] [IFC-0849] [IFC-0869] the generated and handwritten integer and Boolean forms":
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

  test "[IFC-0844] [IFC-0850] [IFC-0851] [IFC-0869] text: concatenated UTF-8 strings with equivalent escapes":
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

  test "[IFC-0846] [IFC-0847] [IFC-0848] [IFC-0849] [IFC-0850] [IFC-0851] [IFC-0853] [IFC-0854] [IFC-0870] rejected: unsigned negation, malformed suffixes, out-of-range values, NUL, invalid UTF-8, other expressions":
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
