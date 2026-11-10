"""Writes tests/vectors/cddl/vectors.cbor: the cdCDDLe §12 self-vector set (G16).

The container is a deterministic-CBOR map {"vectors": [record, ...]} whose
records follow cdCDDLe §12 exactly. Error classes are the coarse G16 ones:
syntax, unsupported, resolution, canonical, decode.

Source vectors (input-cddl) carry an expected canonical model written by hand
below from cdCDDLe §7-§8; the expected bytes are that model encoded by the
oracle, never output of the Nim code. Decode vectors (input-cbor-hex) are
checked by the independent oracle/cdcddle.py: a valid one must pass it and an
invalid one must fail it, or nothing is written.

Vector names start with their category, which the Nim suite uses to tag the
cdCDDLe requirement each category covers.

Run from the repository root: python3 oracle/gen_cddl_vectors.py [--check]
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import cdcddle  # noqa: E402
import dcbor  # noqa: E402

ROOT = Path(".")
OUT = ROOT / "tests/vectors/cddl/vectors.cbor"


# Model builders (cdCDDLe §8) ---------------------------------------------------

def doc(*rules):
    return {0: 0, 1: list(rules), 2: "cdcddle"}


def rule(name, t):
    return {0: 1, 1: name, 3: t}


def ref(name):
    return {0: 3, 1: name}


def prim(name):
    return {0: 5, 1: name}


def lit(kind, value):
    return {0: 6, 1: kind, 2: value}


def u(v):
    return lit("uint", v)


def nint(v):
    return lit("nint", v)


def integer(v):
    return u(v) if v >= 0 else nint(v)


def text(v):
    return lit("tstr", v)


def bstr(v):
    return lit("bstr", v)


def boolean(v):
    return lit("bool", v)


def member(t, key=None, occ=None):
    m = {0: 10}
    if key is not None:
        m[1] = {0: 21, 1: text(key)}
    m[2] = t
    if occ is not None:
        m[3] = {0: 11, 1: 0, 2: 1 if occ == "?" else "unbounded"}
    return m


def array(*members):
    return {0: 7, 1: {0: 9, 1: list(members)}}


def cmap(*members):
    return {0: 8, 1: {0: 9, 1: list(members)}}


def choice(*alts):
    return {0: 12, 1: list(alts)}


def rng(lo, hi):
    return {0: 13, 1: integer(lo), 2: integer(hi), 3: True, 4: True}


def size(target, controller):
    return {0: 14, 1: "size", 2: prim(target), 3: controller}


UINT, BOOL, TSTR, BSTR = prim("uint"), prim("bool"), prim("tstr"), prim("bstr")


def one(t, name="a"):
    return doc(rule(name, t))


# Source vectors ------------------------------------------------------------------

VALID = [
    # presentation: whitespace, comments, numeric spelling, string escaping (§7, §12)
    ("presentation-whitespace-compact", "a=uint\n", one(UINT)),
    ("presentation-whitespace-spread", "\n\n  a\n    =\n        uint\n\n", one(UINT)),
    ("presentation-whitespace-crlf", "a =\r\n uint\r\n", one(UINT)),
    ("presentation-whitespace-no-final-newline", "a = uint", one(UINT)),
    ("presentation-comments", "; leading\na = ; inside\n  uint ; trailing\n; last\n", one(UINT)),
    ("presentation-number-decimal", "a = 26\n", one(u(26))),
    ("presentation-number-hex", "a = 0x1a\n", one(u(26))),
    ("presentation-number-hex-upper", "a = 0X001A\n", one(u(26))),
    ("presentation-number-binary", "a = 0b11010\n", one(u(26))),
    ("presentation-number-negative", "a = -26\n", one(nint(-26))),
    ("presentation-number-negative-hex", "a = -0x1a\n", one(nint(-26))),
    ("presentation-number-negative-zero", "a = -0\n", one(u(0))),
    ("presentation-text-plain", 'a = "caf\u00e9 \\"q\\" \\\\ /"\n', one(text('caf\u00e9 "q" \\ /'))),
    ("presentation-text-escaped", 'a = "caf\\u00E9 \\"q\\" \\\\ \\/"\n', one(text('caf\u00e9 "q" \\ /'))),
    ("presentation-text-control-escapes", 'a = "\\b\\f\\n\\r\\t\\u0000"\n', one(text("\b\f\n\r\t\0"))),
    ("presentation-text-surrogate-pair", 'a = "\\ud83d\\ude00"\n', one(text("\U0001f600"))),
    ("presentation-text-raw-astral", 'a = "\U0001f600"\n', one(text("\U0001f600"))),
    ("presentation-bytes-hex", "a = h'00ff'\n", one(bstr(b"\x00\xff"))),
    ("presentation-bytes-hex-spaced", "a = h'00 FF'\n", one(bstr(b"\x00\xff"))),
    ("presentation-bytes-hex-multiline", "a = H'00\n  ff ; a comment\n'\n", one(bstr(b"\x00\xff"))),
    ("presentation-bytes-base64", "a = b64'AP8='\n", one(bstr(b"\x00\xff"))),
    ("presentation-bytes-base64-unpadded", "a = b64'AP8'\n", one(bstr(b"\x00\xff"))),
    ("presentation-bytes-base64-classic", "a = b64'+/8='\n", one(bstr(b"\xfb\xff"))),
    ("presentation-bytes-base64url", "a = b64'-_8'\n", one(bstr(b"\xfb\xff"))),
    ("presentation-bytes-quoted", "a = 'A\\'b\\u00e9'\n", one(bstr(b"A'b\xc3\xa9"))),
    ("presentation-bytes-quoted-as-hex", "a = h'412762c3a9'\n", one(bstr(b"A'b\xc3\xa9"))),
    ("presentation-parentheses", "a = ((uint))\n", one(UINT)),
    ("presentation-separators-commas", "a = [uint, tstr,]\n", one(array(member(UINT), member(TSTR)))),
    ("presentation-separators-spaces", "a = [uint tstr]\n", one(array(member(UINT), member(TSTR)))),
    ("presentation-control-tight", "a = tstr .size(1..8)\n", one(size("tstr", rng(1, 8)))),
    ("presentation-control-spaced", "a = tstr .size ( 1 .. 8 )\n", one(size("tstr", rng(1, 8)))),
    # top-level rule order (§7.1)
    ("rule-order-sorted", "a = uint\nb = tstr\n", doc(rule("a", UINT), rule("b", TSTR))),
    ("rule-order-reversed", "b = tstr\na = uint\n", doc(rule("a", UINT), rule("b", TSTR))),
    (
        "rule-order-scalar-values",
        "a = uint\n_x = uint\nB = uint\n@y = uint\na0 = uint\na.b = uint\na-b = uint\n",
        doc(*(rule(n, UINT) for n in ["@y", "B", "_x", "a", "a-b", "a.b", "a0"])),
    ),
    # distinct bound names with identical structure (§6, §7)
    ("names-identical-primitives", "a = uint\nb = uint\n", doc(rule("a", UINT), rule("b", UINT))),
    (
        "names-identical-maps",
        "p = {x: uint}\nq = {x: uint}\n",
        doc(rule("p", cmap(member(UINT, "x"))), rule("q", cmap(member(UINT, "x")))),
    ),
    # choice alternative order (§7.2, §7.4)
    ("choice-order-first", "a = uint / tstr\n", one(choice(UINT, TSTR))),
    ("choice-order-second", "a = tstr / uint\n", one(choice(TSTR, UINT))),
    (
        "choice-flattened",
        "a = (uint / tstr) / (bool / (bstr / 1))\n",
        one(choice(UINT, TSTR, BOOL, BSTR, u(1))),
    ),
    ("choice-duplicates-kept", "a = uint / uint\n", one(choice(UINT, UINT))),
    ("choice-literals", "a = 1 / 2 / true / false\n", one(choice(u(1), u(2), boolean(True), boolean(False)))),
    # named references (§6, §7.3)
    ("reference-preserved", "a = b\nb = uint\n", doc(rule("a", ref("b")), rule("b", UINT))),
    ("reference-recursive", "tree = [* tree]\n", one(array(member(ref("tree"), occ="*")), "tree")),
    (
        "reference-mutual",
        "a = [* b]\nb = {? next: a}\n",
        doc(rule("a", array(member(ref("b"), occ="*"))), rule("b", cmap(member(ref("a"), "next", "?")))),
    ),
    ("reference-dotted-names", "w = x.y-z\nx.y-z = uint\n", doc(rule("w", ref("x.y-z")), rule("x.y-z", UINT))),
    # every supported construct (§5.1, §7.4)
    (
        "construct-primitives",
        "a = [uint, bool, tstr, bstr]\n",
        one(array(member(UINT), member(BOOL), member(TSTR), member(BSTR))),
    ),
    (
        "construct-literals",
        "a = [0, 18446744073709551615, -1, -18446744073709551616, true, false, \"\", h'']\n",
        one(array(*(member(x) for x in [
            u(0), u(2**64 - 1), nint(-1), nint(-(2**64)), boolean(True), boolean(False), text(""), bstr(b""),
        ]))),
    ),
    ("construct-array-variable", "a = [* uint]\n", one(array(member(UINT, occ="*")))),
    ("construct-array-empty", "a = []\n", one(array())),
    ("construct-map-empty", "a = {}\n", one(cmap())),
    (
        "construct-map-sorted",
        "a = {zeta: uint, ? alpha: tstr, mid: [* bstr]}\n",
        one(cmap(member(TSTR, "alpha", "?"), member(array(member(BSTR, occ="*")), "mid"), member(UINT, "zeta"))),
    ),
    (
        "construct-map-scalar-order",
        "a = {b: uint, B: uint, _: uint, a1: uint}\n",
        one(cmap(member(UINT, "B"), member(UINT, "_"), member(UINT, "a1"), member(UINT, "b"))),
    ),
    ("construct-range-uint", "a = 0..255\n", one(rng(0, 255))),
    ("construct-range-hex", "a = 0x00..0xff\n", one(rng(0, 255))),
    ("construct-range-negative", "a = -10..-1\n", one(rng(-10, -1))),
    ("construct-range-mixed", "a = -1..1\n", one(rng(-1, 1))),
    ("construct-range-parenthesized-bounds", "a = (1)..(2)\n", one(rng(1, 2))),
    ("construct-range-equal", "a = 5..5\n", one(u(5))),
    ("construct-range-equal-negative", "a = -3..-3\n", one(nint(-3))),
    ("construct-size-uint", "a = uint .size 8\n", one(size("uint", u(8)))),
    ("construct-size-zero", "a = tstr .size 0\n", one(size("tstr", u(0)))),
    ("construct-size-range", "a = bstr .size (1..32)\n", one(size("bstr", rng(1, 32)))),
    ("construct-size-equal-range", "a = tstr .size (4..4)\n", one(size("tstr", u(4)))),
    ("construct-size-parenthesized", "a = (bstr) .size ((16))\n", one(size("bstr", u(16)))),
    (
        "construct-nested",
        "a = {list: [* {? id: uint, tags: [* tstr]}], pair: [uint, uint / tstr]}\n",
        one(cmap(
            member(array(member(cmap(member(UINT, "id", "?"), member(array(member(TSTR, occ="*")), "tags")), occ="*")), "list"),
            member(array(member(UINT), member(choice(UINT, TSTR))), "pair"),
        )),
    ),
    ("construct-unusual-names", "@a = uint\n_b = @a\n", doc(rule("@a", UINT), rule("_b", ref("@a")))),
    ("construct-literal-key-names", "a = {true: uint, uint: tstr}\n", one(cmap(member(UINT, "true"), member(TSTR, "uint")))),
]

INVALID = [
    # every unsupported construct category of §5.1
    ("unsupported-group-rule", "g = (x: uint)\n"),
    ("unsupported-group-rule-bare", "g = x: uint\n"),
    ("unsupported-group-rule-entries", "g = (uint, tstr)\n"),
    ("unsupported-group-rule-occurrence", "g = * uint\n"),
    ("unsupported-generic-rule", "g<T> = [* T]\n"),
    ("unsupported-generic-application", "g = h<uint>\nh = uint\n"),
    ("unsupported-rule-extension-type", "a = uint\na /= tstr\n"),
    ("unsupported-rule-extension-group", "a = uint\na //= tstr\n"),
    ("unsupported-group-choice", "a = [uint // tstr]\n"),
    ("unsupported-socket-type", "a = $b\n"),
    ("unsupported-socket-group", "a = {$$b}\n"),
    ("unsupported-socket-rule", "$b = uint\n"),
    ("unsupported-unwrap", "a = [~b]\nb = [uint]\n"),
    ("unsupported-enumeration", "a = &b\n"),
    ("unsupported-enumeration-inline", "a = &(x: 1, y: 2)\n"),
    ("unsupported-tag", "a = #6.32(tstr)\n"),
    ("unsupported-major-type", "a = #7.21\n"),
    ("unsupported-any-item", "a = #\n"),
    ("unsupported-cut", 'a = {"x" ^ => uint}\n'),
    ("unsupported-arrow-key", 'a = {"x" => uint}\n'),
    ("unsupported-arrow-key-type", "a = {* tstr => uint}\n"),
    ("unsupported-text-key", 'a = {"x": uint}\n'),
    ("unsupported-uint-key", "a = {1: uint}\n"),
    ("unsupported-keyless-map-entry", "a = {uint}\n"),
    ("unsupported-occurrence-plus", "a = [+ uint]\n"),
    ("unsupported-occurrence-bounded", "a = [1*3 uint]\n"),
    ("unsupported-occurrence-zero-star", "a = [0* uint]\n", "G10"),
    ("unsupported-occurrence-star-one", "a = {*1 x: uint}\n", "G10"),
    ("unsupported-optional-array-member", "a = [? uint]\n"),
    ("unsupported-star-map-member", "a = {* x: uint}\n"),
    ("unsupported-mixed-array", "a = [uint, * tstr]\n"),
    ("unsupported-two-star-array", "a = [* uint, * tstr]\n"),
    ("unsupported-keyed-array-member", "a = [x: uint, y: uint]\n"),
    ("unsupported-exclusive-range", "a = 0...10\n"),
    ("unsupported-control-bits", "a = uint .bits b\n"),
    ("unsupported-control-regexp", 'a = tstr .regexp "x+"\n'),
    ("unsupported-control-cbor", "a = bstr .cbor uint\n"),
    ("unsupported-control-lt", "a = uint .lt 10\n"),
    ("unsupported-control-default", "a = uint .default 1\n"),
    ("unsupported-float", "a = 1.5\n"),
    ("unsupported-float-exponent", "a = 1e3\n"),
    ("unsupported-hexfloat", "a = 0x1p4\n"),
    ("unsupported-integer-too-large", "a = 18446744073709551616\n"),
    ("unsupported-integer-too-small", "a = -18446744073709551617\n"),
    ("unsupported-named-range-bound", "a = 0 .. b\nb = 10\n", "G12"),
    ("unsupported-text-range-bound", 'a = "a" .. "z"\n'),
    ("unsupported-prelude-int", "a = int\n"),
    ("unsupported-prelude-text", "a = text\n"),
    ("unsupported-prelude-any", "a = [* any]\n"),
    ("unsupported-prelude-nil", "a = nil\n"),
    ("unsupported-size-named-target", "a = b .size 3\nb = tstr\n"),
    ("unsupported-size-literal-target", 'a = "x" .size 1\n'),
    ("unsupported-size-named-controller", "a = tstr .size n\nn = 3\n"),
    ("unsupported-size-choice-controller", "a = tstr .size (1 / 2)\n"),
    ("unsupported-bytes-quoted-line-break", "a = 'x\ny'\n"),
    # text that is not CDDL (RFC 8610 Appendix B)
    ("syntax-empty", ""),
    ("syntax-whitespace-only", "  \n\n"),
    ("syntax-comment-only", "; nothing here\n"),
    ("syntax-missing-type", "a =\n"),
    ("syntax-missing-assignment", "a uint\n"),
    ("syntax-tab", "a =\tuint\n"),
    ("syntax-comment-at-end-of-input", "a = uint ; no line break"),
    ("syntax-bare-carriage-return", "a = uint\rb = tstr\n"),
    ("syntax-leading-zero", "a = 01\n"),
    ("syntax-missing-hex-digits", "a = 0x\n"),
    ("syntax-unknown-escape", 'a = "\\x41"\n'),
    ("syntax-quote-escape-in-text", "a = \"\\'\"\n"),
    ("syntax-unpaired-surrogate", 'a = "\\ud800"\n'),
    ("syntax-unterminated-text", 'a = "abc\n'),
    ("syntax-control-character-in-text", 'a = "x\x01"\n'),
    ("syntax-odd-hex", "a = h'abc'\n"),
    ("syntax-bad-hex-digit", "a = h'0g'\n"),
    ("syntax-base64-bad-padding", "a = b64'AP8=='\n"),
    ("syntax-base64-trailing-bits", "a = b64'AP9'\n"),
    ("syntax-base64-mixed-alphabets", "a = b64'+-8='\n"),
    ("syntax-unterminated-array", "a = [uint\n"),
    ("syntax-unbalanced-bracket", "a = uint)\n"),
    ("syntax-size-unparenthesized-range", "a = tstr .size 1..8\n"),
    ("syntax-two-controls", "a = tstr .size 1 .size 2\n"),
    ("syntax-dangling-choice", "a = uint /\n"),
    # names (§6; RFC 8610 forbids redefining prelude names)
    ("resolution-undefined", "a = b\n"),
    ("resolution-undefined-in-map", "a = {x: y}\n"),
    ("resolution-duplicate-rule", "a = uint\na = tstr\n"),
    ("resolution-duplicate-identical-rule", "a = uint\na = uint\n"),
    ("resolution-primitive-name", "uint = tstr\n"),
    ("resolution-primitive-name-bool", "bool = uint\n"),
    ("resolution-prelude-name", "int = uint\n"),
    ("resolution-prelude-name-true", "true = uint\n"),
    # canonical-model rules (§7.4, §8)
    ("canonical-range-reversed", "a = 10..1\n"),
    ("canonical-range-reversed-negative", "a = -1..-10\n"),
    ("canonical-duplicate-map-key", "a = {x: uint, x: tstr}\n"),
    ("canonical-duplicate-map-key-optional", "a = {x: uint, ? x: uint}\n"),
    ("canonical-size-bool", "a = bool .size 1\n"),
    ("canonical-size-negative", "a = uint .size -1\n"),
    ("canonical-size-negative-range", "a = tstr .size (-1..4)\n"),
    ("canonical-size-reversed-range", "a = tstr .size (8..1)\n"),
]


# Decode vectors ------------------------------------------------------------------

MINI = one(UINT)
EVERY_KIND = doc(
    rule("a", cmap(
        member(ref("b"), "k"),
        member(array(member(UINT), member(BOOL)), "l", "?"),
        member(array(member(TSTR, occ="*")), "m"),
    )),
    rule("b", choice(u(1), nint(-1), boolean(False), text("t"), bstr(b"\x00"), BSTR)),
    rule("c", rng(-5, 5)),
    rule("d", size("tstr", rng(1, 64))),
    rule("e", size("uint", u(8))),
)


def bad_member(m):
    return one(cmap(m)) if 1 in m else one(array(m))


DECODE_INVALID = [
    # empty documents and choices (§6, §10)
    ("decode-empty-document", {0: 0, 1: [], 2: "cdcddle"}),
    ("decode-empty-choice", one(choice())),
    ("decode-one-alternative-choice", one(choice(UINT))),
    ("decode-nested-choice", one(choice(choice(UINT, TSTR), BOOL)), "G13"),
    # document identity (§8, §13)
    ("decode-unknown-revision", {0: 0, 1: [rule("a", UINT)], 2: "cdcddle2"}),
    ("decode-revision-as-bytes", {0: 0, 1: [rule("a", UINT)], 2: b"cdcddle"}),
    ("decode-document-kind", {0: 1, 1: [rule("a", UINT)], 2: "cdcddle"}),
    # names (§6, §8)
    ("decode-duplicate-rule", doc(rule("a", UINT), rule("a", UINT))),
    ("decode-rule-name-empty", one(UINT, "")),
    ("decode-rule-name-digit", one(UINT, "1a")),
    ("decode-rule-name-trailing-dash", one(UINT, "a-")),
    ("decode-rule-name-space", one(UINT, "a b")),
    ("decode-rule-name-primitive", one(TSTR, "uint")),
    ("decode-rule-name-not-text", doc({0: 1, 1: b"a", 3: UINT})),
    ("decode-reference-name-empty", one(ref(""))),
    ("decode-reference-name-digit", one(ref("9"))),
    ("decode-reference-name-trailing-dot", one(ref("a."))),
    ("decode-reference-name-primitive", one(ref("tstr"))),
    # literal kind and value pairs (§8)
    ("decode-literal-uint-negative", one(lit("uint", -1))),
    ("decode-literal-nint-positive", one(lit("nint", 1))),
    ("decode-literal-nint-zero", one(lit("nint", 0))),
    ("decode-literal-bool-integer", one(lit("bool", 1))),
    ("decode-literal-uint-bool", one(lit("uint", True))),
    ("decode-literal-tstr-bytes", one(lit("tstr", b"x"))),
    ("decode-literal-bstr-text", one(lit("bstr", "x"))),
    ("decode-literal-null", one(lit("tstr", None))),
    ("decode-literal-unknown-kind", one(lit("int", 1))),
    # ranges (§7.4, §8)
    ("decode-range-equal-bounds", one({0: 13, 1: u(5), 2: u(5), 3: True, 4: True})),
    ("decode-range-reversed", one({0: 13, 1: u(5), 2: u(1), 3: True, 4: True})),
    ("decode-range-text-bound", one({0: 13, 1: text("a"), 2: text("z"), 3: True, 4: True})),
    ("decode-range-exclusive", one({0: 13, 1: u(1), 2: u(5), 3: True, 4: False})),
    ("decode-range-missing-inclusive", one({0: 13, 1: u(1), 2: u(5), 3: True})),
    # occurrences and members (§8)
    ("decode-occurrence-upper-two", bad_member({0: 10, 2: UINT, 3: {0: 11, 1: 0, 2: 2}})),
    ("decode-occurrence-lower-one", one(array({0: 10, 2: UINT, 3: {0: 11, 1: 1, 2: "unbounded"}}))),
    ("decode-occurrence-extra-field", one(array({0: 10, 2: UINT, 3: {0: 11, 1: 0, 2: "unbounded", 3: 1}}))),
    ("decode-map-member-unbounded", one(cmap(member(UINT, "x", "*")))),
    ("decode-map-member-without-key", one(cmap(member(UINT)))),
    ("decode-array-member-optional", one(array(member(UINT, occ="?")))),
    ("decode-array-member-with-key", one(array(member(UINT, "x")))),
    ("decode-array-mixed", one(array(member(UINT, occ="*"), member(TSTR)))),
    ("decode-array-two-unbounded", one(array(member(UINT, occ="*"), member(TSTR, occ="*")))),
    ("decode-member-key-not-tstr", one(cmap({0: 10, 1: {0: 21, 1: u(1)}, 2: UINT}))),
    ("decode-member-key-bare-text", one(cmap({0: 10, 1: "x", 2: UINT}))),
    # .size (§8)
    ("decode-size-bool-target", one(size("bool", u(1)))),
    ("decode-size-reference-target", one({0: 14, 1: "size", 2: ref("b"), 3: u(1)})),
    ("decode-size-negative", one(size("uint", nint(-1)))),
    ("decode-size-negative-range", one(size("tstr", rng(-1, 4)))),
    ("decode-size-text-controller", one(size("tstr", text("4")))),
    ("decode-control-bits", one({0: 14, 1: "bits", 2: UINT, 3: u(1)})),
    # unknown node kinds and fields (§8, §10)
    ("decode-node-kind-2", one({0: 2, 1: "a"})),
    ("decode-node-kind-4", one({0: 4, 1: "a"})),
    ("decode-node-kind-15", one({0: 15})),
    ("decode-node-kind-22", one({0: 22})),
    ("decode-node-kind-group-as-type", one({0: 9, 1: []})),
    ("decode-node-kind-text", one({0: "3", 1: "a"})),
    ("decode-node-not-a-map", one([5, "uint"])),
    ("decode-unknown-field-rule", doc({0: 1, 1: "a", 2: "x", 3: UINT})),
    ("decode-unknown-field-document", {0: 0, 1: [rule("a", UINT)], 2: "cdcddle", 3: 0}),
    ("decode-unknown-field-primitive", one({0: 5, 1: "uint", 2: 0})),
    ("decode-unknown-field-member", one(array({0: 10, 2: UINT, 4: 0}))),
    ("decode-unknown-text-field", one({0: 5, 1: "uint", "x": 0})),
    ("decode-missing-rule-type", doc({0: 1, 1: "a"})),
    ("decode-missing-reference-name", one({0: 3})),
    # canonical order (§7.1, §10)
    ("decode-rules-out-of-order", doc(rule("b", UINT), rule("a", UINT))),
    ("decode-map-members-out-of-order", one(cmap(member(UINT, "b"), member(UINT, "a")))),
    ("decode-map-members-duplicate", one(cmap(member(UINT, "a"), member(TSTR, "a")))),
]


def non_deterministic() -> list[tuple[str, str]]:
    """Encodings of MINI that are not deterministic CBOR (§9, §10)."""
    h = dcbor.encode(MINI).hex()
    assert h == "a3000001" + "81" + "a3000101616103a20005016475696e74" + "02676364636464" + "6c65", h
    rules = "81" + "a3000101616103a20005016475696e74"
    tail = "02676364636464" + "6c65"
    return [
        ("decode-cbor-non-shortest-key", "a3" + "1800" + "00" + "01" + rules + tail),
        ("decode-cbor-non-shortest-value", "a3" + "00" + "1800" + "01" + rules + tail),
        ("decode-cbor-non-shortest-length", "a3" + "0000" + "01" + "9801" + rules[2:] + tail),
        ("decode-cbor-indefinite-array", "a3" + "0000" + "01" + "9f" + rules[2:] + "ff" + tail),
        ("decode-cbor-indefinite-map", "bf" + "0000" + "01" + rules + tail + "ff"),
        ("decode-cbor-indefinite-text", h.replace("6161", "7f6161ff", 1)),
        ("decode-cbor-unsorted-keys", "a3" + "01" + rules + "0000" + tail),
        ("decode-cbor-duplicate-key", "a4" + "0000" + "01" + rules + tail + "0000"),
        ("decode-cbor-trailing-bytes", h + "00"),
        ("decode-cbor-truncated", h[:-2]),
    ]


# Output --------------------------------------------------------------------------

def canonical_order(v):
    """Rebuilds maps with keys in deterministic-encoding order, for diagnostics."""
    if isinstance(v, dict):
        return {k: canonical_order(v[k]) for k in sorted(v, key=dcbor.encode)}
    if isinstance(v, list):
        return [canonical_order(x) for x in v]
    return v


def record(name, expect, notes="", **fields):
    r = {"name": name, "expect": expect}
    r.update(fields)
    if notes:
        r["notes"] = notes
    return r


def build() -> list[dict]:
    out: list[dict] = []
    for name, src, model in VALID:
        data = dcbor.encode(model)
        cdcddle.check(data)
        out.append(record(
            name, "valid", "expected model written by hand from cdCDDLe §7-§8",
            **{"input-cddl": src, "canonical-diagnostic": dcbor.diag(canonical_order(model)),
               "canonical-cbor-hex": data.hex()},
        ))
    for item in INVALID:
        name, src = item[0], item[1]
        cls = name.split("-")[0]
        out.append(record(name, "invalid", item[2] if len(item) > 2 else "", **{"input-cddl": src, "error-class": cls}))
    app_a = bytes.fromhex("".join((ROOT / "spec/mirrors/CDE/app-a.cbor.hex").read_text().split()))
    for name, data in (("decode-app-a", app_a), ("decode-minimal", dcbor.encode(MINI)),
                       ("decode-every-kind", dcbor.encode(EVERY_KIND))):
        cdcddle.check(data)
        out.append(record(
            name, "valid", "accepted by oracle/cdcddle.py",
            **{"input-cbor-hex": data.hex(), "canonical-diagnostic": dcbor.diag(dcbor.decode(data)),
               "canonical-cbor-hex": data.hex()},
        ))
    invalid = [(i[0], dcbor.encode(i[1]).hex(), i[2] if len(i) > 2 else "") for i in DECODE_INVALID]
    invalid += [(n, h, "not deterministic CBOR") for n, h in non_deterministic()]
    for name, h, note in invalid:
        try:
            cdcddle.check(bytes.fromhex(h))
        except cdcddle.CdeError:
            pass
        else:
            raise SystemExit(f"{name}: the oracle accepts it")
        out.append(record(name, "invalid", note, **{"input-cbor-hex": h, "error-class": "decode"}))
    names = [r["name"] for r in out]
    assert len(names) == len(set(names)), "duplicate vector names"
    return out


def main() -> int:
    data = dcbor.encode({"vectors": build()})
    if "--check" in sys.argv:
        same = OUT.exists() and OUT.read_bytes() == data
        print("cdCDDLe vectors are up to date" if same else f"{OUT} is stale: run python3 oracle/gen_cddl_vectors.py")
        return 0 if same else 1
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(data)
    print(f"wrote {len(dcbor.decode(data)['vectors'])} vectors to {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
